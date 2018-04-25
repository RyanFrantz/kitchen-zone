require 'openssl'
require 'securerandom'
require 'shellwords'

require 'net/ssh'


module Kitchen
  module Driver
    # Driver plugin for Test-Kitchen to use Solaris Zones.
    class Zone < Kitchen::Driver::SSHBase
      # Mutex for generating SSH keys, important for concurrent kitchen-ing.
      SSH_KEY_MUTEX = Mutex.new

      # The name of the host that will be used to spin up the kitchen zone.
      default_config :global_zone_host nil
      # The username required to connect to the global zone host.
      default_config :global_zone_username 'root'
      # The name of the user we expect to connect to the zone as.
      default_config :kitchen_user_name 'kitchen'
      # The public and private halves of the key pair we'll use to authenticate
      # when SSH'ing into the zone.
      default_config :ssh_public_key  File.join(Dir.pwd, ".#{config[:kitchen_user_name]}", 'id_rsa.pub')
      default_config :ssh_private_key File.join(Dir.pwd, ".#{config[:kitchen_user_name]}", 'id_rsa')
      expand_path_for :ssh_public_key
      expand_path_for :ssh_private_key
      # An optional comment used to clarify the intent of the zone.
      default_config :zone_comment "Test Kitchen created by #{Etc.getlogin || 'unknown'} on #{Socket.gethostname} at #{Time.now}"
      # The name of the stub device we expect to exist for our zones to connect.
      # The stub device is expected to have a DHCP server bound to it so our
      # zone can grab a dynamic address.
      default_config :zone_lower_link 'kitchenstub0'
      # Name of the zone to create.
      default_config :zone_name do |driver|
        # The zone name identifies the zone to the configuration utility. The following rules apply to zone names:
        #     Each zone must have a unique name.
        #     A zone name is case-sensitive.
        #     A zone name must begin with an alpha-numeric character.
        #     The name can contain alpha-numeric characters, underbars (_), hyphens (-), and periods (.).
        #     The name cannot be longer than 64 characters.
        #     The name global and all names beginning with SUNW are reserved and cannot be used.
        driver.instance.name[0..53] + '-' + SecureRandom.hex(10)
      end
      # The default root of our zones.
      default_config :zone_path_root '/systems/zones/'

      # FIXME: Add logic to ensure we exclude currently listening/active ports.
      # NAT port to forward for SSH.
      default_config :zone_port (rand(65535 - 1025) + 1025)
      # We expect a template zone to exist that we can clone. Name it here.
      default_config :zone_template "kitchen-template"

      # Test that both halves of a keypair exist.
      def keypair?
        File.exist?(config[:ssh_public_key]) && File.exist?(config[:ssh_private_key])
      end

      def write_file(path = '', content = '')
        File.open(path, 'w') do |f|
          f.write(content)
          f.chmod(0600)
        end
      end

      # Generates SSH keypair if needed.
      def generate_keypair
        # If we don't have both halves of the pair, generate a keypair.
        unless keypair?
          SSH_KEY_MUTEX.synchronize do
            private_key = OpenSSL::PKey::RSA.new(2048)
            # We need an SSH2-valid blob.
            ssh2_key_blob = Base64.encode64(private_key.to_blob).gsub("\n", '')
            public_key = "ssh-rsa #{ssh2_key_blob} #{config[:kitchen_user_name]}@#{config[:zone_name]}"
            write_file(config[:ssh_public_key], public_key)
            write_file(config[:ssh_private_key], private_key)
          end
        end
      end

      # Return a Kitchen::SSH object representing a connection to the global
      # zone. So we can do work.
      def gz_connection
        hostname = config[:global_zone_host]
        username = config[:global_zone_username]
        @gz_connection ||= Kitchen::SSH.new(hostname, username)
      end

      def create_zone
        zone_name = state[:zone_name] = config[:zone_name]
        # Format arguments for the zone config commands.
        zone_config_args = {
          zone_path:       config[:zone_path_root] + zone_name,
          zone_lower_link: config[:zone_lower_link],
          zone_comment:    config[:zone_comment]
        }
        zone_config = "#{zone_name}.cfg"
        zone_cfg_path_local = File.join(Dir.pwd, ".#{config[:kitchen_user_name]}", zone_config
        zone_cfg_content = zone_config_commands(zone_config_args)
        write_file(zone_cfg_path_local, zone_cfg_content)

        # Format arguments for the zone system configuration profile.
        zone_sc_profile_args = {
          zone_name:         zone_name,
          kitchen_user_name: config[:kitchen_user_name],
          ssh_public_key:    IO.read(config[:ssh_public_key])
        }
        zone_profile = "#{zone_name}_profile.xml"
        zone_profile_path_local = File.join(Dir.pwd, ".#{config[:kitchen_user_name]}", zone_profile
        zone_profile_content = zone_sc_profile(zone_sc_profile_args)
        write_file(zone_profile_path_local, zone_profile_content)

        # Create a temp dir to hold some config files.
        zone_temp_root = config[:zone_path_root] + 'kitchen_tmp'
        gz_connection.exec("mkdir -p #{zone_temp_root}")
        tempdir = gz_connection.exec("mktemp -d -p #{zone_temp_root}").stdout.strip

        [zone_cfg_path_local, zone_profile_path_local].each do |f|
          gz_connection.upload!(f, tempdir)
        end

        begin

          # Clone the template zone.
          gz_connection.exec("/usr/sbin/zonecfg -z #{zone_name} -f #{tempdir}/#{zone_config}")
          gz_connection.exec("/usr/sbin/zoneadm -z #{zone_name} clone -c #{tempdir}/#{zone_profile} #{config[:zone_template]}")

          # Boot the zone.
          gz_connection.exec("/usr/sbin/zoneadm -z #{zone_name} boot")
        ensure
          # Clean up the config.
          gz_connection.exec("rm -rf #{tempdir}") unless config[:keep_config]
        end
      end

      def setup_networking
        zone_name = config[:zone_name]
        # Wait for networking. An IP address will assigned via DHCP.
        info "Waiting for zone #{zone_name} to start"
        while true # TODO this should have a timeout
          sleep(5)
          cmd = gz_connection.exec("/usr/sbin/zlogin #{zone_name} ipadm show-addr")
          if !cmd.error? && cmd.stdout =~ %r{net0/v4\s+dhcp\s+ok\s+([0-9.]+)/24}
            state[:zone_ip] = $1
            break
          end
        end

        # Set up NAT.
        state[:zone_port] = config[:zone_port]
        gz_connection.exec'sh', '-c', "echo \"rdr net0 0.0.0.0/0 port #{state[:zone_port]} -> #{state[:zone_ip]} port 22\" | /usr/sbin/ipnat -f -")
      end

      def create(state)
        generate_keypair
        create_zone
        setup_networking

        # Populate the state for the transport.
        state[:hostname] = config[:transport][:host]
        state[:port] = state[:zone_port]
        state[:username] = config[:kitchen_user_name]
      end

      def destroy(state)
        if state[:zone_port] && state[:zone_ip]
          gz_connection.exec('sh', '-c', "echo \"rdr net0 0.0.0.0/0 port #{state[:zone_port]} -> #{state[:zone_ip]} port 22\" | /usr/sbin/ipnat -r -f -")
          state.delete(:zone_port)
          state.delete(:zone_ip)
        end
        if state[:zone_name]
          [
            "/usr/sbin/zoneadm -z #{state[:zone_name]} halt",
            "/usr/sbin/zoneadm -z #{state[:zone_name]} uninstall -F",
            "/usr/sbin/zonecfg -z #{state[:zone_name]} delete -F",
          ].each do |cmd|
            gz_connection.exec(cmd)
          end
          state.delete(:zone_name)
        end
      end

    end
  end
end
