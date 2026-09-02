#!/usr/bin/env bash
# Unit tests for pure helper functions in scripts/ikev2-manager.sh.
# The manager script only runs main() when executed directly, so it is safe to source.
#
# Fixture assignments below are read by the sourced manager functions, not by
# this file, which is what SC2034 flags.
# shellcheck disable=SC2034

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

# conntrack_target_max
assert_eq "conntrack target raises a low limit" "32768" "$(conntrack_target_max 7680)"
assert_eq "conntrack target keeps the minimum" "32768" "$(conntrack_target_max 32768)"
assert_eq "conntrack target preserves a higher limit" "65536" "$(conntrack_target_max 65536)"
assert_eq "conntrack target handles unavailable input" "32768" "$(conntrack_target_max unavailable)"

MOCK_CONNTRACK_COUNT=100
MOCK_CONNTRACK_MAX=7680
# shellcheck disable=SC2329 # Invoked indirectly by conntrack_status.
sysctl() {
  # shellcheck disable=SC2317 # Function body is invoked indirectly.
  case "${2:-}" in
    net.netfilter.nf_conntrack_count) printf '%s\n' "$MOCK_CONNTRACK_COUNT" ;;
    net.netfilter.nf_conntrack_max) printf '%s\n' "$MOCK_CONNTRACK_MAX" ;;
    *) return 1 ;;
  esac
}
assert_eq "conntrack status flags a low limit" \
  "100/7680 (1%); limit below 32768" "$(conntrack_status)"
MOCK_CONNTRACK_COUNT=22938
MOCK_CONNTRACK_MAX=32768
assert_eq "conntrack status warns at 70 percent" \
  "22938/32768 (70%); warning" "$(conntrack_status)"
MOCK_CONNTRACK_COUNT=29492
assert_eq "conntrack status is critical at 90 percent" \
  "29492/32768 (90%); critical" "$(conntrack_status)"
unset -f sysctl

# valid_port / valid_port_list / normalize_port_list
assert_ok "valid_port accepts 22" valid_port "22"
assert_ok "valid_port accepts 65535" valid_port "65535"
assert_fail "valid_port rejects 0" valid_port "0"
assert_fail "valid_port rejects 65536" valid_port "65536"
assert_fail "valid_port rejects letters" valid_port "ssh"
assert_ok "valid_port_list accepts empty" valid_port_list ""
assert_ok "valid_port_list accepts commas and spaces" valid_port_list "443, 8443 2001"
assert_fail "valid_port_list rejects bad member" valid_port_list "443,bad"
assert_eq "normalize_port_list canonicalizes" "443,8443,2001" "$(normalize_port_list "443, 8443 2001")"
assert_eq "normalize_port_list dedupes" "443" "$(normalize_port_list "443,443")"
assert_eq "normalize_port_list empty" "" "$(normalize_port_list "")"

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

# acme_mode_from_choice
assert_eq "ACME selector maps 1 to DNS-01" "dns-01" "$(acme_mode_from_choice 1)"
assert_eq "ACME selector maps dns to DNS-01" "dns-01" "$(acme_mode_from_choice dns)"
assert_eq "ACME selector maps 2 to HTTP-01" "http-01" "$(acme_mode_from_choice 2)"
assert_eq "ACME selector maps http-01 to HTTP-01" "http-01" "$(acme_mode_from_choice http-01)"
assert_fail "ACME selector rejects unknown choice" acme_mode_from_choice 3

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

# valid_egress_policy / valid_cert_key_type / valid_ike_unique
assert_ok "valid_egress_policy accepts internet-only" valid_egress_policy "internet-only"
assert_ok "valid_egress_policy accepts open" valid_egress_policy "open"
assert_fail "valid_egress_policy rejects unknown" valid_egress_policy "all"
assert_ok "valid_cert_key_type accepts ec256" valid_cert_key_type "ec256"
assert_fail "valid_cert_key_type rejects rsa1024" valid_cert_key_type "rsa1024"
assert_ok "valid_ike_unique accepts replace" valid_ike_unique "replace"
assert_fail "valid_ike_unique rejects always" valid_ike_unique "always"

# acme_keylength_for
assert_eq "acme_keylength_for rsa2048" "2048" "$(acme_keylength_for rsa2048)"
assert_eq "acme_keylength_for ec256" "ec-256" "$(acme_keylength_for ec256)"
assert_fail "acme_keylength_for rejects unknown" acme_keylength_for "rsa1024"

# cidr_overlaps
assert_ok "cidr_overlaps 10.20.20.0/24 inside 10.0.0.0/8" cidr_overlaps "10.20.20.0/24" "10.0.0.0/8"
assert_ok "cidr_overlaps is symmetric" cidr_overlaps "10.0.0.0/8" "10.20.20.0/24"
assert_fail "cidr_overlaps separate networks" cidr_overlaps "10.20.20.0/24" "192.168.1.0/24"
assert_ok "cidr_overlaps default route covers everything" cidr_overlaps "10.20.20.0/24" "0.0.0.0/0"

# conntrack_target_max
assert_eq "conntrack_target_max raises a low limit" "32768" "$(conntrack_target_max 7680)"
assert_eq "conntrack_target_max keeps a higher limit" "262144" "$(conntrack_target_max 262144)"
assert_eq "conntrack_target_max handles garbage" "32768" "$(conntrack_target_max "")"

# supported releases
assert_eq "supported_os_list lists tested releases" "22.04 24.04 26.04" "$(supported_os_list)"

# ---------------------------------------------------------------------------
# Helpers that read the user database and the proxy configuration. They are
# not pure, so they run against fixtures in a temporary directory.
# ---------------------------------------------------------------------------
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

