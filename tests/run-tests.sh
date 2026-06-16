#!/usr/bin/env bash
# Unit tests for pure helper functions in scripts/ikev2-manager.sh.
# The manager script only runs main() when executed directly, so it is safe to source.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/ikev2-manager.sh
# shellcheck disable=SC1091
source "$TESTS_DIR/../scripts/ikev2-manager.sh"

PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
}

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL: $1"
}

assert_ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass
  else
    fail "$desc"
  fi
}

assert_fail() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$desc"
  else
    pass
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

# valid_ipv4
assert_ok "valid_ipv4 accepts 1.2.3.4" valid_ipv4 "1.2.3.4"
assert_ok "valid_ipv4 accepts 255.255.255.255" valid_ipv4 "255.255.255.255"
assert_ok "valid_ipv4 accepts 0.0.0.0" valid_ipv4 "0.0.0.0"
assert_fail "valid_ipv4 rejects 256.1.1.1" valid_ipv4 "256.1.1.1"
assert_fail "valid_ipv4 rejects 1.2.3" valid_ipv4 "1.2.3"
assert_fail "valid_ipv4 rejects 1.2.3.4.5" valid_ipv4 "1.2.3.4.5"
assert_fail "valid_ipv4 rejects letters" valid_ipv4 "a.b.c.d"
assert_fail "valid_ipv4 rejects empty" valid_ipv4 ""

# ip_to_int
assert_eq "ip_to_int 0.0.0.0" "0" "$(ip_to_int 0.0.0.0)"
assert_eq "ip_to_int 1.0.0.0" "16777216" "$(ip_to_int 1.0.0.0)"
assert_eq "ip_to_int 10.20.20.10" "169088010" "$(ip_to_int 10.20.20.10)"
assert_eq "ip_to_int handles leading zeros" "169088010" "$(ip_to_int 010.020.020.010)"

# valid_cidr
assert_ok "valid_cidr accepts 10.20.20.0/24" valid_cidr "10.20.20.0/24"
assert_ok "valid_cidr accepts 0.0.0.0/0" valid_cidr "0.0.0.0/0"
assert_fail "valid_cidr rejects prefix 33" valid_cidr "10.0.0.0/33"
assert_fail "valid_cidr rejects missing prefix" valid_cidr "10.0.0.0"
assert_fail "valid_cidr rejects bad ip" valid_cidr "300.0.0.0/24"

# cidr_contains
assert_ok "cidr_contains 10.20.20.0/24 holds 10.20.20.10" cidr_contains "10.20.20.0/24" "10.20.20.10"
assert_ok "cidr_contains 0.0.0.0/0 holds anything" cidr_contains "0.0.0.0/0" "8.8.8.8"
assert_fail "cidr_contains 10.20.20.0/24 misses 10.20.21.1" cidr_contains "10.20.20.0/24" "10.20.21.1"
assert_ok "cidr_contains exact /32" cidr_contains "192.168.1.1/32" "192.168.1.1"
assert_fail "cidr_contains /32 mismatch" cidr_contains "192.168.1.1/32" "192.168.1.2"

# valid_range
assert_ok "valid_range accepts default pool" valid_range "10.20.20.10-10.20.20.250"
assert_ok "valid_range accepts single-address range" valid_range "10.20.20.10-10.20.20.10"
assert_fail "valid_range rejects reversed range" valid_range "10.20.20.250-10.20.20.10"
assert_fail "valid_range rejects missing dash" valid_range "10.20.20.10"
assert_fail "valid_range rejects bad end" valid_range "10.20.20.10-foo"

# valid_ipv6
assert_ok "valid_ipv6 accepts ::1" valid_ipv6 "::1"
assert_ok "valid_ipv6 accepts ::" valid_ipv6 "::"
assert_ok "valid_ipv6 accepts 2001:db8::1" valid_ipv6 "2001:db8::1"
assert_ok "valid_ipv6 accepts full form" valid_ipv6 "2001:0db8:0000:0000:0000:0000:0000:0001"
assert_ok "valid_ipv6 accepts 1:2:3:4:5:6:7:8" valid_ipv6 "1:2:3:4:5:6:7:8"
assert_ok "valid_ipv6 accepts trailing ::" valid_ipv6 "fd42:4242:4242:1::"
assert_ok "valid_ipv6 accepts 7 groups with ::" valid_ipv6 "1:2:3:4:5:6:7::"
assert_fail "valid_ipv6 rejects IPv4" valid_ipv6 "1.2.3.4"
assert_fail "valid_ipv6 rejects double compression" valid_ipv6 "2001::db8::1"
assert_fail "valid_ipv6 rejects triple colon" valid_ipv6 "2001:::1"
assert_fail "valid_ipv6 rejects long group" valid_ipv6 "12345::"
assert_fail "valid_ipv6 rejects 9 groups" valid_ipv6 "1:2:3:4:5:6:7:8:9"
assert_fail "valid_ipv6 rejects 7 groups without ::" valid_ipv6 "1:2:3:4:5:6:7"
assert_fail "valid_ipv6 rejects trailing single colon" valid_ipv6 "1::3:"
assert_fail "valid_ipv6 rejects leading single colon" valid_ipv6 ":1::2"
assert_fail "valid_ipv6 rejects non-hex" valid_ipv6 "gggg::1"
assert_fail "valid_ipv6 rejects empty" valid_ipv6 ""

