#!/bin/sh
# Unit tests for deterministic helpers in lib/ip.sh.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/testlib.sh"
. "$ROOT/lib/ip.sh"

assert_ok 'is_ipv4 accepts a public IPv4 address' is_ipv4 '1.2.3.4'
assert_ok 'is_ipv4 accepts a private IPv4 address' is_ipv4 '192.168.1.1'
assert_fail 'is_ipv4 rejects an incomplete address' is_ipv4 '1.2.3'
assert_fail 'is_ipv4 rejects a CIDR' is_ipv4 '1.2.3.4/24'
assert_fail 'is_ipv4 rejects out-of-range octet' is_ipv4 '1.2.3.256'
assert_fail 'is_ipv4 rejects non-numeric octet' is_ipv4 '1.2.3.x'

assert_ok 'is_domain accepts a hostname' is_domain 'example.com'
assert_ok 'is_domain accepts internal underscores' is_domain 'acme_challenge.example.com'
assert_fail 'is_domain rejects whitespace' is_domain 'example .com'
assert_fail 'is_domain rejects a leading hyphen' is_domain '-example.com'

assert_ok 'is_cidr accepts /0' is_cidr '0.0.0.0/0'
assert_ok 'is_cidr accepts /32' is_cidr '192.168.1.1/32'
assert_fail 'is_cidr rejects a prefix above /32' is_cidr '10.0.0.0/33'
assert_fail 'is_cidr rejects a missing prefix' is_cidr '10.0.0.0'

assert_eq 'cidr_total_ips calculates /32' '1' "$(cidr_total_ips '10.0.0.1/32')"
assert_eq 'cidr_total_ips calculates /24' '256' "$(cidr_total_ips '10.0.0.0/24')"
assert_eq 'cidr_total_ips calculates /0' '4294967296' "$(cidr_total_ips '0.0.0.0/0')"

assert_eq 'cidr_sample_ips handles /32' '10.0.0.1' "$(cidr_sample_ips '10.0.0.1/32')"
assert_eq 'cidr_sample_ips handles /31' '10.0.0.0 10.0.0.1' "$(cidr_sample_ips '10.0.0.0/31')"
assert_eq 'cidr_sample_ips handles /30' '10.0.0.1 10.0.0.2' "$(cidr_sample_ips '10.0.0.0/30')"
assert_eq 'cidr_sample_ips handles /24' '10.0.0.1 10.0.0.128 10.0.0.254' "$(cidr_sample_ips '10.0.0.0/24')"

assert_ok 'is_tunnel_iface accepts nwg' is_tunnel_iface 'nwg0'
assert_ok 'is_tunnel_iface accepts WireGuard' is_tunnel_iface 'wg0'
assert_ok 'is_tunnel_iface accepts kernel tunnel' is_tunnel_iface 'tun0'
assert_fail 'is_tunnel_iface rejects LAN bridge' is_tunnel_iface 'br0'
assert_fail 'is_tunnel_iface rejects Ethernet' is_tunnel_iface 'eth0'

test_summary 'lib/ip.sh'