USERS_DB="$FIXTURE_DIR/users.db"
MANAGER_DIR="$FIXTURE_DIR"
cat >"$USERS_DB" <<'FIXTURE_DB'
alice-pc|pw-alice|my-team|windows
bob-phone|pw-bob|my-team|ios
carl-pc|pw-carl|solo|windows
dana-pc|pw-dana|solo|ios
eve-pc|pw-eve||windows
FIXTURE_DB

# list_groups must not truncate an explicit hyphenated group name, and falls
# back to the username prefix only when the group field is empty.
assert_eq "list_groups keeps hyphenated groups" "eve
my-team
solo" "$(list_groups)"

# select_group_prompt is consumed through a command substitution, so its
# prompt and listing must not reach stdout.
assert_eq "select_group_prompt returns only the group by number" "my-team" \
  "$(printf '2\n' | select_group_prompt 2>/dev/null)"
assert_eq "select_group_prompt returns only the group by name" "solo" \
  "$(printf 'solo\n' | select_group_prompt 2>/dev/null)"
assert_fail "select_group_prompt rejects an unknown group" \
  bash -c 'printf "nope\n" | select_group_prompt' 2>/dev/null

assert_eq "get_group_users filters by group and platform" "bob-phone|pw-bob|my-team|ios" \
  "$(get_group_users "my-team" "ios")"

MT_CONFIG_FILE="$FIXTURE_DIR/config.toml"
cat >"$MT_CONFIG_FILE" <<'FIXTURE_TOML'
[server]
port = 1443
max_connections = 512

[censorship]
tls_domain = "rutube.ru"
mask = true
mask_port = 8443

[access.users]
alice = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
bob = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
FIXTURE_TOML

assert_eq "mt_user_secret returns the requested user" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$(mt_user_secret bob)"
assert_eq "mt_user_secret falls back to the first user" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "$(mt_user_secret "")"
assert_eq "mt_user_secret is empty for an unknown user" "" "$(mt_user_secret nobody)"
assert_eq "mt_list_users lists proxy users" "alice
bob" "$(mt_list_users)"

# mask_port lives in another section and must not be read as the listen port.
mt_load_config
assert_eq "mt_load_config reads the server port" "1443" "$MT_PORT"
assert_eq "mt_load_config reads the TLS domain" "rutube.ru" "$MT_TLS_DOMAIN"

# ---------------------------------------------------------------------------
# Generated artifacts.
# ---------------------------------------------------------------------------
FIREWALL_SCRIPT="$FIXTURE_DIR/apply-firewall.sh"
VPN_POOL_CIDR="10.20.20.0/24"
VPN_POOL6_CIDR="fd42:4242:4242:1::/112"
UPLINK_IF="eth0"
IPV6_MODE="nat"
CLIENT_ISOLATION="1"
EGRESS_POLICY="internet-only"
VPN_DNS="1.1.1.1,192.168.1.53"
ACME_MODE="http-01"
EGRESS_HOST_TCP_PORTS="2002"
EGRESS_HOST_UDP_PORTS=""
HARDEN_INPUT="1"
HARDEN_TCP_PORTS=""
HARDEN_UDP_PORTS=""
write_firewall_script

assert_ok "generated firewall script is valid bash" bash -n "$FIREWALL_SCRIPT"
assert_ok "generated firewall script carries the version marker" \
  grep -qF "$GENERATED_TAG: v$SCRIPT_VERSION" "$FIREWALL_SCRIPT"
assert_ok "generated firewall script opens TCP/80 for HTTP-01 renewal" \
  grep -q -- '--dport 80 -j ACCEPT' "$FIREWALL_SCRIPT"
assert_ok "generated firewall script allows DHCPv4 replies" \
  grep -q -- '--dport 68 -j ACCEPT' "$FIREWALL_SCRIPT"
assert_ok "generated firewall script blocks cloud metadata" \
  grep -q '169.254.0.0/16' "$FIREWALL_SCRIPT"
assert_ok "generated firewall script bakes in the SSH ports" \
  grep -q "^HARDEN_SSH_PORTS=" "$FIREWALL_SCRIPT"
assert_ok "generated firewall script keeps allowed host ports reachable" \
  grep -q "^EGRESS_HOST_TCP_PORTS='2002'" "$FIREWALL_SCRIPT"
# Dumping the live ruleset would persist rules owned by Docker or ufw.
if grep -qE 'iptables-save|netfilter-persistent save' "$FIREWALL_SCRIPT"; then
  fail "generated firewall script must not persist the ambient ruleset"
else
  pass
fi
if grep -qE 'iptables-save|netfilter-persistent save' "$TESTS_DIR/../scripts/ikev2-manager.sh"; then
  fail "manager must not persist the ambient ruleset"
else
  pass
fi

# generated_is_current must notice files written by another version.
assert_ok "generated_is_current accepts a current file" generated_is_current "$FIREWALL_SCRIPT"
printf '#!/usr/bin/env bash\n# %s: v0.0.1\n' "$GENERATED_TAG" >"$FIXTURE_DIR/stale.sh"
assert_fail "generated_is_current rejects an older file" generated_is_current "$FIXTURE_DIR/stale.sh"
assert_fail "generated_is_current rejects a missing file" generated_is_current "$FIXTURE_DIR/absent.sh"

if grep -q -- '--clear-creds' "$TESTS_DIR/../scripts/ikev2-manager.sh"; then
  fail "swanctl reload must use supported --clear option"
else
  pass
fi

# The function index is only useful while it matches the script.
if "$TESTS_DIR/../scripts/check-index.sh" >/dev/null; then
  pass
else
  fail "docs/INDEX.md is stale; run scripts/gen-index.sh"
fi

echo
echo "Passed: $PASSED, failed: $FAILED"
((FAILED == 0))