# valid_ipv6_cidr
assert_ok "valid_ipv6_cidr accepts ULA /112" valid_ipv6_cidr "fd42:4242:4242:1::/112"
assert_ok "valid_ipv6_cidr accepts ::/0" valid_ipv6_cidr "::/0"
assert_fail "valid_ipv6_cidr rejects /129" valid_ipv6_cidr "fd42::/129"
assert_fail "valid_ipv6_cidr rejects missing prefix" valid_ipv6_cidr "fd42::"
assert_fail "valid_ipv6_cidr rejects bad address" valid_ipv6_cidr "fd42::zz/64"

# valid_ipv6_mode
assert_ok "valid_ipv6_mode accepts block" valid_ipv6_mode "block"
assert_ok "valid_ipv6_mode accepts nat" valid_ipv6_mode "nat"
assert_ok "valid_ipv6_mode accepts off" valid_ipv6_mode "off"
assert_fail "valid_ipv6_mode rejects on" valid_ipv6_mode "on"

# dns_list_drop_ipv6
assert_eq "dns_list_drop_ipv6 keeps IPv4 only" "1.1.1.1,8.8.8.8" "$(dns_list_drop_ipv6 "1.1.1.1,2606:4700:4700::1111,8.8.8.8")"
assert_eq "dns_list_drop_ipv6 may empty the list" "" "$(dns_list_drop_ipv6 "2606:4700:4700::1111")"

# normalize_dns_list
assert_eq "normalize_dns_list keeps order and strips spaces" "1.1.1.1,8.8.8.8" "$(normalize_dns_list "1.1.1.1; 8.8.8.8")"
assert_eq "normalize_dns_list accepts IPv6" "2606:4700:4700::1111,1.1.1.1" "$(normalize_dns_list "2606:4700:4700::1111,1.1.1.1")"
assert_eq "normalize_dns_list drops IPv6 loopback" "8.8.8.8" "$(normalize_dns_list "::1,8.8.8.8")"
assert_eq "normalize_dns_list dedupes" "1.1.1.1" "$(normalize_dns_list "1.1.1.1,1.1.1.1")"
assert_eq "normalize_dns_list drops loopback" "1.1.1.1" "$(normalize_dns_list "127.0.0.53,1.1.1.1")"
assert_eq "normalize_dns_list drops unspecified" "9.9.9.9" "$(normalize_dns_list "0.0.0.0,9.9.9.9")"
assert_eq "normalize_dns_list drops junk" "8.8.4.4" "$(normalize_dns_list "not-an-ip,8.8.4.4")"
assert_eq "normalize_dns_list empty input" "" "$(normalize_dns_list "")"

# ensure_apple_esp_proposals
assert_eq "ensure_apple_esp_proposals migrates old server set" \
  "aes256gcm16-ecp384,aes256-sha256,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16" \
  "$(ensure_apple_esp_proposals "aes256gcm16-ecp384,aes256-sha256")"
assert_eq "ensure_apple_esp_proposals keeps complete default unchanged" \
  "$DEFAULT_ESP_PROPOSALS" \
  "$(ensure_apple_esp_proposals "$DEFAULT_ESP_PROPOSALS")"
assert_eq "ensure_apple_esp_proposals strips spaces and avoids duplicates" \
  "aes256gcm16,aes256gcm16-ecp256,aes256gcm16-modp2048" \
  "$(ensure_apple_esp_proposals "aes256gcm16, aes256gcm16-ecp256")"

# valid_domain_name
assert_ok "valid_domain_name accepts vpn.example.com" valid_domain_name "vpn.example.com"
assert_fail "valid_domain_name rejects single label" valid_domain_name "example"
assert_fail "valid_domain_name rejects leading dash label" valid_domain_name "-bad.example.com"
assert_fail "valid_domain_name rejects double dot" valid_domain_name "ex..ample.com"
assert_fail "valid_domain_name rejects wildcard" valid_domain_name "*.example.com"
assert_fail "valid_domain_name rejects trailing dot" valid_domain_name "example.com."

# valid_username / valid_group_name
assert_ok "valid_username accepts user@host-1.x" valid_username "user@host-1.x"
assert_fail "valid_username rejects pipe" valid_username "user|name"
assert_fail "valid_username rejects empty" valid_username ""
assert_ok "valid_group_name accepts team_1" valid_group_name "team_1"
assert_fail "valid_group_name rejects space" valid_group_name "team 1"

# valid_dns_provider
assert_ok "valid_dns_provider accepts dns_timeweb" valid_dns_provider "dns_timeweb"
assert_fail "valid_dns_provider rejects shell metachars" valid_dns_provider "dns;rm"

# normalize_platform / valid_platform
assert_eq "normalize_platform Win -> windows" "windows" "$(normalize_platform "Win")"
assert_eq "normalize_platform iPhone -> ios" "ios" "$(normalize_platform "iPhone")"
assert_eq "normalize_platform empty -> unknown" "unknown" "$(normalize_platform "")"
assert_ok "valid_platform accepts macos" valid_platform "macos"
assert_fail "valid_platform rejects android" valid_platform "android"

# infer_group_from_username
assert_eq "infer_group_from_username team-alice" "team" "$(infer_group_from_username "team-alice")"
assert_eq "infer_group_from_username bob" "bob" "$(infer_group_from_username "bob")"

# escape_swanctl / html_escape / trim
assert_eq "escape_swanctl escapes quotes" 'a\"b' "$(escape_swanctl 'a"b')"
assert_eq "escape_swanctl escapes backslash" 'a\\b' "$(escape_swanctl 'a\b')"
assert_eq "html_escape escapes markup" "&lt;b&gt;&amp;&quot;" "$(html_escape '<b>&"')"
assert_eq "trim strips whitespace" "abc" "$(trim "  abc  ")"

echo
echo "Passed: $PASSED, failed: $FAILED"
((FAILED == 0))
