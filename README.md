# `kitchen-zone` Driver

[![License](https://img.shields.io/badge/license-Apache_2-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

A [Test Kitchen](https://kitchen.ci/) driver to test cookbooks using Solaris zones.

## Inspiration

Originally forked from
[https://github.com/poise/kitchen-zone](https://github.com/poise/kitchen-zone).
The code has been updated to take advantage of newer support in
[test-kitchen](https://github.com/test-kitchen/test-kitchen). It also updates
(and tries to call out) assumptions about the underlying Solaris host that are
required to spin up zones.

**TODO**: Add tons of documentation, especially about the `kitchen`
configuration variables.
