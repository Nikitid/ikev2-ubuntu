#!/usr/bin/env bash
set -Euo pipefail
# Bash 5.2+ expands & in ${var//pat/repl} to the match by default,
# which corrupts replacements like &lt; in html_escape.
shopt -u patsub_replacement 2>/dev/null || true

SCRIPT_VERSION="1.4.0"
# Schema version of $CONFIG_FILE; migrate_config() upgrades older files.
CONFIG_VERSION="2"
# Marker written into every generated file so a newer script can detect and
# regenerate artifacts left behind by an older version.
GENERATED_TAG="ikev2-manager generated"
MANAGER_DIR="/opt/ikev2-manager"
CONFIG_FILE="$MANAGER_DIR/config.env"
ACME_ENV_FILE="$MANAGER_DIR/acme.env"
USERS_DB="$MANAGER_DIR/users.db"
EXPORTS_DIR="$MANAGER_DIR/exports"
CERT_RELOAD_SCRIPT="$MANAGER_DIR/reload-certificate.sh"
CERT_CHECK_SCRIPT="$MANAGER_DIR/check-certificate.sh"
CERT_CHECK_SERVICE="/etc/systemd/system/ikev2-manager-certcheck.service"
CERT_CHECK_TIMER="/etc/systemd/system/ikev2-manager-certcheck.timer"
MODULES_LOAD_FILE="/etc/modules-load.d/ikev2-manager.conf"
# Number of generations kept per backed up file; older copies hold private
# key material and are pruned.
BACKUP_KEEP="5"

# MTProto proxy manager paths
# Backend: mtproto.zig by Aleksandr Kalashnikov (sleep3r)
# Source:  https://github.com/sleep3r/mtproto.zig  License: MIT
MT_SERVICE="mtproto-proxy"
MT_BUDDY_BIN="/usr/local/bin/mtbuddy"
MT_INSTALL_DIR="/opt/mtproto-proxy"
MT_CONFIG_FILE="${MT_INSTALL_DIR}/config.toml"
MT_SERVICE_FILE="/etc/systemd/system/${MT_SERVICE}.service"
MT_DEFAULT_PORT="443"
MT_DEFAULT_TLS_DOMAIN="rutube.ru"
MT_BOOTSTRAP_URL="https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh"
# Optional pin: set to the expected sha256 of the bootstrap script to install
# without the interactive fingerprint confirmation.
MT_BOOTSTRAP_SHA256=""

SWANCTL_CONF="/etc/swanctl/swanctl.conf"
SWANCTL_X509_DIR="/etc/swanctl/x509"
SWANCTL_X509CA_DIR="/etc/swanctl/x509ca"
SWANCTL_PRIVATE_DIR="/etc/swanctl/private"
SYSCTL_FILE="/etc/sysctl.d/99-ikev2-manager.conf"
# Netfilter chains owned by this manager.
HARDEN_CHAIN="IKEV2_MGR_IN"
EGRESS_CHAIN="IKEV2_MGR_FWD"
HOST_CHAIN="IKEV2_MGR_HOST"
FIREWALL_SCRIPT="$MANAGER_DIR/apply-firewall.sh"
FIREWALL_SERVICE="/etc/systemd/system/ikev2-manager-firewall.service"
ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
# acme.sh is installed from a pinned upstream tag; the unpinned installer is
# only used as a fallback and requires an explicit confirmation.
ACME_VERSION="3.1.0"
ACME_INSTALLER_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/acme.sh"
ACME_INSTALLER_FALLBACK_URL="https://get.acme.sh"
SERVICE_NAME=""
LAST_ERROR=""
# Set by the non-interactive subcommands so prompts are skipped.
NONINTERACTIVE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
if command -v stty >/dev/null 2>&1; then
  stty iutf8 2>/dev/null || true
fi

# Defaults for v1 fixed scenario
DEFAULT_CONN_NAME="ikev2-eap"
DEFAULT_CERT_NAME="ikev2.pem"
DEFAULT_CERT_PATH="$SWANCTL_X509_DIR/ikev2.pem"
DEFAULT_CA_PATH="$MANAGER_DIR/issuer-chain.pem"
LEGACY_CA_PATH="$SWANCTL_X509CA_DIR/issuer-ca.pem"
DEFAULT_KEY_PATH="$SWANCTL_PRIVATE_DIR/ikev2.key"
CA_CHAIN_PREFIX="$SWANCTL_X509_DIR/ikev2-issuer"
CA_ROOT_PATH="$SWANCTL_X509CA_DIR/ikev2-root.pem"
DEFAULT_POOL_RANGE="10.20.20.10-10.20.20.250"
DEFAULT_POOL_CIDR="10.20.20.0/24"
# IPv6 behavior: block = clients tunnel IPv6 and the server drops it (no
# leaks on dual-stack clients), nat = full IPv6 via NAT66, off = IPv4 only.
DEFAULT_IPV6_MODE="block"
DEFAULT_POOL6_CIDR="fd42:4242:4242:1::/112"
DEFAULT_DNS_FALLBACK="1.1.1.1,1.0.0.1"
DEFAULT_ACME_MODE="dns-01"
DEFAULT_DPD_DELAY="30s"
DEFAULT_IKE_PROPOSALS="aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048"
DEFAULT_ESP_PROPOSALS="aes256gcm16-ecp384,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16,aes256-sha256-modp2048,aes256-sha256"
APPLE_REKEY_ESP_PROPOSALS="aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16"
DEFAULT_LOCAL_TS="0.0.0.0/0"
# Hairpinned client-to-client traffic is dropped unless explicitly disabled.
DEFAULT_CLIENT_ISOLATION="1"
# Inbound hardening appends a default-drop allowlist chain to INPUT.
DEFAULT_HARDEN_INPUT="0"
# Egress policy for the client pool. internet-only drops traffic aimed at
# link-local/metadata and private networks (and at this host itself), open
# keeps the historic behaviour of routing everything.
DEFAULT_EGRESS_POLICY="internet-only"
# Networks a VPN client must not reach through the tunnel under
# internet-only. Configured client DNS servers are exempted at rule build
# time so a resolver on a private network keeps working.
EGRESS_BLOCKED_V4="169.254.0.0/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8"
EGRESS_BLOCKED_V6="fe80::/10 fc00::/7 ::1/128"
# Ports on the VPN host itself that clients may still reach under
# internet-only (for example SSH administered over the tunnel). DNS is
# always allowed so a resolver running on the host keeps working.
DEFAULT_EGRESS_HOST_TCP_PORTS=""
DEFAULT_EGRESS_HOST_UDP_PORTS=""
DEFAULT_CERT_KEY_TYPE="rsa2048"
# unique = never keeps historic behaviour: several parallel sessions per
# identity. replace disconnects the previous session of the same identity.
DEFAULT_IKE_UNIQUE="never"
# Keep enough conntrack capacity for short NAT/VPN traffic bursts on small VPS
# instances. Existing higher administrator-defined limits are preserved.
MIN_CONNTRACK_MAX="32768"
# Ubuntu LTS releases this script is tested against.
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04" "26.04")

# The menu header shows the failure of the most recent action. Errors are
# recorded explicitly by report_error() where they are reported: a global ERR
# trap also caught benign non-zero statuses (an empty grep, a missing
# interface) and turned them into misleading "last error" lines.

# Reports a failure to the operator and remembers it for the menu header.
report_error() {
  local message="$1"
  LAST_ERROR="$message"
  echo "$message"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
  fi
}

ensure_manager_dir() {
  mkdir -p "$MANAGER_DIR"
  chmod 700 "$MANAGER_DIR"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  CONN_NAME="${CONN_NAME:-$DEFAULT_CONN_NAME}"
  CERT_NAME="${CERT_NAME:-$DEFAULT_CERT_NAME}"
  CERT_PATH="${CERT_PATH:-$DEFAULT_CERT_PATH}"
  CA_PATH="${CA_PATH:-$DEFAULT_CA_PATH}"
  if [[ "$CA_PATH" == "$LEGACY_CA_PATH" ]]; then
    CA_PATH="$DEFAULT_CA_PATH"
  fi
  KEY_PATH="${KEY_PATH:-$DEFAULT_KEY_PATH}"
  VPN_POOL_RANGE="${VPN_POOL_RANGE:-$DEFAULT_POOL_RANGE}"
  VPN_POOL_CIDR="${VPN_POOL_CIDR:-$DEFAULT_POOL_CIDR}"
  IPV6_MODE="${IPV6_MODE:-$DEFAULT_IPV6_MODE}"
  VPN_POOL6_CIDR="${VPN_POOL6_CIDR:-$DEFAULT_POOL6_CIDR}"
  ACME_MODE="${ACME_MODE:-$DEFAULT_ACME_MODE}"
  VPN_DNS="${VPN_DNS:-$(detect_default_dns || true)}"
  VPN_DNS="${VPN_DNS:-$DEFAULT_DNS_FALLBACK}"
  DPD_DELAY="${DPD_DELAY:-$DEFAULT_DPD_DELAY}"
  IKE_PROPOSALS="${IKE_PROPOSALS:-$DEFAULT_IKE_PROPOSALS}"
  ESP_PROPOSALS="${ESP_PROPOSALS:-$DEFAULT_ESP_PROPOSALS}"
  ESP_PROPOSALS="$(ensure_apple_esp_proposals "$ESP_PROPOSALS")"
  LOCAL_TS="${LOCAL_TS:-$DEFAULT_LOCAL_TS}"
  CLIENT_ISOLATION="${CLIENT_ISOLATION:-$DEFAULT_CLIENT_ISOLATION}"
  HARDEN_INPUT="${HARDEN_INPUT:-$DEFAULT_HARDEN_INPUT}"
  HARDEN_TCP_PORTS="${HARDEN_TCP_PORTS:-}"
  HARDEN_UDP_PORTS="${HARDEN_UDP_PORTS:-}"
  EGRESS_POLICY="${EGRESS_POLICY:-$DEFAULT_EGRESS_POLICY}"
  EGRESS_HOST_TCP_PORTS="${EGRESS_HOST_TCP_PORTS:-$DEFAULT_EGRESS_HOST_TCP_PORTS}"
  EGRESS_HOST_UDP_PORTS="${EGRESS_HOST_UDP_PORTS:-$DEFAULT_EGRESS_HOST_UDP_PORTS}"
  CERT_KEY_TYPE="${CERT_KEY_TYPE:-$DEFAULT_CERT_KEY_TYPE}"
  IKE_UNIQUE="${IKE_UNIQUE:-$DEFAULT_IKE_UNIQUE}"
  MANAGED_PACKAGES="${MANAGED_PACKAGES:-}"
  UPLINK_IF="${UPLINK_IF:-$(detect_uplink_if || true)}"
  UPLINK_IF="${UPLINK_IF:-}"
  INSTALLED="${INSTALLED:-0}"
  CONFIG_SCHEMA="${CONFIG_SCHEMA:-1}"
}

# Config files written before schema 2 simply lack the newer keys; the
# defaults applied in load_config() are the migration. The stored schema
# number is refreshed on the next save_config().
migrate_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  [[ "${CONFIG_SCHEMA:-1}" != "$CONFIG_VERSION" ]] || return 0
  CONFIG_SCHEMA="$CONFIG_VERSION"
  save_config
}

effective_installed() {
  [[ "${INSTALLED:-0}" == "1" && -f "$CONFIG_FILE" && -f "$SWANCTL_CONF" ]]
}

save_config() {
  ensure_manager_dir
  {
    printf 'INSTALLED=%q\n' "${INSTALLED:-0}"
    printf 'DOMAIN=%q\n' "${DOMAIN:-}"
    printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL:-}"
    printf 'ACME_MODE=%q\n' "${ACME_MODE:-}"
    printf 'DNS_PROVIDER=%q\n' "${DNS_PROVIDER:-}"
    printf 'CONN_NAME=%q\n' "${CONN_NAME:-}"
    printf 'CERT_NAME=%q\n' "${CERT_NAME:-}"
    printf 'CERT_PATH=%q\n' "${CERT_PATH:-}"
    printf 'CA_PATH=%q\n' "${CA_PATH:-}"
    printf 'KEY_PATH=%q\n' "${KEY_PATH:-}"
    printf 'VPN_POOL_RANGE=%q\n' "${VPN_POOL_RANGE:-}"
    printf 'VPN_POOL_CIDR=%q\n' "${VPN_POOL_CIDR:-}"
    printf 'IPV6_MODE=%q\n' "${IPV6_MODE:-}"
    printf 'VPN_POOL6_CIDR=%q\n' "${VPN_POOL6_CIDR:-}"
    printf 'VPN_DNS=%q\n' "${VPN_DNS:-}"
    printf 'UPLINK_IF=%q\n' "${UPLINK_IF:-}"
    printf 'DPD_DELAY=%q\n' "${DPD_DELAY:-}"
    printf 'IKE_PROPOSALS=%q\n' "${IKE_PROPOSALS:-}"
    printf 'ESP_PROPOSALS=%q\n' "${ESP_PROPOSALS:-}"
    printf 'LOCAL_TS=%q\n' "${LOCAL_TS:-}"
    printf 'CLIENT_ISOLATION=%q\n' "${CLIENT_ISOLATION:-}"
    printf 'HARDEN_INPUT=%q\n' "${HARDEN_INPUT:-}"
    printf 'HARDEN_TCP_PORTS=%q\n' "${HARDEN_TCP_PORTS:-}"
    printf 'HARDEN_UDP_PORTS=%q\n' "${HARDEN_UDP_PORTS:-}"
    printf 'EGRESS_POLICY=%q\n' "${EGRESS_POLICY:-$DEFAULT_EGRESS_POLICY}"
    printf 'EGRESS_HOST_TCP_PORTS=%q\n' "${EGRESS_HOST_TCP_PORTS:-}"
    printf 'EGRESS_HOST_UDP_PORTS=%q\n' "${EGRESS_HOST_UDP_PORTS:-}"
    printf 'CERT_KEY_TYPE=%q\n' "${CERT_KEY_TYPE:-$DEFAULT_CERT_KEY_TYPE}"
    printf 'IKE_UNIQUE=%q\n' "${IKE_UNIQUE:-$DEFAULT_IKE_UNIQUE}"
    printf 'MANAGED_PACKAGES=%q\n' "${MANAGED_PACKAGES:-}"
    printf 'CONFIG_SCHEMA=%q\n' "$CONFIG_VERSION"
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

os_supported() {
  [[ -f /etc/os-release ]] || return 1
  local os_id version_id supported
  os_id=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
  version_id=$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
  [[ "$os_id" == "ubuntu" ]] || return 1
  for supported in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
    [[ "$version_id" == "$supported" ]] && return 0
  done
  return 1
}

supported_os_list() {
  local IFS=' '
  printf '%s' "${SUPPORTED_UBUNTU_VERSIONS[*]}"
}

os_label() {
  if [[ -f /etc/os-release ]]; then
    local name version_id
    name=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
    echo "$name"
  else
    echo "unknown"
  fi
}

detect_service_name() {
  if [[ -f /usr/lib/systemd/system/strongswan.service || -f /lib/systemd/system/strongswan.service || -f /etc/systemd/system/strongswan.service ]]; then
    echo "strongswan"
    return 0
  fi
  if [[ -f /usr/lib/systemd/system/strongswan-swanctl.service || -f /lib/systemd/system/strongswan-swanctl.service || -f /etc/systemd/system/strongswan-swanctl.service ]]; then
    echo "strongswan-swanctl"
    return 0
  fi
  echo "strongswan"
}

service_active() {
  SERVICE_NAME="$(detect_service_name)"
  systemctl is-active --quiet "${SERVICE_NAME}.service"
}

restart_vpn_service() {
  local service_name
  service_name="$(detect_service_name)"

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "${service_name}.service" >/dev/null 2>&1 || true
  systemctl restart "${service_name}.service"
}

detect_uplink_if() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

detect_default_dns() {
  local dns_list=""
  if command -v resolvectl >/dev/null 2>&1; then
    dns_list=$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | awk '!seen[$0]++' | paste -sd, -)
  fi
  if [[ -z "$dns_list" ]]; then
    dns_list=$(awk '/^nameserver /{print $2}' /etc/resolv.conf 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^127\.' | awk '!seen[$0]++' | paste -sd, -)
  fi
  echo "$dns_list"
}

normalize_dns_list() {
  local input="$1" out="" part keep
  local -a __parts=()
  input="${input// /}"
  input="${input//;/,}"
  while IFS=',' read -r -a __parts; do
    for part in "${__parts[@]+"${__parts[@]}"}"; do
      keep=0
      # Loopback and unspecified addresses are useless as client DNS.
      if [[ "$part" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ! "$part" =~ ^(127\.|0\.) ]]; then
        keep=1
      elif [[ "$part" == *:* && "$part" != "::" && "$part" != "::1" ]] && valid_ipv6 "$part"; then
        keep=1
      fi
      ((keep)) || continue
      if [[ -z "$out" ]]; then
        out="$part"
      else
        case ",$out," in
          *",$part,"*) ;;
          *) out+=",$part" ;;
        esac
      fi
    done
    break
  done <<<"$input"
  echo "$out"
}

csv_list_contains() {
  local list="${1// /}" item="$2"
  case ",$list," in
    *",$item,"*) return 0 ;;
    *) return 1 ;;
  esac
}

append_missing_csv_items() {
  local list="${1// /}" required="$2" item
  local IFS=','
  for item in $required; do
    [[ -n "$item" ]] || continue
    if ! csv_list_contains "$list" "$item"; then
      list+="${list:+,}$item"
    fi
  done
  printf '%s' "$list"
}

ensure_apple_esp_proposals() {
  local proposals="${1:-$DEFAULT_ESP_PROPOSALS}"
  append_missing_csv_items "$proposals" "$APPLE_REKEY_ESP_PROPOSALS"
}

conntrack_target_max() {
  local current="${1:-0}"
  if [[ "$current" =~ ^[0-9]+$ ]] && ((current > MIN_CONNTRACK_MAX)); then
    printf '%s' "$current"
  else
    printf '%s' "$MIN_CONNTRACK_MAX"
  fi
}

conntrack_status() {
  local count max usage status
  count="$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || true)"
  max="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)"
  if [[ ! "$count" =~ ^[0-9]+$ || ! "$max" =~ ^[1-9][0-9]*$ ]]; then
    printf 'unavailable'
    return 0
  fi

  usage=$((count * 100 / max))
  status="${count}/${max} (${usage}%)"
  if ((max < MIN_CONNTRACK_MAX)); then
    status+="; limit below ${MIN_CONNTRACK_MAX}"
  elif ((usage >= 90)); then
    status+="; critical"
  elif ((usage >= 70)); then
    status+="; warning"
  fi
  printf '%s' "$status"
}

# Drop IPv6 resolvers from a comma-separated DNS list; they are unreachable
# for clients unless full IPv6 (nat mode) is enabled.
dns_list_drop_ipv6() {
  local out="" part
  local IFS=','
  for part in $1; do
    [[ "$part" == *:* ]] && continue
    out+="${out:+,}$part"
  done
  printf '%s' "$out"
}

valid_ipv4() {
  local ip="$1" o1 o2 o3 o4 oct IFS=.
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r o1 o2 o3 o4 <<<"$ip"
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    ((10#$oct >= 0 && 10#$oct <= 255)) || return 1
  done
}

ip_to_int() {
  local o1 o2 o3 o4 IFS=.
  read -r o1 o2 o3 o4 <<<"$1"
  echo $(((10#$o1 << 24) | (10#$o2 << 16) | (10#$o3 << 8) | 10#$o4))
}

cidr_contains() {
  local cidr="$1" ip="$2" base prefix mask net
  base="${cidr%/*}"
  prefix="${cidr#*/}"
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  fi
  net=$(($(ip_to_int "$base") & mask))
  ((($(ip_to_int "$ip") & mask) == net))
}

# True when two IPv4 CIDRs share any address.
cidr_overlaps() {
  local a="$1" b="$2" a_prefix b_prefix prefix mask
  a_prefix="${a#*/}"
  b_prefix="${b#*/}"
  prefix=$((a_prefix < b_prefix ? a_prefix : b_prefix))
  if ((prefix == 0)); then
    return 0
  fi
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  ((($(ip_to_int "${a%%/*}") & mask) == ($(ip_to_int "${b%%/*}") & mask)))
}

# Networks already configured on this host that would collide with the pool.
conflicting_local_networks() {
  local candidate cidr
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    valid_cidr "$candidate" || continue
    if cidr_overlaps "$1" "$candidate"; then
      printf '%s\n' "$candidate"
    fi
  done < <(ip -4 -o addr show 2>/dev/null | awk '{print $4}')
}

valid_ipv6() {
  local ip="$1" head tail g
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  # A lone leading/trailing colon is only allowed as part of "::".
  [[ "$ip" == :* && "$ip" != ::* ]] && return 1
  [[ "$ip" == *: && "$ip" != *:: ]] && return 1
  if [[ "$ip" == *::* ]]; then
    [[ "$ip" == *::*::* || "$ip" == *:::* ]] && return 1
    head="${ip%%::*}"
    tail="${ip#*::}"
    local -a hg=() tg=()
    [[ -n "$head" ]] && IFS=':' read -r -a hg <<<"$head"
    [[ -n "$tail" ]] && IFS=':' read -r -a tg <<<"$tail"
    for g in "${hg[@]+"${hg[@]}"}"; do
      [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    for g in "${tg[@]+"${tg[@]}"}"; do
      [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    ((${#hg[@]} + ${#tg[@]} <= 7))
  else
    local -a gs=()
    IFS=':' read -r -a gs <<<"$ip"
    ((${#gs[@]} == 8)) || return 1
    for g in "${gs[@]}"; do
      [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
  fi
}

valid_ipv6_cidr() {
  local cidr="$1" ip prefix
  [[ "$cidr" =~ ^([^/]+)/([0-9]{1,3})$ ]] || return 1
  ip="${BASH_REMATCH[1]}"
  prefix="${BASH_REMATCH[2]}"
  valid_ipv6 "$ip" || return 1
  ((10#$prefix >= 0 && 10#$prefix <= 128))
}

valid_ipv6_mode() {
  case "$1" in
    off | block | nat) return 0 ;;
    *) return 1 ;;
  esac
}

host_has_global_ipv6() {
  ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1
}

valid_cidr() {
  local cidr="$1" ip prefix
  [[ "$cidr" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
  ip="${BASH_REMATCH[1]}"
  prefix="${BASH_REMATCH[2]}"
  valid_ipv4 "$ip" || return 1
  ((prefix >= 0 && prefix <= 32)) || return 1
}

valid_range() {
  local range="$1" start end
  [[ "$range" =~ ^([^,]+)-([^,]+)$ ]] || return 1
  start="${BASH_REMATCH[1]}"
  end="${BASH_REMATCH[2]}"
  valid_ipv4 "$start" || return 1
  valid_ipv4 "$end" || return 1
  (($(ip_to_int "$start") <= $(ip_to_int "$end")))
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ((10#$1 >= 1 && 10#$1 <= 65535))
}

# Comma/space separated TCP/UDP port list; empty input is valid (no ports).
valid_port_list() {
  local list="$1" port
  list="${list//,/ }"
  for port in $list; do
    valid_port "$port" || return 1
  done
}

# Canonical form: comma-separated, duplicates removed, original order kept.
normalize_port_list() {
  local list="$1" port out=""
  list="${list//,/ }"
  for port in $list; do
    case ",$out," in
      *",$port,"*) ;;
      *) out+="${out:+,}$port" ;;
    esac
  done
  printf '%s' "$out"
}

valid_domain_name() {
  local d="$1" label
  local labels=()
  local IFS='.'

  [[ -n "$d" ]] || return 1
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$d" == *.* ]] || return 1
  [[ "$d" != .* && "$d" != *. ]] || return 1
  [[ "$d" != *..* ]] || return 1

  read -r -a labels <<<"$d"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

valid_dns_provider() {
  [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

valid_username() {
  local u="$1"
  [[ -n "$u" ]] || return 1
  [[ "$u" =~ ^[A-Za-z0-9._@-]+$ ]] || return 1
}

valid_group_name() {
  local g="$1"
  [[ -n "$g" ]] || return 1
  [[ "$g" =~ ^[A-Za-z0-9._@-]+$ ]] || return 1
}

valid_platform() {
  case "$1" in
    windows | ios | macos | ubuntu | unknown) return 0 ;;
    *) return 1 ;;
  esac
}

valid_egress_policy() {
  case "$1" in
    internet-only | open) return 0 ;;
    *) return 1 ;;
  esac
}

valid_cert_key_type() {
  case "$1" in
    rsa2048 | rsa3072 | rsa4096 | ec256 | ec384) return 0 ;;
    *) return 1 ;;
  esac
}

# acme.sh spells key types differently from the config value.
acme_keylength_for() {
  case "$1" in
    rsa2048) printf '2048' ;;
    rsa3072) printf '3072' ;;
    rsa4096) printf '4096' ;;
    ec256) printf 'ec-256' ;;
    ec384) printf 'ec-384' ;;
    *) return 1 ;;
  esac
}

valid_ike_unique() {
  case "$1" in
    never | no | keep | replace) return 0 ;;
    *) return 1 ;;
  esac
}

strongswan_version() {
  local raw
  raw="$(swanctl --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$raw" ]] || return 1
  printf '%s' "$raw"
}

# Compares the running strongSwan against major.minor.patch arguments.
strongswan_at_least() {
  local want_major="$1" want_minor="$2" want_patch="${3:-0}"
  local version major minor patch
  version="$(strongswan_version)" || return 1
  IFS=. read -r major minor patch <<<"$version"
  ((10#${major:-0} > want_major)) && return 0
  ((10#${major:-0} < want_major)) && return 1
  ((10#${minor:-0} > want_minor)) && return 0
  ((10#${minor:-0} < want_minor)) && return 1
  ((10#${patch:-0} >= want_patch))
}

infer_group_from_username() {
  local u="$1"
  u="${u%%-*}"
  [[ -n "$u" ]] && printf '%s\n' "$u" || printf 'default\n'
}

normalize_platform() {
  local p
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    win | windows | pc) echo "windows" ;;
    iphone | ios | ipad | phone) echo "ios" ;;
    mac | macos) echo "macos" ;;
    linux | ubuntu) echo "ubuntu" ;;
    "") echo "unknown" ;;
    *) echo "$p" ;;
  esac
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# Prints a multi-line value indented, one line per row.
print_indented() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  %s\n' "$line"
  done <<<"$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s-%s-%s\n' \
      "$(openssl rand -hex 4)" \
      "$(openssl rand -hex 2)" \
      "$(openssl rand -hex 2)" \
      "$(openssl rand -hex 2)" \
      "$(openssl rand -hex 6)"
  fi
}

interface_exists() {
  ip link show "$1" >/dev/null 2>&1
}

detect_topology_hint() {
  local ip
  ip=$(ip -4 addr show dev "${UPLINK_IF:-}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
  if [[ -z "$ip" ]]; then
    echo "unknown"
    return 0
  fi
  case "$ip" in
    10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].*) echo "private/NAT likely ($ip)" ;;
    *) echo "public-ish ($ip)" ;;
  esac
}

count_users() {
  [[ -f "$USERS_DB" ]] || {
    echo 0
    return 0
  }
  awk -F'[|\t]' 'NF && $1 !~ /^[[:space:]]*$/ && $1 != "username" {c++} END{print c+0}' "$USERS_DB"
}

cert_public_key_alg() {
  [[ -f "$CERT_PATH" ]] || return 1
  openssl x509 -in "$CERT_PATH" -text -noout 2>/dev/null | awk -F': ' '/Public Key Algorithm/{print $2; exit}'
}

cert_days_left() {
  [[ -f "$CERT_PATH" ]] || return 1
  local end_epoch now_epoch end_raw
  end_raw=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2-)
  [[ -n "$end_raw" ]] || return 1
  end_epoch=$(date -d "$end_raw" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  echo $(((end_epoch - now_epoch) / 86400))
}

cert_issuer_cn() {
  [[ -f "$CERT_PATH" ]] || return 1
  openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null \
    | sed -nE 's/.*CN[[:space:]]*=[[:space:]]*([^,/]+).*/\1/p'
}

ca_chain_file_count() {
  local file count=0
  for file in "${CA_CHAIN_PREFIX}"-*.pem; do
    [[ -f "$file" ]] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

has_nat_rule() {
  [[ -n "${UPLINK_IF:-}" ]] || return 1
  iptables -t nat -C POSTROUTING -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j MASQUERADE >/dev/null 2>&1
}

has_forward_rule_out() {
  [[ -n "${UPLINK_IF:-}" ]] || return 1
  iptables -C FORWARD -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j ACCEPT >/dev/null 2>&1
}

has_forward_rule_in() {
  [[ -n "${UPLINK_IF:-}" ]] || return 1
  iptables -C FORWARD -d "$VPN_POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT >/dev/null 2>&1
}

has_mss_clamp_rule() {
  iptables -t mangle -C FORWARD -s "$VPN_POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
}

has_isolation_rule() {
  iptables -C FORWARD -s "$VPN_POOL_CIDR" -d "$VPN_POOL_CIDR" -j DROP >/dev/null 2>&1
}

has_harden_chain() {
  iptables -C INPUT -j "$HARDEN_CHAIN" >/dev/null 2>&1
}

has_egress_chain() {
  iptables -C FORWARD -s "$VPN_POOL_CIDR" -j "$EGRESS_CHAIN" >/dev/null 2>&1
}

has_host_chain() {
  iptables -C INPUT -s "$VPN_POOL_CIDR" -j "$HOST_CHAIN" >/dev/null 2>&1
}

# Rule helpers used by the manager itself (the generated firewall script
# carries its own copies so it stays standalone).
ipt_del_rule() {
  local tool="$1" table="$2" chain="$3"
  shift 3
  while "$tool" -t "$table" -C "$chain" "$@" >/dev/null 2>&1; do
    "$tool" -t "$table" -D "$chain" "$@" || break
  done
}

ipt_drop_chain() {
  local tool="$1" parent="$2" chain="$3"
  shift 3
  ipt_del_rule "$tool" filter "$parent" "$@" -j "$chain"
  "$tool" -F "$chain" 2>/dev/null || true
  "$tool" -X "$chain" 2>/dev/null || true
}

status_line() {
  local label="$1"
  local value="$2"
  printf "${YELLOW}%-20s ${GREEN}%s${NC}
" "$label" "$value"
}

menu_item() {
  local key="$1"
  local text="$2"
  echo -e "${CYAN}${key})${NC} ${text}"
}

menu_enter_hint() {
  local text="$1"
  echo -e "${CYAN}Enter${NC} ${text}"
}

read_menu_choice() {
  local __var="$1"
  local __choice
  echo -en "${YELLOW}Select:${NC} "
  read -r __choice || true
  # The header shows the error of the action that is about to run, not of an
  # action several screens back.
  LAST_ERROR=""
  printf -v "$__var" '%s' "$__choice"
}

acme_mode_from_choice() {
  local choice
  choice="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$choice" in
    1 | dns | dns-01) printf 'dns-01' ;;
    2 | http | http-01) printf 'http-01' ;;
    *) return 1 ;;
  esac
}

select_acme_mode() {
  local __var="$1"
  local current="${2:-$DEFAULT_ACME_MODE}"
  local choice selected

  echo "ACME validation mode"
  echo "--------------------"
  menu_item 1 "DNS-01 — DNS API credentials; no inbound port 80 required"
  menu_item 2 "HTTP-01 — standalone validation; requires inbound TCP/80"
  echo
  echo "Current: $current (press Enter to keep)"

  while true; do
    read_menu_choice choice
    if [[ -z "$choice" ]]; then
      selected="$current"
      break
    fi
    if selected="$(acme_mode_from_choice "$choice")"; then
      break
    fi
    echo -e "${YELLOW}Select 1 for DNS-01 or 2 for HTTP-01.${NC}"
  done
  printf -v "$__var" '%s' "$selected"
}

invalid_choice() {
  echo -e "${YELLOW}Invalid choice.${NC}"
  sleep 1
}

render_header() {
  ((NONINTERACTIVE)) || clear
  load_config

  local install_state service_status cert_state users_state firewall_state auth_state quick_state topology_state os_state
  os_state="$(os_label)"
  topology_state="$(detect_topology_hint)"

  if effective_installed; then
    install_state="installed"
  else
    install_state="not installed"
  fi

  echo -e "${CYAN}ikev2-ubuntu${NC}"
  printf '%27b\n' "${WHITE}v${SCRIPT_VERSION}${NC}"
  echo

  if [[ "$install_state" != "installed" ]]; then
    status_line "Install status:" "$install_state"
    status_line "OS:" "$os_state"
    status_line "Topology hint:" "$topology_state"
    status_line "MTProto proxy:" "$(mt_service_status)"
    echo
    if [[ -n "$LAST_ERROR" ]]; then
      printf "${RED}Last error:${NC} %s\n\n" "$LAST_ERROR"
    fi
    return 0
  fi

  if service_active; then
    service_status="active/running"
  else
    local act sub
    SERVICE_NAME="$(detect_service_name)"
    act="$(systemctl show -p ActiveState --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
    if [[ -n "$act" && -n "$sub" ]]; then
      service_status="${act}/${sub}"
    elif [[ -n "$act" ]]; then
      service_status="$act"
    else
      service_status="inactive"
    fi
  fi

  if [[ -f "$CERT_PATH" ]]; then
    cert_state="$(cert_public_key_alg || echo unknown)"
    if days=$(cert_days_left 2>/dev/null); then
      cert_state+="; ${days}d left"
    fi
  else
    cert_state="missing"
  fi

  users_state="$(count_users)"
  firewall_state="$(has_nat_rule && echo yes || echo no)/$(has_forward_rule_out && has_forward_rule_in && echo yes || echo no)/$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
  auth_state="IKEv2 / EAP-MSCHAPv2"
  quick_state="${VPN_POOL_RANGE:-unset} | ${VPN_DNS:-unset}"

  status_line "Install status:" "$install_state"
  status_line "Service status:" "$service_status"
  status_line "Domain:" "${DOMAIN:-unset}"
  status_line "VPN users:" "$users_state"
  status_line "Certificate:" "$cert_state"
  status_line "Firewall:" "$firewall_state"
  status_line "Auth:" "$auth_state"
  status_line "Pool / DNS:" "$quick_state"
  status_line "IPv6 mode:" "${IPV6_MODE:-off}"
  status_line "Egress policy:" "${EGRESS_POLICY:-internet-only}"
  status_line "MTProto proxy:" "$(mt_service_status)"
  echo
  if [[ -n "$LAST_ERROR" ]]; then
    printf "${RED}Last error:${NC} %s\n\n" "$LAST_ERROR"
  fi
}
pause() {
  ((NONINTERACTIVE)) && return 0
  read -r -p "Press Enter to continue..." _
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer || true
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer || true
    echo "$answer"
  fi
}

# Secrets must not end up in the terminal scrollback or in a recorded
# session, so they are read without echo.
ask_secret() {
  local prompt="$1" answer
  read -r -s -p "$prompt: " answer || true
  echo >&2
  printf '%s' "$answer"
}

ask_secret_multiline_generic() {
  local line
  echo -e "${YELLOW}Enter KEY=VALUE lines. Empty line finishes input.${NC}"
  : >"$ACME_ENV_FILE"
  chmod 600 "$ACME_ENV_FILE"
  while true; do
    read -r -s -p "> " line || true
    echo
    [[ -z "$line" ]] && break
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]]; then
      echo "Invalid format. Use KEY=VALUE."
      continue
    fi
    local key value
    key="${line%%=*}"
    value="${line#*=}"
    printf 'export %s=%q
' "$key" "$value" >>"$ACME_ENV_FILE"
  done
}

ask_acme_provider_env() {
  ensure_manager_dir
  : >"$ACME_ENV_FILE"
  chmod 600 "$ACME_ENV_FILE"

  case "$DNS_PROVIDER" in
    dns_timeweb)
      local token
      while true; do
        token="$(ask_secret "Timeweb Cloud JWT token")"
        [[ -n "$token" ]] && break
        echo "Token cannot be empty."
      done
      printf 'export TW_Token=%q\n' "$token" >"$ACME_ENV_FILE"
      ;;
    "")
      return 0
      ;;
    *)
      echo "Provider variables for $DNS_PROVIDER"
      ask_secret_multiline_generic
      ;;
  esac
}
backup_file() {
  local target="$1"
  local backup_dir backup_name
  [[ -f "$target" ]] || return 0
  backup_dir="$MANAGER_DIR/backups"
  backup_name="${target#/}"
  backup_name="${backup_name//\//_}"
  ensure_manager_dir
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  cp -a "$target" "$backup_dir/${backup_name}.bak.$(date +%Y%m%d-%H%M%S)"
  prune_backups "$backup_dir" "${backup_name}.bak.*"
}

# Old certificates and private keys are liabilities; keep only the most
# recent $BACKUP_KEEP generations of each backed up file.
prune_backups() {
  local backup_dir="$1" pattern="$2" file
  [[ -d "$backup_dir" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    rm -f -- "$file"
  done < <(find "$backup_dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n "+$((BACKUP_KEEP + 1))" | cut -d' ' -f2-)
}

# Downloads a remote installer and refuses to run it unattended: the operator
# sees the fingerprint of the exact bytes that are about to be executed.
fetch_and_confirm_script() {
  local url="$1" dest="$2" expected_sha="${3:-}" actual_sha ans

  curl -fsSL "$url" -o "$dest" || return 1
  [[ -s "$dest" ]] || return 1

  actual_sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
  if [[ -n "$expected_sha" ]]; then
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      echo "Checksum mismatch for $url"
      echo "expected: $expected_sha"
      echo "actual:   $actual_sha"
      return 1
    fi
    return 0
  fi

  echo
  echo "About to execute a script downloaded from:"
  echo "  $url"
  echo "  sha256: ${actual_sha:-unavailable}"
  echo "  size:   $(wc -c <"$dest") bytes"
  read -r -p "Execute it? [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

write_certificate_reload_script() {
  ensure_manager_dir
  cat >"$CERT_RELOAD_SCRIPT" <<EOF_RELOAD
#!/usr/bin/env bash
# ${GENERATED_TAG}: v${SCRIPT_VERSION}
set -Eeuo pipefail
umask 077

# acme.sh runs this from cron with its output discarded, so a failure here
# has to leave a trace in the journal instead of vanishing.
trap 'logger -t ikev2-manager -p daemon.err "certificate reload failed (line \$LINENO: \$BASH_COMMAND)" 2>/dev/null || true' ERR

ca_bundle='${CA_PATH}'
chain_prefix='${CA_CHAIN_PREFIX}'
root_path='${CA_ROOT_PATH}'
cert_path='${CERT_PATH}'
legacy_ca_bundle='${LEGACY_CA_PATH}'
swanctl_conf='${SWANCTL_CONF}'
service_name='$(detect_service_name)'
backup_dir='${MANAGER_DIR}/backups/credentials'
x509_dir='${SWANCTL_X509_DIR}'
x509ca_dir='${SWANCTL_X509CA_DIR}'
private_dir='${SWANCTL_PRIVATE_DIR}'

[[ -s "\$ca_bundle" ]]
mkdir -p "\$backup_dir"
chmod 700 "\$backup_dir"

for directory in "\$x509_dir" "\$x509ca_dir" "\$private_dir"; do
  while IFS= read -r backup; do
    name="\${directory##*/}-\${backup##*/}"
    mv "\$backup" "\$backup_dir/\$name"
  done < <(find "\$directory" -maxdepth 1 -type f -name '*.bak.*' -print)
done

if [[ -f "\$legacy_ca_bundle" && "\$legacy_ca_bundle" != "\$ca_bundle" ]]; then
  mv "\$legacy_ca_bundle" "\$backup_dir/legacy-issuer-ca.pem"
fi
for old_chain in "\$x509ca_dir"/ikev2-chain-*.pem; do
  [[ -f "\$old_chain" ]] || continue
  mv "\$old_chain" "\$backup_dir/\${old_chain##*/}"
done

for old_chain in "\${chain_prefix}"-*.pem; do
  [[ -f "\$old_chain" ]] || continue
  mv "\$old_chain" "\$backup_dir/\${old_chain##*/}.old"
done

# Old chains and keys accumulate on every renewal; keep a bounded history.
find "\$backup_dir" -maxdepth 1 -type f -printf '%T@ %p\\n' 2>/dev/null \
  | sort -rn | tail -n "+$((BACKUP_KEEP * 4 + 1))" | cut -d' ' -f2- \
  | while IFS= read -r stale; do rm -f -- "\$stale"; done
awk -v prefix="\$chain_prefix" '
  /-----BEGIN CERTIFICATE-----/ {
    count++
    output = sprintf("%s-%02d.pem", prefix, count)
  }
  output != "" { print > output }
  /-----END CERTIFICATE-----/ {
    close(output)
    output = ""
  }
  END { if (count == 0 || output != "") exit 1 }
' "\$ca_bundle"
chmod 644 "\${chain_prefix}"-*.pem

last_chain=""
for file in "\${chain_prefix}"-*.pem; do
  [[ -f "\$file" ]] || continue
  last_chain="\$file"
done
[[ -n "\$last_chain" ]]

issuer_hash="\$(openssl x509 -in "\$last_chain" -noout -issuer_hash)"
system_root="/etc/ssl/certs/\${issuer_hash}.0"
[[ -f "\$system_root" ]]
root_tmp="\${root_path}.tmp.\$\$"
cp -L "\$system_root" "\$root_tmp"
chmod 644 "\$root_tmp"
mv -f "\$root_tmp" "\$root_path"

openssl verify -CAfile "\$root_path" -untrusted "\$ca_bundle" \
  "\$cert_path" >/dev/null

if [[ -f "\$swanctl_conf" ]]; then
  config_tmp="\${swanctl_conf}.tmp.\$\$"
  awk '!/^[[:space:]]*cacerts[[:space:]]*=/' \
    "\$swanctl_conf" >"\$config_tmp"
  chmod 600 "\$config_tmp"
  mv -f "\$config_tmp" "\$swanctl_conf"
fi

if systemctl is-active --quiet "\${service_name}.service"; then
  swanctl --load-creds --clear >/dev/null 2>&1 && \
    swanctl --load-conns >/dev/null 2>&1 || \
    systemctl restart "\${service_name}.service"
fi
EOF_RELOAD
  chmod 700 "$CERT_RELOAD_SCRIPT"
}

# acme.sh renews from cron with its output sent to /dev/null. A silent
# renewal failure is invisible until clients stop connecting, so an
# independent daily check reports the remaining lifetime to the journal.
write_certificate_check_service() {
  ensure_manager_dir
  cat >"$CERT_CHECK_SCRIPT" <<EOF_CHECK
#!/usr/bin/env bash
# ${GENERATED_TAG}: v${SCRIPT_VERSION}
set -Euo pipefail

cert_path='${CERT_PATH}'
warn_days=21
critical_days=7

if [[ ! -f "\$cert_path" ]]; then
  logger -t ikev2-manager -p daemon.err "certificate missing: \$cert_path"
  exit 1
fi

end_raw="\$(openssl x509 -in "\$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2-)"
if [[ -z "\$end_raw" ]]; then
  logger -t ikev2-manager -p daemon.err "cannot read certificate expiry from \$cert_path"
  exit 1
fi

end_epoch="\$(date -d "\$end_raw" +%s 2>/dev/null || true)"
if [[ -z "\$end_epoch" ]]; then
  logger -t ikev2-manager -p daemon.err "cannot parse certificate expiry: \$end_raw"
  exit 1
fi

days_left=\$(((end_epoch - \$(date +%s)) / 86400))

if ((days_left <= critical_days)); then
  logger -t ikev2-manager -p daemon.crit "certificate expires in \${days_left}d; ACME renewal is not working"
  exit 1
elif ((days_left <= warn_days)); then
  logger -t ikev2-manager -p daemon.warning "certificate expires in \${days_left}d"
else
  logger -t ikev2-manager -p daemon.info "certificate valid for \${days_left}d"
fi
EOF_CHECK
  chmod 700 "$CERT_CHECK_SCRIPT"

  cat >"$CERT_CHECK_SERVICE" <<EOF_CHECK_SVC
[Unit]
Description=IKEv2 Manager certificate expiry check

[Service]
Type=oneshot
ExecStart=${CERT_CHECK_SCRIPT}
EOF_CHECK_SVC

  cat >"$CERT_CHECK_TIMER" <<'EOF_CHECK_TIMER'
[Unit]
Description=Daily IKEv2 Manager certificate expiry check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF_CHECK_TIMER

  systemctl daemon-reload
  systemctl enable --now ikev2-manager-certcheck.timer >/dev/null 2>&1 || true
}

# Records which of the required packages were actually missing, so that
# uninstall can purge exactly what this script added and nothing else.
ensure_packages() {
  local required=(
    ca-certificates
    curl
    openssl
    iproute2
    kmod
    iptables
    strongswan-swanctl
    charon-systemd
    libcharon-extra-plugins
  )
  local package added=()

  export DEBIAN_FRONTEND=noninteractive
  for package in "${required[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "^install ok installed$"; then
      added+=("$package")
    fi
  done

  apt-get update
  apt-get install -y "${required[@]}" || return 1

  local IFS=','
  MANAGED_PACKAGES="${added[*]+"${added[*]}"}"
}

ensure_acme_installed() {
  if [[ -x "$ACME_BIN" ]]; then
    return 0
  fi

  local installer rc=0
  installer=$(mktemp) || return 1

  # Preferred path: the acme.sh script from a pinned upstream tag, installed
  # with its own --install mode. No confirmation is needed because the URL
  # points at an immutable tag.
  if curl -fsSL "$ACME_INSTALLER_URL" -o "$installer" && [[ -s "$installer" ]]; then
    echo "Installing acme.sh ${ACME_VERSION} (pinned)."
    if [[ -n "${ACME_EMAIL:-}" ]]; then
      sh "$installer" --install --home "$ACME_HOME" --accountemail "$ACME_EMAIL" >/dev/null || rc=1
    else
      sh "$installer" --install --home "$ACME_HOME" >/dev/null || rc=1
    fi
  else
    rc=1
  fi

  # Fallback: the moving installer. It is unpinned, so the operator has to
  # approve the exact bytes.
  if ((rc != 0)) || [[ ! -x "$ACME_BIN" ]]; then
    rc=0
    echo "Pinned acme.sh ${ACME_VERSION} is unavailable; falling back to ${ACME_INSTALLER_FALLBACK_URL}."
    if fetch_and_confirm_script "$ACME_INSTALLER_FALLBACK_URL" "$installer"; then
      if [[ -n "${ACME_EMAIL:-}" ]]; then
        sh "$installer" email="$ACME_EMAIL" || rc=1
      else
        sh "$installer" || rc=1
      fi
    else
      rc=1
    fi
  fi

  rm -f "$installer"
  ((rc == 0)) && [[ -x "$ACME_BIN" ]]
}

# Ports sshd actually listens on, resolved while the manager is running and
# baked into the generated script: resolving them at boot races sshd startup
# and a wrong answer locks the operator out.
detect_ssh_ports() {
  local ports
  ports="$({
    awk '$1 == "Port" { print $2 }' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null
    ss -Hlntp 2>/dev/null | awk '/"sshd"/ { sub(/.*:/, "", $4); print $4 }'
  } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
  ports="$(trim "${ports:-}")"
  printf '%s' "${ports:-22}"
}

write_firewall_script() {
  ensure_manager_dir
  cat >"$FIREWALL_SCRIPT" <<EOF_FW_HEAD
#!/usr/bin/env bash
# ${GENERATED_TAG}: v${SCRIPT_VERSION}
# Generated file. Edit the manager configuration and reapply instead.
set -Eeuo pipefail

POOL_CIDR='${VPN_POOL_CIDR}'
POOL6_CIDR='${VPN_POOL6_CIDR}'
UPLINK_IF='${UPLINK_IF}'
IPV6_MODE='${IPV6_MODE:-off}'
CLIENT_ISOLATION='${CLIENT_ISOLATION:-1}'
EGRESS_POLICY='${EGRESS_POLICY:-internet-only}'
EGRESS_BLOCKED_V4='${EGRESS_BLOCKED_V4}'
EGRESS_BLOCKED_V6='${EGRESS_BLOCKED_V6}'
EGRESS_HOST_TCP_PORTS='${EGRESS_HOST_TCP_PORTS}'
EGRESS_HOST_UDP_PORTS='${EGRESS_HOST_UDP_PORTS}'
VPN_DNS='${VPN_DNS}'
ACME_MODE='${ACME_MODE:-dns-01}'
HARDEN_INPUT='${HARDEN_INPUT:-0}'
HARDEN_TCP_PORTS='${HARDEN_TCP_PORTS}'
HARDEN_UDP_PORTS='${HARDEN_UDP_PORTS}'
HARDEN_SSH_PORTS='$(detect_ssh_ports)'
HARDEN_CHAIN='IKEV2_MGR_IN'
EGRESS_CHAIN='IKEV2_MGR_FWD'
HOST_CHAIN='IKEV2_MGR_HOST'
MT_CONFIG='${MT_CONFIG_FILE}'
EOF_FW_HEAD

  cat >>"$FIREWALL_SCRIPT" <<'EOF_FW_BODY'

# --------------------------------------------------------------------------
# Rule helpers. Every rule is applied with check-then-act so the script is
# idempotent and safe to run on every boot and on every configuration change.
# --------------------------------------------------------------------------
ipt_ins() {
  local tool="$1" table="$2" chain="$3"
  shift 3
  "$tool" -t "$table" -C "$chain" "$@" >/dev/null 2>&1 \
    || "$tool" -t "$table" -I "$chain" "$@"
}

ipt_app() {
  local tool="$1" table="$2" chain="$3"
  shift 3
  "$tool" -t "$table" -C "$chain" "$@" >/dev/null 2>&1 \
    || "$tool" -t "$table" -A "$chain" "$@"
}

ipt_del() {
  local tool="$1" table="$2" chain="$3"
  shift 3
  while "$tool" -t "$table" -C "$chain" "$@" >/dev/null 2>&1; do
    "$tool" -t "$table" -D "$chain" "$@" || break
  done
}

ipt_chain_reset() {
  local tool="$1" chain="$2"
  "$tool" -N "$chain" 2>/dev/null || true
  "$tool" -F "$chain"
}

ipt_chain_drop() {
  local tool="$1" parent="$2" chain="$3"
  shift 3
  ipt_del "$tool" filter "$parent" "$@" -j "$chain"
  "$tool" -F "$chain" 2>/dev/null || true
  "$tool" -X "$chain" 2>/dev/null || true
}

# Client DNS servers of the matching family; they stay reachable even when
# they live on a network the egress policy otherwise blocks.
dns_servers_v4() {
  local entry
  local IFS=','
  for entry in $VPN_DNS; do
    [[ "$entry" == *:* ]] && continue
    [[ -n "$entry" ]] && printf '%s\n' "$entry"
  done
}

dns_servers_v6() {
  local entry
  local IFS=','
  for entry in $VPN_DNS; do
    [[ "$entry" == *:* ]] || continue
    printf '%s\n' "$entry"
  done
}

have_ip6tables=0
command -v ip6tables >/dev/null 2>&1 && have_ip6tables=1

# Listening port of the MTProto proxy, when it is installed.
mt_port=""
if [[ -f "$MT_CONFIG" ]]; then
  mt_port="$(awk '/^\[server\]/{f=1;next} /^\[/{f=0} \
    f && /^[[:space:]]*port[[:space:]]*=/{sub(/.*=[[:space:]]*/,""); gsub(/[^0-9]/,"",$0); print; exit}' \
    "$MT_CONFIG" 2>/dev/null || true)"
fi

# --------------------------------------------------------------------------
# IKEv2 listeners. External NAT/security-group rules still have to allow
# UDP/500 and UDP/4500.
# --------------------------------------------------------------------------
ipt_ins iptables filter INPUT -p udp --dport 500 -j ACCEPT
ipt_ins iptables filter INPUT -p udp --dport 4500 -j ACCEPT

# The proxy port is reopened here as well so the rule survives a reboot on
# hosts with a restrictive INPUT policy; nothing else reapplies it.
if [[ -n "$mt_port" ]]; then
  ipt_ins iptables filter INPUT -p tcp --dport "$mt_port" -m comment --comment "mtproto-manager" -j ACCEPT
fi

# --------------------------------------------------------------------------
# Full-tunnel forwarding/NAT for VPN clients.
# --------------------------------------------------------------------------
ipt_ins iptables nat POSTROUTING -s "$POOL_CIDR" -o "$UPLINK_IF" -j MASQUERADE
ipt_ins iptables filter FORWARD -s "$POOL_CIDR" -o "$UPLINK_IF" -j ACCEPT
ipt_ins iptables filter FORWARD -d "$POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT

# Clamp TCP MSS to path MTU for tunneled clients: native IKEv2 clients have
# no MSS help from their side, large packets blackhole without this.
ipt_app iptables mangle FORWARD -s "$POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ipt_app iptables mangle FORWARD -d "$POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Hairpinned client-to-client traffic; inserted before the egress chain so
# the egress chain jump ends up above it.
if [[ "$CLIENT_ISOLATION" == "1" ]]; then
  ipt_ins iptables filter FORWARD -s "$POOL_CIDR" -d "$POOL_CIDR" -j DROP
else
  ipt_del iptables filter FORWARD -s "$POOL_CIDR" -d "$POOL_CIDR" -j DROP
fi

# --------------------------------------------------------------------------
# Egress policy. Under internet-only a VPN client must not be able to use the
# tunnel as a foothold into the hosting network: cloud metadata (169.254/16),
# private ranges and this host's own services are dropped. Configured client
# DNS servers are exempted, and the pool itself returns so that the client
# isolation rule above stays authoritative.
# --------------------------------------------------------------------------
if [[ "$EGRESS_POLICY" == "internet-only" ]]; then
  ipt_chain_reset iptables "$EGRESS_CHAIN"
  while IFS= read -r dns_server; do
    [[ -n "$dns_server" ]] || continue
    iptables -A "$EGRESS_CHAIN" -d "$dns_server" -j RETURN
  done < <(dns_servers_v4)
  iptables -A "$EGRESS_CHAIN" -d "$POOL_CIDR" -j RETURN
  for blocked in $EGRESS_BLOCKED_V4; do
    iptables -A "$EGRESS_CHAIN" -d "$blocked" -j DROP
  done
  ipt_ins iptables filter FORWARD -s "$POOL_CIDR" -j "$EGRESS_CHAIN"

  # Traffic addressed to the host itself lands in INPUT, not FORWARD.
  ipt_chain_reset iptables "$HOST_CHAIN"
  iptables -A "$HOST_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A "$HOST_CHAIN" -p icmp -j ACCEPT
  iptables -A "$HOST_CHAIN" -p udp --dport 53 -j ACCEPT
  iptables -A "$HOST_CHAIN" -p tcp --dport 53 -j ACCEPT
  for port in ${EGRESS_HOST_TCP_PORTS//,/ }; do
    iptables -A "$HOST_CHAIN" -p tcp --dport "$port" -j ACCEPT
  done
  for port in ${EGRESS_HOST_UDP_PORTS//,/ }; do
    iptables -A "$HOST_CHAIN" -p udp --dport "$port" -j ACCEPT
  done
  iptables -A "$HOST_CHAIN" -j DROP
  ipt_ins iptables filter INPUT -s "$POOL_CIDR" -j "$HOST_CHAIN"
else
  ipt_chain_drop iptables FORWARD "$EGRESS_CHAIN" -s "$POOL_CIDR"
  ipt_chain_drop iptables INPUT "$HOST_CHAIN" -s "$POOL_CIDR"
fi

# --------------------------------------------------------------------------
# IPv6. The rules of the modes that are not active are removed, so switching
# block <-> nat <-> off converges instead of stacking up.
# --------------------------------------------------------------------------
if ((have_ip6tables)); then
  if [[ "$IPV6_MODE" == "off" ]]; then
    ipt_del ip6tables filter INPUT -p udp --dport 500 -j ACCEPT
    ipt_del ip6tables filter INPUT -p udp --dport 4500 -j ACCEPT
  else
    ipt_ins ip6tables filter INPUT -p udp --dport 500 -j ACCEPT
    ipt_ins ip6tables filter INPUT -p udp --dport 4500 -j ACCEPT
  fi

  if [[ "$IPV6_MODE" == "nat" ]]; then
    ipt_del ip6tables filter FORWARD -s "$POOL6_CIDR" -j DROP

    ipt_ins ip6tables nat POSTROUTING -s "$POOL6_CIDR" -o "$UPLINK_IF" -j MASQUERADE
    ipt_ins ip6tables filter FORWARD -s "$POOL6_CIDR" -o "$UPLINK_IF" -j ACCEPT
    ipt_ins ip6tables filter FORWARD -d "$POOL6_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT
    ipt_app ip6tables mangle FORWARD -s "$POOL6_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ipt_app ip6tables mangle FORWARD -d "$POOL6_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    if [[ "$CLIENT_ISOLATION" == "1" ]]; then
      ipt_ins ip6tables filter FORWARD -s "$POOL6_CIDR" -d "$POOL6_CIDR" -j DROP
    else
      ipt_del ip6tables filter FORWARD -s "$POOL6_CIDR" -d "$POOL6_CIDR" -j DROP
    fi

    if [[ "$EGRESS_POLICY" == "internet-only" ]]; then
      ipt_chain_reset ip6tables "$EGRESS_CHAIN"
      while IFS= read -r dns_server; do
        [[ -n "$dns_server" ]] || continue
        ip6tables -A "$EGRESS_CHAIN" -d "$dns_server" -j RETURN
      done < <(dns_servers_v6)
      ip6tables -A "$EGRESS_CHAIN" -d "$POOL6_CIDR" -j RETURN
      for blocked in $EGRESS_BLOCKED_V6; do
        ip6tables -A "$EGRESS_CHAIN" -d "$blocked" -j DROP
      done
      ipt_ins ip6tables filter FORWARD -s "$POOL6_CIDR" -j "$EGRESS_CHAIN"

      ipt_chain_reset ip6tables "$HOST_CHAIN"
      ip6tables -A "$HOST_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ip6tables -A "$HOST_CHAIN" -p ipv6-icmp -j ACCEPT
      ip6tables -A "$HOST_CHAIN" -p udp --dport 53 -j ACCEPT
      ip6tables -A "$HOST_CHAIN" -p tcp --dport 53 -j ACCEPT
      for port in ${EGRESS_HOST_TCP_PORTS//,/ }; do
        ip6tables -A "$HOST_CHAIN" -p tcp --dport "$port" -j ACCEPT
      done
      for port in ${EGRESS_HOST_UDP_PORTS//,/ }; do
        ip6tables -A "$HOST_CHAIN" -p udp --dport "$port" -j ACCEPT
      done
      ip6tables -A "$HOST_CHAIN" -j DROP
      ipt_ins ip6tables filter INPUT -s "$POOL6_CIDR" -j "$HOST_CHAIN"
    else
      ipt_chain_drop ip6tables FORWARD "$EGRESS_CHAIN" -s "$POOL6_CIDR"
      ipt_chain_drop ip6tables INPUT "$HOST_CHAIN" -s "$POOL6_CIDR"
    fi
  else
    # Not NAT66: drop the forwarding/NAT rules of that mode.
    ipt_del ip6tables nat POSTROUTING -s "$POOL6_CIDR" -o "$UPLINK_IF" -j MASQUERADE
    ipt_del ip6tables filter FORWARD -s "$POOL6_CIDR" -o "$UPLINK_IF" -j ACCEPT
    ipt_del ip6tables filter FORWARD -d "$POOL6_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT
    ipt_del ip6tables mangle FORWARD -s "$POOL6_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ipt_del ip6tables mangle FORWARD -d "$POOL6_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ipt_del ip6tables filter FORWARD -s "$POOL6_CIDR" -d "$POOL6_CIDR" -j DROP
    ipt_chain_drop ip6tables FORWARD "$EGRESS_CHAIN" -s "$POOL6_CIDR"
    ipt_chain_drop ip6tables INPUT "$HOST_CHAIN" -s "$POOL6_CIDR"

    if [[ "$IPV6_MODE" == "block" ]]; then
      # Blackhole client IPv6 so dual-stack clients cannot leak around the
      # tunnel.
      ipt_app ip6tables filter FORWARD -s "$POOL6_CIDR" -j DROP
    else
      ipt_del ip6tables filter FORWARD -s "$POOL6_CIDR" -j DROP
    fi
  fi
fi

# --------------------------------------------------------------------------
# Inbound hardening: a default-drop allowlist chain appended to INPUT.
# SSH ports are resolved when the rules are generated (not at boot, where
# sshd may not have started yet), IKEv2, ESP, ICMP, DHCP, the ACME HTTP-01
# port and explicitly listed ports stay reachable.
# --------------------------------------------------------------------------
harden_tools=(iptables)
((have_ip6tables)) && harden_tools+=(ip6tables)

if [[ "$HARDEN_INPUT" == "1" ]]; then
  ssh_ports="$({
    printf '%s\n' $HARDEN_SSH_PORTS
    awk '$1 == "Port" { print $2 }' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null
    ss -Hlntp 2>/dev/null | awk '/"sshd"/ { sub(/.*:/, "", $4); print $4 }'
  } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
  [[ -n "${ssh_ports// /}" ]] || ssh_ports="22"

  for ipt in "${harden_tools[@]}"; do
    ipt_chain_reset "$ipt" "$HARDEN_CHAIN"
    "$ipt" -A "$HARDEN_CHAIN" -i lo -j ACCEPT
    "$ipt" -A "$HARDEN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if [[ "$ipt" == "ip6tables" ]]; then
      # ICMPv6 carries neighbor discovery and RA; DHCPv6 keeps the uplink lease.
      "$ipt" -A "$HARDEN_CHAIN" -p ipv6-icmp -j ACCEPT
      "$ipt" -A "$HARDEN_CHAIN" -p udp --dport 546 -j ACCEPT
    else
      "$ipt" -A "$HARDEN_CHAIN" -p icmp -j ACCEPT
      # DHCPv4 lease renewal on cloud instances that do not use static
      # addressing; the reply can arrive outside an existing conntrack entry.
      "$ipt" -A "$HARDEN_CHAIN" -p udp --dport 68 -j ACCEPT
    fi
    "$ipt" -A "$HARDEN_CHAIN" -p udp --dport 500 -j ACCEPT
    "$ipt" -A "$HARDEN_CHAIN" -p udp --dport 4500 -j ACCEPT
    # Non-NAT peers run plain ESP instead of UDP encapsulation.
    "$ipt" -A "$HARDEN_CHAIN" -p esp -j ACCEPT
    for port in $ssh_ports; do
      "$ipt" -A "$HARDEN_CHAIN" -p tcp --dport "$port" -j ACCEPT
    done
    # HTTP-01 renewal runs unattended from cron and needs inbound TCP/80.
    if [[ "$ACME_MODE" == "http-01" ]]; then
      "$ipt" -A "$HARDEN_CHAIN" -p tcp --dport 80 -j ACCEPT
    fi
    if [[ -n "$mt_port" ]]; then
      "$ipt" -A "$HARDEN_CHAIN" -p tcp --dport "$mt_port" -j ACCEPT
    fi
    for port in ${HARDEN_TCP_PORTS//,/ }; do
      "$ipt" -A "$HARDEN_CHAIN" -p tcp --dport "$port" -j ACCEPT
    done
    for port in ${HARDEN_UDP_PORTS//,/ }; do
      "$ipt" -A "$HARDEN_CHAIN" -p udp --dport "$port" -j ACCEPT
    done
    "$ipt" -A "$HARDEN_CHAIN" -j DROP
    ipt_app "$ipt" filter INPUT -j "$HARDEN_CHAIN"
  done
else
  for ipt in "${harden_tools[@]}"; do
    ipt_chain_drop "$ipt" INPUT "$HARDEN_CHAIN"
  done
fi

# These rules are reapplied by ikev2-manager-firewall.service on every boot.
# Nothing is written to /etc/iptables here on purpose: dumping the live
# ruleset would also persist unrelated rules owned by Docker, ufw or the
# hosting provider.
EOF_FW_BODY
  chmod 700 "$FIREWALL_SCRIPT"
}

write_firewall_service() {
  cat >"$FIREWALL_SERVICE" <<EOF_SVC
[Unit]
Description=IKEv2 Manager firewall rules
Documentation=file://${FIREWALL_SCRIPT}
After=network-online.target netfilter-persistent.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FIREWALL_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SVC
  systemctl daemon-reload
  systemctl enable --now ikev2-manager-firewall.service
}

apply_firewall_rules() {
  [[ -n "$UPLINK_IF" ]] || {
    echo "Uplink interface is not set."
    return 1
  }
  write_firewall_script
  write_firewall_service
  "$FIREWALL_SCRIPT"
}

remove_firewall_rules() {
  local chain
  ipt_del_rule iptables filter INPUT -p udp --dport 500 -j ACCEPT
  ipt_del_rule iptables filter INPUT -p udp --dport 4500 -j ACCEPT

  if [[ -n "${UPLINK_IF:-}" ]]; then
    ipt_del_rule iptables nat POSTROUTING -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j MASQUERADE
    ipt_del_rule iptables filter FORWARD -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j ACCEPT
    ipt_del_rule iptables filter FORWARD -d "$VPN_POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT
  fi

  ipt_del_rule iptables mangle FORWARD -s "$VPN_POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ipt_del_rule iptables mangle FORWARD -d "$VPN_POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ipt_del_rule iptables filter FORWARD -s "$VPN_POOL_CIDR" -d "$VPN_POOL_CIDR" -j DROP
  ipt_drop_chain iptables FORWARD "$EGRESS_CHAIN" -s "$VPN_POOL_CIDR"
  ipt_drop_chain iptables INPUT "$HOST_CHAIN" -s "$VPN_POOL_CIDR"
  ipt_drop_chain iptables INPUT "$HARDEN_CHAIN"

  if command -v ip6tables >/dev/null 2>&1; then
    ipt_del_rule ip6tables filter INPUT -p udp --dport 500 -j ACCEPT
    ipt_del_rule ip6tables filter INPUT -p udp --dport 4500 -j ACCEPT

    if [[ -n "${VPN_POOL6_CIDR:-}" ]]; then
      ipt_del_rule ip6tables filter FORWARD -s "$VPN_POOL6_CIDR" -j DROP
      if [[ -n "${UPLINK_IF:-}" ]]; then
        ipt_del_rule ip6tables nat POSTROUTING -s "$VPN_POOL6_CIDR" -o "$UPLINK_IF" -j MASQUERADE
        ipt_del_rule ip6tables filter FORWARD -s "$VPN_POOL6_CIDR" -o "$UPLINK_IF" -j ACCEPT
        ipt_del_rule ip6tables filter FORWARD -d "$VPN_POOL6_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT
      fi
      ipt_del_rule ip6tables mangle FORWARD -s "$VPN_POOL6_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      ipt_del_rule ip6tables mangle FORWARD -d "$VPN_POOL6_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      ipt_del_rule ip6tables filter FORWARD -s "$VPN_POOL6_CIDR" -d "$VPN_POOL6_CIDR" -j DROP
      ipt_drop_chain ip6tables FORWARD "$EGRESS_CHAIN" -s "$VPN_POOL6_CIDR"
      ipt_drop_chain ip6tables INPUT "$HOST_CHAIN" -s "$VPN_POOL6_CIDR"
    fi
    ipt_drop_chain ip6tables INPUT "$HARDEN_CHAIN"
  fi

  if [[ -f "$FIREWALL_SERVICE" ]]; then
    systemctl disable --now ikev2-manager-firewall.service >/dev/null 2>&1 || true
    rm -f "$FIREWALL_SERVICE"
    systemctl daemon-reload
  fi

  rm -f "$FIREWALL_SCRIPT"

  # Persisted rule files are deliberately left alone: this script never wrote
  # them, and rewriting them here would capture unrelated rules.
  for chain in "$EGRESS_CHAIN" "$HOST_CHAIN" "$HARDEN_CHAIN"; do
    iptables -X "$chain" 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
      ip6tables -X "$chain" 2>/dev/null || true
    fi
  done
}

# Other software on the host may depend on forwarding (Docker, k8s, another
# VPN). Turning it off unconditionally used to break their networking, so it
# is only reset when nothing else asks for it.
forwarding_used_by_others() {
  if systemctl is-active --quiet docker.service 2>/dev/null; then
    printf 'docker.service'
    return 0
  fi
  if [[ -d /sys/class/net/docker0 ]]; then
    printf 'docker0 bridge'
    return 0
  fi
  local hit
  hit="$(grep -rls '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' \
    /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d 2>/dev/null \
    | grep -v "^${SYSCTL_FILE}$" | head -n1 || true)"
  if [[ -n "$hit" ]]; then
    printf '%s' "$hit"
    return 0
  fi
  return 1
}

disable_sysctl() {
  local owner
  rm -f "$SYSCTL_FILE" "$MODULES_LOAD_FILE"
  if owner="$(forwarding_used_by_others)"; then
    echo "IP forwarding left enabled: still required by ${owner}."
  else
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
  fi
  sysctl --system >/dev/null 2>&1 || true
}

cleanup_acme_binding() {
  if [[ -n "${DOMAIN:-}" && -x "$ACME_BIN" ]]; then
    "$ACME_BIN" --remove -d "$DOMAIN" >/dev/null 2>&1 || true
    "$ACME_BIN" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
    rm -rf -- "${ACME_HOME:?}/${DOMAIN:?}" "${ACME_HOME:?}/${DOMAIN:?}_ecc"
  fi
  rm -f "$ACME_ENV_FILE"
}

cleanup_managed_files() {
  rm -f "$SWANCTL_CONF" "$CERT_PATH" "$CA_PATH" "$KEY_PATH"
  rm -f "$LEGACY_CA_PATH" "$CA_ROOT_PATH" "$CERT_RELOAD_SCRIPT" "$CERT_CHECK_SCRIPT"
  rm -f "${CA_CHAIN_PREFIX}"-*.pem /etc/swanctl/x509ca/ikev2-chain-*.pem
  rm -f "${CERT_PATH}".bak.* "${CA_PATH}".bak.* "${KEY_PATH}".bak.* "${SWANCTL_CONF}".bak.* 2>/dev/null || true
  # /etc/swanctl/conf.d may hold configuration this manager never wrote; it
  # is left alone.
  rmdir /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private /etc/swanctl 2>/dev/null || true

  if [[ -f "$CERT_CHECK_TIMER" || -f "$CERT_CHECK_SERVICE" ]]; then
    systemctl disable --now ikev2-manager-certcheck.timer >/dev/null 2>&1 || true
    rm -f "$CERT_CHECK_TIMER" "$CERT_CHECK_SERVICE"
    systemctl daemon-reload
  fi
}

# Only packages this manager installed are purged, and only the strongSwan
# ones: removing shared libraries or running autoremove could take unrelated
# software with them.
purge_vpn_packages() {
  local -a candidates=() purge=()
  local package ans
  local IFS=','
  for package in ${MANAGED_PACKAGES:-}; do
    [[ -n "$package" ]] && candidates+=("$package")
  done
  unset IFS

  for package in "${candidates[@]+"${candidates[@]}"}"; do
    case "$package" in
      strongswan-swanctl | charon-systemd | libcharon-extra-plugins | strongswan-pki)
        purge+=("$package")
        ;;
    esac
  done

  if ((${#purge[@]} == 0)); then
    echo "No strongSwan packages recorded as installed by this manager; leaving packages in place."
    return 0
  fi

  echo "Packages installed by this manager: ${purge[*]}"
  read -r -p "Purge them? [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || {
    echo "Packages left installed."
    return 0
  }

  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y "${purge[@]}" >/dev/null 2>&1 || true
}

uninstall_cleanup() {
  render_header
  echo -e "${WHITE}Uninstall / cleanup IKEv2 manager setup${NC}"
  echo
  echo "This will:"
  echo "- stop and disable strongSwan"
  echo "- remove managed firewall rules and firewall unit"
  echo "- remove manager config, users, generated VPN config and installed cert paths"
  echo "- remove ACME renewal binding for the configured domain"
  echo "- offer to purge the strongSwan packages this manager installed"
  echo "- reset IPv4 forwarding, unless another service still needs it"
  echo
  read -r -p "Type DELETE to continue: " confirm || true
  [[ "$confirm" == "DELETE" ]] || return 0

  SERVICE_NAME="$(detect_service_name)"
  systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl stop strongswan.service >/dev/null 2>&1 || true
  systemctl stop strongswan-starter.service >/dev/null 2>&1 || true
  systemctl stop charon-systemd.service >/dev/null 2>&1 || true

  remove_firewall_rules
  disable_sysctl
  cleanup_acme_binding
  cleanup_managed_files
  purge_vpn_packages

  rm -rf "$MANAGER_DIR"

  INSTALLED=0
  DOMAIN=""
  ACME_EMAIL=""
  ACME_MODE="$DEFAULT_ACME_MODE"
  DNS_PROVIDER=""
  VPN_POOL_RANGE="$DEFAULT_POOL_RANGE"
  VPN_POOL_CIDR="$DEFAULT_POOL_CIDR"
  IPV6_MODE="$DEFAULT_IPV6_MODE"
  VPN_POOL6_CIDR="$DEFAULT_POOL6_CIDR"
  VPN_DNS="$DEFAULT_DNS_FALLBACK"
  EGRESS_POLICY="$DEFAULT_EGRESS_POLICY"
  EGRESS_HOST_TCP_PORTS="$DEFAULT_EGRESS_HOST_TCP_PORTS"
  EGRESS_HOST_UDP_PORTS="$DEFAULT_EGRESS_HOST_UDP_PORTS"
  CERT_KEY_TYPE="$DEFAULT_CERT_KEY_TYPE"
  IKE_UNIQUE="$DEFAULT_IKE_UNIQUE"
  MANAGED_PACKAGES=""
  UPLINK_IF="$(detect_uplink_if || true)"
  LAST_ERROR=""
  echo
  echo "IKEv2 manager setup removed."
  pause
}

ensure_kernel_ipsec_support() {
  local required_modules=(xfrm_user esp4)
  # esp6/xfrm6_tunnel cover IKE over IPv6 and ESP-in-UDP over IPv6; a missing
  # module surfaces as netlink "Protocol not supported" on CHILD_SA install.
  local optional_modules=(af_key ah4 xfrm4_tunnel esp6 xfrm6_tunnel rfc4106 gcm aes aesni_intel)
  local module failed=0 output

  if command -v modprobe >/dev/null 2>&1; then
    for module in "${required_modules[@]}"; do
      if ! output=$(modprobe "$module" 2>&1); then
        echo "Kernel module unavailable: $module"
        if grep -qE "install command '.*/bin/false'|install /bin/false" <<<"$output"; then
          echo "Module $module is blocked by a modprobe.d mitigation rule."
          grep -RIn -- "install[[:space:]]\\+${module}\\|blacklist[[:space:]]\\+${module}" \
            /etc/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d 2>/dev/null || true
        else
          echo "$output"
        fi
        failed=1
      fi
    done
    for module in "${optional_modules[@]}"; do
      modprobe "$module" >/dev/null 2>&1 || true
    done
  fi

  if ! ip xfrm state >/dev/null 2>&1; then
    echo "Kernel XFRM/IPsec API is not available."
    failed=1
  fi

  if [[ ! -r /proc/net/xfrm_stat ]]; then
    echo "/proc/net/xfrm_stat is not available."
    failed=1
  fi

  if ((failed)); then
    echo "This kernel does not expose the IPsec/XFRM support required by strongSwan."
    echo "Use a distro/kernel with CONFIG_XFRM and ESP support enabled, or ask the VPS provider to enable IPsec."
    return 1
  fi
}

enable_sysctl() {
  local current_conntrack_max target_conntrack_max applied_conntrack_max
  modprobe nf_conntrack >/dev/null 2>&1 || {
    echo "Failed to load nf_conntrack kernel module."
    return 1
  }

  # systemd-sysctl runs before nf_conntrack is autoloaded, so a
  # net.netfilter.* key in sysctl.d is silently dropped on boot unless the
  # module is loaded early. Without this the configured limit only survives
  # until the next reboot.
  mkdir -p "$(dirname "$MODULES_LOAD_FILE")"
  {
    echo "# ${GENERATED_TAG}: v${SCRIPT_VERSION}"
    echo "nf_conntrack"
  } >"$MODULES_LOAD_FILE"
  chmod 644 "$MODULES_LOAD_FILE"

  current_conntrack_max="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)"
  target_conntrack_max="$(conntrack_target_max "$current_conntrack_max")"

  {
    echo "# ${GENERATED_TAG}: v${SCRIPT_VERSION}"
    echo "net.ipv4.ip_forward=1"
    echo "net.netfilter.nf_conntrack_max=$target_conntrack_max"
    if [[ "${IPV6_MODE:-off}" == "nat" ]]; then
      echo "net.ipv6.conf.all.forwarding=1"
    fi
  } >"$SYSCTL_FILE"
  chmod 644 "$SYSCTL_FILE"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w "net.netfilter.nf_conntrack_max=$target_conntrack_max" >/dev/null 2>&1 || true
  if [[ "${IPV6_MODE:-off}" == "nat" ]]; then
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  fi
  sysctl -p "$SYSCTL_FILE" >/dev/null

  applied_conntrack_max="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)"
  if [[ "$applied_conntrack_max" != "$target_conntrack_max" ]]; then
    echo "Warning: nf_conntrack_max is ${applied_conntrack_max:-unknown}, expected ${target_conntrack_max}."
  fi
}

# True when a generated file carries the marker of the running version.
generated_is_current() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qF "${GENERATED_TAG}: v${SCRIPT_VERSION}" "$file"
}

# Lists the managed artifacts that are missing or were written by an older
# version of this script.
stale_artifacts() {
  local file
  for file in "$FIREWALL_SCRIPT" "$SYSCTL_FILE" "$MODULES_LOAD_FILE" \
    "$CERT_RELOAD_SCRIPT" "$CERT_CHECK_SCRIPT"; do
    generated_is_current "$file" || printf '%s\n' "$file"
  done
}

# Upgrading the script used to leave every generated artifact behind at its
# old content: the configuration said one thing and the machine did another.
# Regenerating them is idempotent, so it runs whenever a drift is detected.
reconcile_managed_state() {
  local force="${1:-}" stale
  effective_installed || return 0
  stale="$(stale_artifacts)"
  if [[ -z "$stale" && "$force" != "force" ]]; then
    return 0
  fi

  if [[ -n "$stale" ]]; then
    echo "Managed files were generated by an older version; regenerating:"
    print_indented "$stale"
  else
    echo "Regenerating managed files."
  fi
  echo

  write_certificate_reload_script
  write_certificate_check_service
  enable_sysctl || echo "Warning: failed to reapply sysctl settings."
  if [[ -n "${UPLINK_IF:-}" ]]; then
    apply_firewall_rules || echo "Warning: failed to reapply firewall rules."
  fi
  migrate_config
  echo "Regeneration complete."
  pause
}

escape_swanctl() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

generate_swanctl_conf() {
  migrate_users_db
  ESP_PROPOSALS="$(ensure_apple_esp_proposals "$ESP_PROPOSALS")"
  mkdir -p /etc/swanctl /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private
  backup_file "$SWANCTL_CONF"

  # In block/nat modes clients get an IPv6 address and a ::/0 selector, so
  # dual-stack devices route IPv6 into the tunnel instead of leaking it.
  local effective_local_ts="$LOCAL_TS" pool_list="vpn_pool" pool6_block="" childless_line=""
  # Apple clients negotiate childless IKE_SAs; strongSwan supports it from
  # 5.9.6 and rejects the keyword on older builds.
  if strongswan_at_least 5 9 6; then
    childless_line="
    childless = allow"
  fi
  if [[ "${IPV6_MODE:-off}" != "off" ]]; then
    if [[ ",$LOCAL_TS," != *",::/0,"* ]]; then
      effective_local_ts="${LOCAL_TS},::/0"
    fi
    pool_list="vpn_pool, vpn_pool6"
    pool6_block="
  vpn_pool6 {
    addrs = ${VPN_POOL6_CIDR}
  }"
  fi

  {
    cat <<EOF_HEAD
connections {
  ${CONN_NAME} {
    version = 2
    send_cert = always
    proposals = ${IKE_PROPOSALS}
    unique = ${IKE_UNIQUE:-never}${childless_line}
    dpd_delay = ${DPD_DELAY}
    mobike = yes
    fragmentation = yes

    local {
      auth = pubkey
      certs = ${CERT_NAME}
      id = ${DOMAIN}
    }

    remote {
      auth = eap-mschapv2
      eap_id = %any
      id = %any
    }

    children {
      net {
        esp_proposals = ${ESP_PROPOSALS}
        local_ts = ${effective_local_ts}
        dpd_action = clear
        start_action = none
      }
    }

    pools = ${pool_list}
  }
}

pools {
  vpn_pool {
    addrs = ${VPN_POOL_RANGE}
    dns = ${VPN_DNS}
  }${pool6_block}
}

secrets {
EOF_HEAD

    if [[ -f "$USERS_DB" ]]; then
      local db_user db_pass db_group db_platform _db_rest esc_user esc_pass idx=0
      while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
        [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
        esc_user=$(escape_swanctl "$db_user")
        esc_pass=$(escape_swanctl "$db_pass")
        idx=$((idx + 1))
        # Section names are numbered: usernames may contain characters
        # (e.g. dots) that the strongswan settings parser rejects in names.
        cat <<EOF_USER
  eap-${idx} {
    id = "${esc_user}"
    secret = "${esc_pass}"
  }

EOF_USER
      done <"$USERS_DB"
    fi

    cat <<EOF_TAIL
  private-key {
    file = ${KEY_PATH}
  }
}
EOF_TAIL
  } >"$SWANCTL_CONF"
  chmod 600 "$SWANCTL_CONF"
}

load_swanctl() {
  if command -v swanctl >/dev/null 2>&1; then
    swanctl --load-all >/dev/null 2>&1 || true
  fi
}

reload_vpn_credentials() {
  if command -v swanctl >/dev/null 2>&1 && swanctl --load-creds >/dev/null 2>&1; then
    load_swanctl
    return 0
  fi
  restart_vpn_service
}

# Best-effort: terminate IKE SAs whose identity matches the given username,
# so a removed user is cut off without restarting the whole service.
terminate_user_sas() {
  local user="$1" ids id
  command -v swanctl >/dev/null 2>&1 || return 0
  ids=$(swanctl --list-sas 2>/dev/null | awk -v u="'${user}'" '
    match($0, /#[0-9]+, /) { uid = substr($0, RSTART + 1, RLENGTH - 3) }
    uid != "" && index($0, u) { print uid; uid = "" }
  ' | sort -un)
  [[ -n "$ids" ]] || return 0
  for id in $ids; do
    swanctl --terminate --ike-id "$id" --timeout 5 >/dev/null 2>&1 || true
  done
}

issue_and_install_cert() {
  [[ -n "${DOMAIN:-}" ]] || {
    echo "Domain is not set."
    return 1
  }

  local keylength
  keylength="$(acme_keylength_for "${CERT_KEY_TYPE:-$DEFAULT_CERT_KEY_TYPE}")" || {
    echo "Unsupported certificate key type: ${CERT_KEY_TYPE:-}"
    return 1
  }

  mkdir -p /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private
  write_certificate_reload_script
  write_certificate_check_service
  backup_file "$CERT_PATH"
  backup_file "$CA_PATH"
  backup_file "$KEY_PATH"

  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null

  local rc=0
  case "${ACME_MODE:-dns-01}" in
    dns-01)
      [[ -n "${DNS_PROVIDER:-}" ]] || {
        echo "DNS provider is not set."
        return 1
      }
      [[ -f "$ACME_ENV_FILE" ]] || {
        echo "ACME env file is missing: $ACME_ENV_FILE"
        return 1
      }
      # shellcheck disable=SC1090
      source "$ACME_ENV_FILE"
      "$ACME_BIN" --issue -d "$DOMAIN" --dns "$DNS_PROVIDER" --keylength "$keylength" || rc=$?
      ;;
    http-01)
      echo "Using HTTP-01 standalone mode."
      echo "The host must be reachable from the Internet on TCP/80 during validation."
      "$ACME_BIN" --issue -d "$DOMAIN" --standalone --keylength "$keylength" || rc=$?
      ;;
    *)
      echo "Unsupported ACME mode: ${ACME_MODE}"
      return 1
      ;;
  esac

  # acme.sh returns 2 (RENEW_SKIP) when the certificate is still valid.
  if ((rc == 2)); then
    echo "Certificate is still valid; skipping issuance, reinstalling existing files."
  elif ((rc != 0)); then
    return "$rc"
  fi

  # Reload credentials without dropping active tunnels; restart only as fallback.
  local -a install_args=(--install-cert -d "$DOMAIN")
  # ECDSA certificates live in acme.sh's *_ecc directory and need --ecc on
  # every subsequent call.
  [[ "$keylength" == ec-* ]] && install_args+=(--ecc)
  install_args+=(
    --cert-file "$CERT_PATH"
    --ca-file "$CA_PATH"
    --key-file "$KEY_PATH"
    --reloadcmd "$CERT_RELOAD_SCRIPT"
  )
  "$ACME_BIN" "${install_args[@]}"
}
validate_acme_env() {
  case "${ACME_MODE:-dns-01}" in
    dns-01)
      [[ -f "$ACME_ENV_FILE" ]] || {
        echo "ACME env file is missing."
        return 1
      }
      # shellcheck disable=SC1090
      source "$ACME_ENV_FILE"
      case "$DNS_PROVIDER" in
        dns_timeweb)
          [[ -n "${TW_Token:-}" ]] || {
            echo "TW_Token is missing for dns_timeweb."
            return 1
          }
          ;;
      esac
      ;;
    http-01)
      return 0
      ;;
    *)
      echo "Unsupported ACME mode: ${ACME_MODE}"
      return 1
      ;;
  esac
}

validate_install_inputs() {
  DOMAIN="${DOMAIN,,}"
  [[ -n "$DOMAIN" ]] || {
    echo "Domain is required."
    return 1
  }
  valid_domain_name "$DOMAIN" || {
    echo "Domain must contain only ASCII letters, digits, dots and hyphens."
    return 1
  }

  ACME_MODE="${ACME_MODE,,}"
  [[ "$ACME_MODE" == "dns-01" || "$ACME_MODE" == "http-01" ]] || {
    echo "ACME mode must be dns-01 or http-01."
    return 1
  }

  if [[ "$ACME_MODE" == "dns-01" ]]; then
    [[ -n "$DNS_PROVIDER" ]] || {
      echo "DNS provider is required for DNS-01."
      return 1
    }
    valid_dns_provider "$DNS_PROVIDER" || {
      echo "DNS provider contains invalid characters."
      return 1
    }
  else
    DNS_PROVIDER=""
  fi

  [[ -n "$UPLINK_IF" ]] || {
    echo "Uplink interface is required."
    return 1
  }
  interface_exists "$UPLINK_IF" || {
    echo "Uplink interface does not exist: $UPLINK_IF"
    return 1
  }

  [[ -n "$VPN_POOL_CIDR" ]] || {
    echo "VPN pool CIDR is required."
    return 1
  }
  valid_cidr "$VPN_POOL_CIDR" || {
    echo "VPN pool CIDR is invalid."
    return 1
  }

  [[ -n "$VPN_POOL_RANGE" ]] || {
    echo "VPN pool range is required."
    return 1
  }
  valid_range "$VPN_POOL_RANGE" || {
    echo "VPN pool range is invalid. Use start-end."
    return 1
  }

  local range_start range_end
  range_start="${VPN_POOL_RANGE%%-*}"
  range_end="${VPN_POOL_RANGE##*-}"
  if ! cidr_contains "$VPN_POOL_CIDR" "$range_start" || ! cidr_contains "$VPN_POOL_CIDR" "$range_end"; then
    echo "VPN pool range is outside the VPN pool CIDR; NAT rules would not match client traffic."
    return 1
  fi

  valid_ipv6_mode "$IPV6_MODE" || {
    echo "IPv6 mode must be block, nat or off."
    return 1
  }
  if [[ "$IPV6_MODE" != "off" ]]; then
    valid_ipv6_cidr "$VPN_POOL6_CIDR" || {
      echo "VPN IPv6 pool CIDR is invalid."
      return 1
    }
  fi
  if [[ "$IPV6_MODE" == "nat" ]] && ! host_has_global_ipv6; then
    echo "Warning: no global IPv6 route detected on this host; NAT66 clients may not reach the Internet over IPv6."
  fi

  VPN_DNS=$(normalize_dns_list "$VPN_DNS")
  if [[ "$IPV6_MODE" != "nat" ]]; then
    VPN_DNS=$(dns_list_drop_ipv6 "$VPN_DNS")
  fi
  [[ -n "$VPN_DNS" ]] || {
    echo "VPN DNS is invalid. Use IP addresses separated by commas."
    return 1
  }

  local conflicts
  conflicts="$(conflicting_local_networks "$VPN_POOL_CIDR")"
  if [[ -n "$conflicts" ]]; then
    echo "Warning: VPN pool $VPN_POOL_CIDR overlaps networks already present on this host:"
    print_indented "$conflicts"
    echo "Routing for those networks will break for VPN clients."
  fi

  [[ "$CLIENT_ISOLATION" == "0" || "$CLIENT_ISOLATION" == "1" ]] || {
    echo "Client isolation must be 0 or 1."
    return 1
  }
  valid_egress_policy "$EGRESS_POLICY" || {
    echo "Egress policy must be internet-only or open."
    return 1
  }
  valid_port_list "$EGRESS_HOST_TCP_PORTS" || {
    echo "Host TCP port list for VPN clients is invalid."
    return 1
  }
  valid_port_list "$EGRESS_HOST_UDP_PORTS" || {
    echo "Host UDP port list for VPN clients is invalid."
    return 1
  }
  EGRESS_HOST_TCP_PORTS=$(normalize_port_list "$EGRESS_HOST_TCP_PORTS")
  EGRESS_HOST_UDP_PORTS=$(normalize_port_list "$EGRESS_HOST_UDP_PORTS")
  valid_cert_key_type "$CERT_KEY_TYPE" || {
    echo "Certificate key type must be one of: rsa2048, rsa3072, rsa4096, ec256, ec384."
    return 1
  }
  valid_ike_unique "$IKE_UNIQUE" || {
    echo "IKE uniqueness policy must be one of: never, no, keep, replace."
    return 1
  }
  [[ "$HARDEN_INPUT" == "0" || "$HARDEN_INPUT" == "1" ]] || {
    echo "Inbound hardening must be 0 or 1."
    return 1
  }
  valid_port_list "$HARDEN_TCP_PORTS" || {
    echo "Extra TCP port list is invalid."
    return 1
  }
  valid_port_list "$HARDEN_UDP_PORTS" || {
    echo "Extra UDP port list is invalid."
    return 1
  }
  HARDEN_TCP_PORTS=$(normalize_port_list "$HARDEN_TCP_PORTS")
  HARDEN_UDP_PORTS=$(normalize_port_list "$HARDEN_UDP_PORTS")
}
install_wizard() {
  render_header
  echo -e "${WHITE}Install / reinstall IKEv2 fixed scenario${NC}"
  echo

  if ! os_supported; then
    report_error "Unsupported OS. Tested releases: Ubuntu $(supported_os_list)."
    pause
    return 1
  fi

  ensure_manager_dir

  DOMAIN=$(ask "Domain name for VPN server" "${DOMAIN:-}")
  ACME_EMAIL=$(ask "Email for acme.sh (optional)" "${ACME_EMAIL:-}")
  echo
  select_acme_mode ACME_MODE "${ACME_MODE:-$DEFAULT_ACME_MODE}"

  DNS_PROVIDER="${DNS_PROVIDER:-dns_timeweb}"
  if [[ "$ACME_MODE" == "dns-01" ]]; then
    DNS_PROVIDER=$(ask "acme.sh DNS provider" "$DNS_PROVIDER")
  else
    DNS_PROVIDER=""
  fi

  UPLINK_IF=$(ask "Uplink interface" "${UPLINK_IF:-$(detect_uplink_if || true)}")
  VPN_POOL_CIDR=$(ask "VPN subnet (CIDR, for NAT/firewall)" "${VPN_POOL_CIDR:-$DEFAULT_POOL_CIDR}")
  VPN_POOL_RANGE=$(ask "VPN lease range (for strongSwan pool)" "${VPN_POOL_RANGE:-$DEFAULT_POOL_RANGE}")
  VPN_DNS=$(ask "DNS servers for VPN clients (comma-separated)" "${VPN_DNS:-$(detect_default_dns || true)}")
  VPN_DNS=$(normalize_dns_list "$VPN_DNS")
  VPN_DNS="${VPN_DNS:-$DEFAULT_DNS_FALLBACK}"

  local ipv6_default="block"
  if host_has_global_ipv6; then
    ipv6_default="nat"
  fi
  echo
  echo "IPv6 modes:"
  echo "  block = clients tunnel IPv6 and the server drops it (prevents IPv6 leaks)"
  echo "  nat   = full IPv6 for clients via NAT66 (host needs global IPv6)"
  echo "  off   = IPv4 only (dual-stack clients will leak IPv6 outside the VPN)"
  IPV6_MODE=$(ask "IPv6 mode (block/nat/off)" "${IPV6_MODE:-$ipv6_default}")
  IPV6_MODE="${IPV6_MODE,,}"
  if [[ "$IPV6_MODE" != "off" ]]; then
    VPN_POOL6_CIDR=$(ask "VPN IPv6 pool (CIDR)" "${VPN_POOL6_CIDR:-$DEFAULT_POOL6_CIDR}")
  fi

  echo
  echo "Inbound hardening appends a default-drop allowlist to INPUT:"
  echo "only loopback, ICMP, IKEv2/ESP, SSH, MTProto proxy and the extra ports"
  echo "listed below stay reachable. Anything else (panels, agents, etc.)"
  echo "must be listed explicitly or it becomes unreachable from outside."
  HARDEN_INPUT=$(ask "Enable inbound hardening (1/0)" "${HARDEN_INPUT:-$DEFAULT_HARDEN_INPUT}")
  if [[ "$HARDEN_INPUT" == "1" ]]; then
    echo
    echo "Currently listening sockets (for reference):"
    ss -Hlntu 2>/dev/null | awk '{ print $1, $5 }' | sort -u | head -n 20 || true
    HARDEN_TCP_PORTS=$(ask "Extra allowed inbound TCP ports (comma-separated, empty for none)" "${HARDEN_TCP_PORTS:-}")
    HARDEN_UDP_PORTS=$(ask "Extra allowed inbound UDP ports (comma-separated, empty for none)" "${HARDEN_UDP_PORTS:-}")
  fi
  CLIENT_ISOLATION=$(ask "Drop VPN client-to-client traffic (1/0)" "${CLIENT_ISOLATION:-1}")

  echo
  echo "Egress policy for VPN clients:"
  echo "  internet-only = block cloud metadata (169.254.0.0/16), private"
  echo "                  networks and this host's own services"
  echo "  open          = route everything, including the hosting network"
  EGRESS_POLICY=$(ask "Egress policy (internet-only/open)" "${EGRESS_POLICY:-$DEFAULT_EGRESS_POLICY}")
  EGRESS_POLICY="${EGRESS_POLICY,,}"
  if [[ "$EGRESS_POLICY" == "internet-only" ]]; then
    echo "Under internet-only, services on this host (SSH, proxies) are not"
    echo "reachable from the tunnel unless their ports are listed here."
    EGRESS_HOST_TCP_PORTS=$(ask "Host TCP ports reachable from VPN clients (empty for none)" "${EGRESS_HOST_TCP_PORTS:-}")
    EGRESS_HOST_UDP_PORTS=$(ask "Host UDP ports reachable from VPN clients (empty for none)" "${EGRESS_HOST_UDP_PORTS:-}")
  fi

  echo
  echo "Certificate key type: rsa2048 is the most compatible, ec256 produces"
  echo "smaller IKE_AUTH payloads and is supported by Windows 10+, iOS,"
  echo "macOS and strongSwan clients."
  CERT_KEY_TYPE=$(ask "Certificate key type (rsa2048/rsa3072/rsa4096/ec256/ec384)" "${CERT_KEY_TYPE:-$DEFAULT_CERT_KEY_TYPE}")
  CERT_KEY_TYPE="${CERT_KEY_TYPE,,}"

  if [[ "$ACME_MODE" == "http-01" ]]; then
    echo
    echo -e "${YELLOW}HTTP-01 note:${NC} the server must be reachable from the Internet on TCP/80 during validation."
    if [[ "$(detect_topology_hint)" == private/NAT* ]]; then
      echo -e "${YELLOW}Behind NAT detected:${NC} forward external TCP/80 to this host before certificate issuance."
    fi
  fi

  echo
  if [[ "$ACME_MODE" == "dns-01" ]]; then
    read -r -p "Refresh ACME provider environment variables now? [Y/n]: " reply || true
    if [[ ! "$reply" =~ ^[Nn]$ ]]; then
      ask_acme_provider_env
    elif [[ ! -f "$ACME_ENV_FILE" ]]; then
      echo "ACME env file does not exist yet. It must be created now."
      ask_acme_provider_env
    fi
  fi

  if ! validate_install_inputs; then
    pause
    return 1
  fi
  if ! validate_acme_env; then
    pause
    return 1
  fi

  echo
  echo "Installing packages..."
  if ! ensure_packages; then
    report_error "Package installation failed."
    pause
    return 1
  fi

  echo "Installing acme.sh..."
  if ! ensure_acme_installed; then
    report_error "acme.sh installation failed."
    pause
    return 1
  fi

  echo "Writing manager config..."
  INSTALLED=0
  save_config

  echo "Checking kernel IPsec support..."
  if ! ensure_kernel_ipsec_support; then
    pause
    return 1
  fi

  echo "Enabling IPv4 forwarding..."
  if ! enable_sysctl; then
    report_error "Failed to enable IPv4 forwarding."
    pause
    return 1
  fi

  echo "Issuing and installing RSA certificate..."
  if ! issue_and_install_cert; then
    report_error "Certificate issuance or installation failed."
    pause
    return 1
  fi

  echo "Generating swanctl configuration..."
  if ! generate_swanctl_conf; then
    report_error "Failed to generate swanctl configuration."
    pause
    return 1
  fi

  echo "Validating swanctl configuration..."
  systemctl start "$(detect_service_name).service" >/dev/null 2>&1 || true
  if ! swanctl --load-all >/dev/null 2>&1; then
    report_error "Generated swanctl configuration is invalid. Inspect /etc/swanctl/swanctl.conf and retry."
    INSTALLED=0
    save_config
    pause
    return 1
  fi

  echo "Starting VPN service..."
  if ! restart_vpn_service; then
    report_error "Failed to start VPN service."
    pause
    return 1
  fi
  load_swanctl

  echo "Applying firewall rules..."
  if ! apply_firewall_rules; then
    report_error "Failed to apply firewall rules."
    pause
    return 1
  fi

  INSTALLED=1
  save_config

  echo
  echo "Installation complete."
  pause
}
random_password() {
  openssl rand -base64 24 | tr -d '\n' | tr '/+=' 'XYZ'
}

ensure_users_db() {
  ensure_manager_dir
  touch "$USERS_DB"
  chmod 600 "$USERS_DB"
  migrate_users_db
}

migrate_users_db() {
  [[ -f "$USERS_DB" ]] || return 0
  local tmp line db_user db_pass db_group db_platform _db_rest
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" == username\|password\|group\|platform ]]; then
      continue
    fi
    if [[ "$line" == *'|'* ]]; then
      IFS='|' read -r db_user db_pass db_group db_platform _db_rest <<<"$line"
    else
      IFS=$'\t' read -r db_user db_pass _db_rest <<<"$line"
      db_group="$(infer_group_from_username "$db_user")"
      db_platform="unknown"
    fi
    [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
    db_group="${db_group:-$(infer_group_from_username "$db_user")}"
    db_platform="$(normalize_platform "${db_platform:-unknown}")"
    valid_platform "$db_platform" || db_platform="unknown"
    printf '%s|%s|%s|%s\n' "$db_user" "$db_pass" "$db_group" "$db_platform" >>"$tmp"
  done <"$USERS_DB"
  mv "$tmp" "$USERS_DB"
  chmod 600 "$USERS_DB"
  return 0
}

add_or_update_user() {
  render_header
  ensure_users_db
  local username password group platform choice tmpfile found=0 db_user db_pass db_group db_platform _db_rest

  username=$(ask "Username")
  if ! valid_username "$username"; then
    echo "Username is empty or contains invalid characters. Allowed: letters, digits, dot, underscore, at, hyphen."
    pause
    return 1
  fi

  group=$(ask "Group/label" "$(infer_group_from_username "$username")")
  if ! valid_group_name "$group"; then
    echo "Group is empty or contains invalid characters. Allowed: letters, digits, dot, underscore, at, hyphen."
    pause
    return 1
  fi

  echo "Platform: windows / ios / macos / ubuntu / unknown"
  platform=$(normalize_platform "$(ask "Platform" "unknown")")
  if ! valid_platform "$platform"; then
    echo "Invalid platform. Use: windows, ios, macos, ubuntu, unknown."
    pause
    return 1
  fi

  read -r -p "Generate random password? [Y/n]: " choice || true
  if [[ ! "$choice" =~ ^[Nn]$ ]]; then
    password=$(random_password)
  else
    password=$(ask_secret "Password")
    if [[ -z "$password" || "$password" == *'|'* || "$password" == *'"'* || "$password" == *"\\"* || "$password" == *$'\t'* || "$password" == *$'\n'* ]]; then
      echo "Password is empty or contains invalid characters (| \" \\ tab newline)."
      pause
      return 1
    fi
  fi

  tmpfile=$(mktemp)
  while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
    [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
    if [[ "$db_user" == "$username" ]]; then
      printf '%s|%s|%s|%s\n' "$username" "$password" "$group" "$platform" >>"$tmpfile"
      found=1
    else
      printf '%s|%s|%s|%s\n' "$db_user" "$db_pass" "${db_group:-$(infer_group_from_username "$db_user")}" "${db_platform:-unknown}" >>"$tmpfile"
    fi
  done <"$USERS_DB"
  if [[ "$found" -eq 0 ]]; then
    printf '%s|%s|%s|%s\n' "$username" "$password" "$group" "$platform" >>"$tmpfile"
  fi
  mv "$tmpfile" "$USERS_DB"
  chmod 600 "$USERS_DB"

  generate_swanctl_conf
  systemctl start "$(detect_service_name).service" >/dev/null 2>&1 || true
  # --clear drops stale in-memory credentials (e.g. an old password).
  if ! swanctl --load-all --clear >/dev/null 2>&1; then
    report_error "Generated swanctl configuration is invalid. User database was updated, but VPN config reload was blocked."
    pause
    return 1
  fi

  echo
  if [[ "$found" -eq 1 ]]; then
    echo "User updated."
  else
    echo "User added."
  fi
  echo "Username: $username"
  echo "Password: $password"
  echo "Group:    $group"
  echo "Platform: $platform"
  pause
}

list_users_menu() {
  render_header
  ensure_users_db
  if [[ ! -s "$USERS_DB" ]]; then
    echo "No VPN users configured."
    pause
    return 0
  fi
  echo "Configured VPN users"
  echo "--------------------"
  printf '%-3s %-24s %-16s %-10s
' "#" "Username" "Group" "Platform"
  local idx=1 db_user db_pass db_group db_platform _db_rest
  while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
    [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
    printf '%-3s %-24s %-16s %-10s
' "$idx)" "$db_user" "${db_group:-$(infer_group_from_username "$db_user")}" "${db_platform:-unknown}"
    idx=$((idx + 1))
  done <"$USERS_DB"
  pause
}

remove_user_menu() {
  render_header
  ensure_users_db
  if [[ ! -s "$USERS_DB" ]]; then
    echo "No VPN users configured."
    pause
    return 0
  fi

  local -a users=()
  local db_user db_pass db_group db_platform _db_rest idx choice tmpfile
  while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
    [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
    users+=("$db_user")
  done <"$USERS_DB"

  echo "Choose user to remove"
  echo "---------------------"
  for idx in "${!users[@]}"; do
    printf '%2d) %s
' "$((idx + 1))" "${users[$idx]}"
  done
  echo
  menu_enter_hint "Cancel"
  echo
  read -r -p "Selection: " choice || true
  if [[ "$choice" == "0" || -z "$choice" ]]; then
    return 0
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#users[@]})); then
    echo "Invalid selection."
    pause
    return 1
  fi

  tmpfile=$(mktemp)
  while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
    [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
    if [[ "$db_user" != "${users[$((choice - 1))]}" ]]; then
      printf '%s|%s|%s|%s
' "$db_user" "$db_pass" "${db_group:-$(infer_group_from_username "$db_user")}" "${db_platform:-unknown}" >>"$tmpfile"
    fi
  done <"$USERS_DB"
  mv "$tmpfile" "$USERS_DB"
  chmod 600 "$USERS_DB"

  generate_swanctl_conf
  systemctl start "$(detect_service_name).service" >/dev/null 2>&1 || true
  # --clear ensures the removed user's secret is unloaded from charon.
  if ! swanctl --load-all --clear >/dev/null 2>&1; then
    report_error "Generated swanctl configuration is invalid. User database was updated, but VPN config reload was blocked."
    pause
    return 1
  fi
  terminate_user_sas "${users[$((choice - 1))]}"

  echo "User removed: ${users[$((choice - 1))]}"
  pause
}

get_group_users() {
  local group="$1" platform_filter="${2:-}"
  ensure_users_db
  local db_user db_pass db_group db_platform _db_rest
  while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
    [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
    db_group="${db_group:-$(infer_group_from_username "$db_user")}"
    db_platform="${db_platform:-unknown}"
    if [[ "$db_group" == "$group" && (-z "$platform_filter" || "$db_platform" == "$platform_filter") ]]; then
      printf '%s|%s|%s|%s\n' "$db_user" "$db_pass" "$db_group" "$db_platform"
    fi
  done <"$USERS_DB"
}

# The group is the explicit third field; only when it is missing is it
# inferred from the username prefix. Trimming everything after a hyphen from
# an explicit group made hyphenated group names impossible to select.
list_groups() {
  ensure_users_db
  awk -F'|' 'NF && $1 !~ /^[[:space:]]*$/ && $1 != "username" {
    if ($3 != "") {
      print $3
    } else {
      g = $1
      sub(/-.*/, "", g)
      print (g == "" ? "default" : g)
    }
  }' "$USERS_DB" | sort -u
}

select_group_prompt() {
  ensure_users_db
  local -a groups=()
  local line input

  while IFS= read -r line; do
    [[ -n "$line" ]] && groups+=("$line")
  done < <(list_groups)

  if ((${#groups[@]} == 0)); then
    echo "No groups found." >&2
    return 1
  fi

  # Everything except the selected group goes to stderr: the caller reads
  # this function through a command substitution, so anything printed on
  # stdout would end up inside the returned value.
  echo "Available groups" >&2
  echo "----------------" >&2
  local i
  for i in "${!groups[@]}"; do
    printf "%2d) %s\n" "$((i + 1))" "${groups[$i]}" >&2
  done
  echo >&2

  input=$(ask "Group/label to export (number or name)")
  input="$(trim "$input")"

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    if ((input >= 1 && input <= ${#groups[@]})); then
      printf '%s\n' "${groups[$((input - 1))]}"
      return 0
    fi
    echo "Group number out of range: $input" >&2
    return 1
  fi

  if ! valid_group_name "$input"; then
    echo "Invalid group." >&2
    return 1
  fi

  for line in "${groups[@]}"; do
    if [[ "$line" == "$input" ]]; then
      printf '%s\n' "$input"
      return 0
    fi
  done

  echo "Group not found: $input" >&2
  return 1
}

make_ios_mobileconfig() {
  local host="$1" display_name="$2" out_file="$3"
  local uuid_root uuid_vpn payload_id root_id
  uuid_root=$(new_uuid)
  uuid_vpn=$(new_uuid)
  payload_id="com.nikitid.ikev2.$(date +%s).$(openssl rand -hex 4)"
  root_id="com.nikitid.ikev2.root.$(date +%s).$(openssl rand -hex 4)"
  cat >"$out_file" <<EOF_PROFILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>IKEv2</key>
      <dict>
        <key>AuthenticationMethod</key><string>None</string>
        <key>RemoteAddress</key><string>${host}</string>
        <key>RemoteIdentifier</key><string>${host}</string>
        <key>ExtendedAuthEnabled</key><true/>
        <key>DisableMOBIKE</key><integer>0</integer>
        <key>OnDemandEnabled</key><integer>0</integer>
      </dict>
      <key>PayloadDisplayName</key><string>${display_name}</string>
      <key>PayloadIdentifier</key><string>${payload_id}</string>
      <key>PayloadOrganization</key><string>Nikitid</string>
      <key>PayloadType</key><string>com.apple.vpn.managed</string>
      <key>PayloadUUID</key><string>${uuid_vpn}</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>UserDefinedName</key><string>${display_name}</string>
      <key>VPNType</key><string>IKEv2</string>
    </dict>
  </array>
  <key>PayloadDisplayName</key><string>${display_name}</string>
  <key>PayloadIdentifier</key><string>${root_id}</string>
  <key>PayloadOrganization</key><string>Nikitid</string>
  <key>PayloadRemovalDisallowed</key><false/>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>${uuid_root}</string>
  <key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
EOF_PROFILE
}

make_ubuntu_script() {
  local host="$1" out_file="$2"
  local ca_content="" ca_label="root" right_subnet="0.0.0.0/0"
  if [[ "${IPV6_MODE:-off}" != "off" ]]; then
    right_subnet="0.0.0.0/0,::/0"
  fi
  # Pin the trust anchor, not the intermediate: Let's Encrypt rotates
  # intermediates, and a client that trusts only the intermediate stops
  # connecting on the next rotation.
  if [[ -f "$CA_ROOT_PATH" ]]; then
    ca_content="$(<"$CA_ROOT_PATH")"
  elif [[ -f "$CA_PATH" ]]; then
    ca_content="$(<"$CA_PATH")"
    ca_label="issuer"
  fi

  cat >"$out_file" <<EOF_UBUNTU
#!/usr/bin/env bash
set -euo pipefail
read -r -p "Username: " VPN_USER
read -r -s -p "Password: " VPN_PASS
echo

# Existing IPsec configuration on this machine is preserved.
stamp="\$(date +%Y%m%d-%H%M%S)"
for existing in /etc/ipsec.conf /etc/ipsec.secrets; do
  if [[ -f "\$existing" ]]; then
    sudo cp -a "\$existing" "\${existing}.bak.\${stamp}"
    echo "Backed up \$existing to \${existing}.bak.\${stamp}"
  fi
done

sudo apt-get update
sudo apt-get install -y strongswan libcharon-extra-plugins libcharon-extauth-plugins
EOF_UBUNTU

  # charon does not use the system CA store, so ship the trust anchor with
  # the script.
  if [[ -n "$ca_content" ]]; then
    cat >>"$out_file" <<EOF_CA_BLOCK
sudo mkdir -p /etc/ipsec.d/cacerts
sudo tee '/etc/ipsec.d/cacerts/${host}-${ca_label}.pem' >/dev/null <<'EOF_CA'
${ca_content}
EOF_CA
EOF_CA_BLOCK
  fi

  cat >>"$out_file" <<EOF_UBUNTU
sudo tee /etc/ipsec.conf >/dev/null <<EOF
conn ikev2
    keyexchange=ikev2
    right=${host}
    rightid=@${host}
    rightsubnet=${right_subnet}
    rightauth=pubkey
    left=%defaultroute
    leftsourceip=%config
    leftauth=eap-mschapv2
    eap_identity=\$VPN_USER
    auto=add
EOF
sudo tee /etc/ipsec.secrets >/dev/null <<EOF
\$VPN_USER : EAP "\$VPN_PASS"
EOF
sudo chmod 600 /etc/ipsec.secrets
sudo systemctl restart strongswan-starter 2>/dev/null || sudo systemctl restart strongswan
sudo ipsec up ikev2 || true
EOF_UBUNTU
  chmod +x "$out_file"
}

credentials_html_for_platform() {
  local group="$1" platform="$2" u p _g _pl
  while IFS='|' read -r u p _g _pl; do
    [[ -z "$u" ]] && continue
    printf '<code>%s</code> — <code>%s</code>\n' "$(html_escape "$u")" "$(html_escape "$p")"
  done < <(get_group_users "$group" "$platform")
}

windows_message_file() {
  local group="$1" out_file="$2" host add_cmd set_cmd creds
  host="${DOMAIN}"
  add_cmd="Add-VpnConnection -Name \"${host}\" \`
  -ServerAddress \"${host}\" \`
  -TunnelType IKEv2 \`
  -EncryptionLevel Maximum \`
  -AuthenticationMethod EAP \`
  -RememberCredential"
  set_cmd="Set-VpnConnectionIPsecConfiguration -ConnectionName \"${host}\" \`
  -AuthenticationTransformConstants GCMAES256 \`
  -CipherTransformConstants GCMAES256 \`
  -EncryptionMethod GCMAES256 \`
  -IntegrityCheckMethod SHA384 \`
  -DHGroup ECP384 \`
  -PfsGroup ECP384 \`
  -Force"
  creds=$(credentials_html_for_platform "$group" "windows")
  cat >"$out_file" <<EOF_WIN
<b>VPN настройка для ПК</b>
1) В PowerShell нужно вставить два абзаца (раздельно два абзаца).

<pre><code class="language-powershell">$(html_escape "$add_cmd")</code></pre>

<pre><code class="language-powershell">$(html_escape "$set_cmd")</code></pre>

2) Проваливаемся в панель с управлением Wi‑Fi и другим, находим VPN — подключаемся (через стрелочку на правой части кнопки)
3) Вбиваем свои учетные данные от устройства

<b>Учетные данные:</b>
${creds:-<i>Windows users for group not found.</i>}
EOF_WIN
}

ios_message_file() {
  local group="$1" platform="$2" title="$3" out_file="$4" creds
  creds=$(credentials_html_for_platform "$group" "$platform")
  cat >"$out_file" <<EOF_IOS
<b>${title}</b>
1) Качаем файл ниже
2) Сохраняем где угодно, например в загрузках
3) Нажимаем на него и видим сообщение об успешной установке профиля
4) Заходим в "Настройки - Общие - Управление VPN" и видим там профиль который добавили ранее. Нажимаем на него и устанавливаем
5) Дальше он запросит учетные данные VPN
6) После успешного подключения в профиле VPN нужно отключить "Connect On Demand"

<b>Учетные данные:</b>
${creds:-<i>Users for group/platform not found.</i>}
EOF_IOS
}

ubuntu_message_file() {
  local group="$1" out_file="$2" creds
  creds=$(credentials_html_for_platform "$group" "ubuntu")
  cat >"$out_file" <<EOF_UBMSG
<b>VPN настройка для Ubuntu</b>
1) Скачай файл ниже
2) Выполни: <code>chmod +x *.sh</code>
3) Запусти: <code>sudo ./имя-файла.sh</code>
4) Введи учетные данные устройства

<b>Учетные данные:</b>
${creds:-<i>Ubuntu users for group not found.</i>}
EOF_UBMSG
}

generate_client_bundle_local() {
  render_header
  if ! effective_installed; then
    echo "VPN server is not installed."
    pause
    return 1
  fi
  ensure_users_db
  if [[ ! -s "$USERS_DB" ]]; then
    echo "No users configured."
    pause
    return 1
  fi

  local group
  if ! group="$(select_group_prompt)"; then
    pause
    return 1
  fi

  if [[ -z "$(get_group_users "$group")" ]]; then
    echo "Group not found: $group"
    pause
    return 1
  fi

  local ts bundle_dir user _pass _g _platform file safe_user previous_umask
  # The guides carry plaintext credentials; create every file unreadable to
  # anyone but root instead of fixing the mode afterwards.
  previous_umask="$(umask)"
  umask 077
  ts=$(date +%Y%m%d-%H%M%S)
  bundle_dir="$EXPORTS_DIR/${DOMAIN}_${group}_${ts}"
  mkdir -p "$bundle_dir/windows" "$bundle_dir/ios" "$bundle_dir/macos" "$bundle_dir/ubuntu"
  chmod 700 "$EXPORTS_DIR"

  if [[ -n "$(get_group_users "$group" "windows")" ]]; then
    windows_message_file "$group" "$bundle_dir/windows/windows-guide.html"
    cat >"$bundle_dir/windows/windows-apply.ps1" <<EOF_WINPS
Add-VpnConnection -Name "${DOMAIN}" \`
  -ServerAddress "${DOMAIN}" \`
  -TunnelType IKEv2 \`
  -EncryptionLevel Maximum \`
  -AuthenticationMethod EAP \`
  -RememberCredential

Set-VpnConnectionIPsecConfiguration -ConnectionName "${DOMAIN}" \`
  -AuthenticationTransformConstants GCMAES256 \`
  -CipherTransformConstants GCMAES256 \`
  -EncryptionMethod GCMAES256 \`
  -IntegrityCheckMethod SHA384 \`
  -DHGroup ECP384 \`
  -PfsGroup ECP384 \`
  -Force
EOF_WINPS
  fi

  if [[ -n "$(get_group_users "$group" "ios")" ]]; then
    ios_message_file "$group" "ios" "VPN настройка для IPhone" "$bundle_dir/ios/ios-guide.html"
    while IFS='|' read -r user _pass _g _platform; do
      [[ -z "$user" ]] && continue
      safe_user="${user//[^A-Za-z0-9._@-]/_}"
      file="$bundle_dir/ios/${DOMAIN}-${safe_user}.mobileconfig"
      make_ios_mobileconfig "$DOMAIN" "${DOMAIN} ${user}" "$file"
    done < <(get_group_users "$group" "ios")
  fi

  if [[ -n "$(get_group_users "$group" "macos")" ]]; then
    ios_message_file "$group" "macos" "VPN настройка для macOS" "$bundle_dir/macos/macos-guide.html"
    while IFS='|' read -r user _pass _g _platform; do
      [[ -z "$user" ]] && continue
      safe_user="${user//[^A-Za-z0-9._@-]/_}"
      file="$bundle_dir/macos/${DOMAIN}-${safe_user}.mobileconfig"
      make_ios_mobileconfig "$DOMAIN" "${DOMAIN} ${user}" "$file"
    done < <(get_group_users "$group" "macos")
  fi

  if [[ -n "$(get_group_users "$group" "ubuntu")" ]]; then
    ubuntu_message_file "$group" "$bundle_dir/ubuntu/ubuntu-guide.html"
    make_ubuntu_script "$DOMAIN" "$bundle_dir/ubuntu/${DOMAIN}-ubuntu.sh"
  fi

  chmod -R go-rwx "$bundle_dir"
  umask "$previous_umask"

  echo "Client bundle exported locally:"
  echo "$bundle_dir"
  echo
  find "$bundle_dir" -maxdepth 2 -type f | sort
  pause
}

# ------------------------- MTProto proxy manager -------------------------
# Backend: mtproto.zig — a lightweight Telegram proxy in Zig with FakeTLS.
# Source:  https://github.com/sleep3r/mtproto.zig
# Author:  Aleksandr Kalashnikov (sleep3r)
# License: MIT — copyright notice preserved in THIRD_PARTY_LICENSES.md.
#
# The proxy is installed and managed via the mtbuddy CLI downloaded from the
# project's GitHub releases. The TLS impersonation domain (tls_domain) is
# permanent after installation; changing it requires a full reinstall and
# invalidates all distributed tg:// links.

mt_is_installed() {
  [[ -x "$MT_BUDDY_BIN" && -d "$MT_INSTALL_DIR" && -f "$MT_SERVICE_FILE" ]]
}

mt_require_installed() {
  if ! mt_is_installed; then
    echo -e "${RED}MTProto proxy is not installed${NC}"
    sleep 2
    return 1
  fi
}

mt_load_config() {
  MT_PORT="$MT_DEFAULT_PORT"
  MT_TLS_DOMAIN="$MT_DEFAULT_TLS_DOMAIN"
  MT_SECRET=""

  [[ -f "$MT_CONFIG_FILE" ]] || return 0

  local raw_port raw_domain
  raw_port="$(awk '/^\[server\]/{f=1;next} /^\[/{f=0} \
    f && /^[[:space:]]*port[[:space:]]*=/ \
    {sub(/.*=[[:space:]]*/,""); gsub(/[^0-9]/,"",$0); print; exit}' \
    "$MT_CONFIG_FILE" 2>/dev/null || true)"
  [[ -n "$raw_port" ]] && MT_PORT="$raw_port"

  raw_domain="$(awk '/^\[censorship\]/{f=1;next} /^\[/{f=0} \
    f && /tls_domain[[:space:]]*=/ \
    {sub(/.*=[[:space:]]*/,""); sub(/[[:space:]]*#.*/,""); gsub(/"/,""); print; exit}' \
    "$MT_CONFIG_FILE" 2>/dev/null || true)"
  [[ -n "$raw_domain" ]] && MT_TLS_DOMAIN="$raw_domain"

  MT_SECRET="$(mt_user_secret "")"
}

# Secret of a named proxy user, or of the first one when no name is given.
# Printing the first user's secret after adding an account handed out the
# wrong credential and made per-user revocation impossible.
mt_user_secret() {
  local wanted="$1"
  [[ -f "$MT_CONFIG_FILE" ]] || return 0
  awk -v wanted="$wanted" '
    /^\[access\.users\]/ { in_users = 1; next }
    /^\[/ { in_users = 0 }
    in_users && /=[[:space:]]*"/ {
      name = $0
      sub(/[[:space:]]*=.*$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      value = $0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      if (wanted == "" || name == wanted) {
        print value
        exit
      }
    }
  ' "$MT_CONFIG_FILE" 2>/dev/null || true
}

mt_list_users() {
  [[ -f "$MT_CONFIG_FILE" ]] || return 0
  awk '
    /^\[access\.users\]/ { in_users = 1; next }
    /^\[/ { in_users = 0 }
    in_users && /=[[:space:]]*"/ {
      name = $0
      sub(/[[:space:]]*=.*$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != "") print name
    }
  ' "$MT_CONFIG_FILE" 2>/dev/null || true
}

mt_validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535)) || return 1
  return 0
}

mt_port_in_use() {
  local port="$1"
  ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q .
}

mt_get_server_ip() {
  local ip

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "src") {
        print $(i+1)
        exit
      }
    }
  }')"

  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

mt_build_link() {
  local user="${1:-}"
  mt_load_config
  local host domain_hex secret

  if ! command -v xxd >/dev/null 2>&1; then
    echo "link unavailable: xxd is not installed"
    return 1
  fi

  # A public hostname survives NAT; the detected source address does not.
  host="${DOMAIN:-}"
  if [[ -z "$host" ]]; then
    host="$(mt_get_server_ip 2>/dev/null || true)"
    host="${host:-YOUR_IP}"
  fi

  secret="$MT_SECRET"
  if [[ -n "$user" ]]; then
    secret="$(mt_user_secret "$user")"
  fi
  if [[ -z "$secret" ]]; then
    echo "link unavailable: no proxy user secret found"
    return 1
  fi

  domain_hex="$(printf '%s' "$MT_TLS_DOMAIN" | xxd -ps -c 999 | tr -d '\n')"
  printf 'tg://proxy?server=%s&port=%s&secret=ee%s%s\n' \
    "$host" "$MT_PORT" "$secret" "$domain_hex"
}

mt_service_status() {
  local active_state sub_state

  active_state="$(systemctl show -p ActiveState --value "${MT_SERVICE}.service" 2>/dev/null || true)"
  sub_state="$(systemctl show -p SubState --value "${MT_SERVICE}.service" 2>/dev/null || true)"

  if [[ -z "$active_state" ]]; then
    echo "unknown"
    return 0
  fi

  if [[ "$active_state" == "inactive" && "$sub_state" == "dead" ]]; then
    echo "stopped"
    return 0
  fi

  if [[ -n "$sub_state" ]]; then
    echo "${active_state}/${sub_state}"
  else
    echo "$active_state"
  fi
}

mt_service_is_running() {
  local active_state sub_state

  active_state="$(systemctl show -p ActiveState --value "${MT_SERVICE}.service" 2>/dev/null || true)"
  sub_state="$(systemctl show -p SubState --value "${MT_SERVICE}.service" 2>/dev/null || true)"

  [[ "$active_state" == "active" && "$sub_state" == "running" ]]
}

mt_verify_service_started() {
  local attempts=15 stable=0 active_state sub_state

  while ((attempts > 0)); do
    active_state="$(systemctl show -p ActiveState --value "${MT_SERVICE}.service" 2>/dev/null || true)"
    sub_state="$(systemctl show -p SubState --value "${MT_SERVICE}.service" 2>/dev/null || true)"

    if [[ "$active_state" == "active" && "$sub_state" == "running" ]]; then
      stable=$((stable + 1))
      if ((stable >= 3)); then
        return 0
      fi
    elif [[ "$active_state" == "failed" || "$sub_state" == "failed" ]]; then
      break
    else
      stable=0
    fi

    sleep 1
    attempts=$((attempts - 1))
  done

  echo -e "${RED}MTProto proxy service failed to start${NC}"
  echo
  systemctl --no-pager --full status "${MT_SERVICE}.service" || true
  echo
  journalctl -u "${MT_SERVICE}.service" -n 30 --no-pager || true
  return 1
}

mt_firewall_add() {
  mt_load_config
  iptables -C INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproto-manager" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproto-manager" -j ACCEPT
}

mt_firewall_remove() {
  mt_load_config
  while iptables -C INPUT -p tcp --dport "$MT_PORT" \
    -m comment --comment "mtproto-manager" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp --dport "$MT_PORT" \
      -m comment --comment "mtproto-manager" -j ACCEPT \
      || break
  done
}

mt_migrate_legacy() {
  # Remove the legacy C-based MTProxy installation if present.
  if [[ -f /etc/systemd/system/mtproxy.service ]]; then
    systemctl stop mtproxy.service 2>/dev/null || true
    systemctl disable mtproxy.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtproxy.service
    systemctl daemon-reload
  fi

  rm -rf /opt/MTProxy /etc/sysctl.d/99-mtproxy.conf

  # Remove legacy iptables rules inserted with comment "mtproxy-manager".
  local old_port old_internal_port
  old_port=""
  old_internal_port=""
  if [[ -f /etc/mtproxy-manager/config ]]; then
    old_port="$(sed -n 's/^MT_PORT="\([0-9]*\)"$/\1/p' \
      /etc/mtproxy-manager/config | head -n1 || true)"
    old_internal_port="$(sed -n 's/^MT_INTERNAL_PORT="\([0-9]*\)"$/\1/p' \
      /etc/mtproxy-manager/config | head -n1 || true)"
  fi

  if [[ -n "$old_port" ]]; then
    while iptables -C INPUT -p tcp --dport "$old_port" \
      -m comment --comment "mtproxy-manager" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$old_port" \
        -m comment --comment "mtproxy-manager" -j ACCEPT \
        || break
    done
  fi

  if [[ -n "$old_internal_port" ]]; then
    while iptables -C INPUT -p tcp --dport "$old_internal_port" \
      ! -i lo -m comment --comment "mtproxy-manager" -j DROP 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$old_internal_port" \
        ! -i lo -m comment --comment "mtproxy-manager" -j DROP \
        || break
    done
    if command -v ip6tables >/dev/null 2>&1; then
      while ip6tables -C INPUT -p tcp --dport "$old_internal_port" \
        ! -i lo -m comment --comment "mtproxy-manager" -j DROP 2>/dev/null; do
        ip6tables -D INPUT -p tcp --dport "$old_internal_port" \
          ! -i lo -m comment --comment "mtproxy-manager" -j DROP \
          || break
      done
    fi
  fi

  rm -rf /etc/mtproxy-manager
}

mt_client_ips_raw() {
  mt_load_config
  # Peer column is "1.2.3.4:443" or "[2a00::1]:443"; strip port and brackets.
  ss -Htn state established "( sport = :${MT_PORT} )" 2>/dev/null \
    | awk '{print $4}' \
    | sed -E 's/^\[//; s/\]?:[0-9]+$//' \
    | sed '/^$/d'
}

mt_client_ip_count() {
  mt_client_ips_raw | sort -u | wc -l
}

mt_install() {
  render_header
  echo -e "${CYAN}Installing MTProto proxy (mtproto.zig by sleep3r)...${NC}"
  echo

  local input_port input_tls_domain ans tmp_bootstrap
  read -r -p "Client port [${MT_DEFAULT_PORT}]: " input_port
  MT_PORT="${input_port:-$MT_DEFAULT_PORT}"

  if ! mt_validate_port "$MT_PORT"; then
    echo -e "${RED}Invalid port${NC}"
    sleep 2
    return 1
  fi

  if mt_port_in_use "$MT_PORT"; then
    echo -e "${RED}Port ${MT_PORT} is already in use by another service${NC}"
    echo "Check with: ss -tlnp | grep :${MT_PORT}"
    sleep 2
    return 1
  fi

  read -r -p "TLS impersonation domain [${MT_DEFAULT_TLS_DOMAIN}]: " input_tls_domain
  MT_TLS_DOMAIN="${input_tls_domain:-$MT_DEFAULT_TLS_DOMAIN}"

  if ! valid_domain_name "$MT_TLS_DOMAIN"; then
    echo -e "${RED}Invalid domain name${NC}"
    sleep 2
    return 1
  fi

  echo
  echo -e "${YELLOW}Warning:${NC} the TLS domain cannot be changed after installation."
  echo "A reinstall is required to change it; all existing tg:// links will stop working."
  echo
  read -r -p "Confirm installation with domain '${MT_TLS_DOMAIN}'? [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || return 0

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates xxd iptables

  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}curl is required${NC}"
    sleep 2
    return 1
  fi

  mt_migrate_legacy

  tmp_bootstrap="$(mktemp /tmp/mtproto-bootstrap.XXXXXX.sh)"
  # The bootstrap script is fetched from a moving branch, so its fingerprint
  # is shown and confirmed before it is executed.
  if ! fetch_and_confirm_script "$MT_BOOTSTRAP_URL" "$tmp_bootstrap" "$MT_BOOTSTRAP_SHA256"; then
    rm -f "$tmp_bootstrap"
    echo -e "${RED}Bootstrap script was not confirmed; installation aborted${NC}"
    sleep 2
    return 1
  fi
  bash "$tmp_bootstrap"
  rm -f "$tmp_bootstrap"

  if [[ ! -x "$MT_BUDDY_BIN" ]]; then
    echo -e "${RED}mtbuddy not found after bootstrap — installation failed${NC}"
    sleep 2
    return 1
  fi

  "$MT_BUDDY_BIN" install --port "$MT_PORT" --domain "$MT_TLS_DOMAIN" --yes

  if [[ ! -d "$MT_INSTALL_DIR" ]]; then
    echo -e "${RED}Installation failed: ${MT_INSTALL_DIR} not found${NC}"
    sleep 2
    return 1
  fi

  mt_firewall_add
  systemctl daemon-reload
  systemctl enable "${MT_SERVICE}.service" >/dev/null 2>&1

  if ! mt_service_is_running; then
    systemctl start "${MT_SERVICE}.service"
  fi

  if mt_verify_service_started; then
    echo
    echo -e "${GREEN}MTProto proxy installed successfully${NC}"
    mt_load_config
    echo -e "${YELLOW}Link:${NC} $(mt_build_link)"
    echo
  fi

  pause
}

mt_remove() {
  render_header
  mt_require_installed || return 1
  mt_load_config

  read -r -p "Remove MTProto proxy? Type DELETE: " ans || true
  [[ "$ans" == "DELETE" ]] || return 0

  mt_firewall_remove

  systemctl stop "${MT_SERVICE}.service" 2>/dev/null || true
  systemctl disable "${MT_SERVICE}.service" 2>/dev/null || true

  if [[ -x "$MT_BUDDY_BIN" ]]; then
    "$MT_BUDDY_BIN" remove --yes 2>/dev/null || true
  fi

  rm -f "$MT_SERVICE_FILE"
  rm -rf "$MT_INSTALL_DIR"
  rm -f "$MT_BUDDY_BIN"
  systemctl daemon-reload

  echo -e "${GREEN}MTProto proxy removed${NC}"
  sleep 2
}

mt_restart_or_start_service() {
  render_header
  mt_require_installed || return 1

  if mt_service_is_running; then
    systemctl restart "${MT_SERVICE}.service"
  else
    systemctl start "${MT_SERVICE}.service"
  fi

  if mt_verify_service_started; then
    echo -e "${GREEN}MTProto proxy service is running${NC}"
  fi

  sleep 2
}

mt_stop() {
  render_header
  mt_require_installed || return 1

  if mt_service_is_running; then
    systemctl stop "${MT_SERVICE}.service"
    echo -e "${GREEN}MTProto proxy stopped${NC}"
  else
    echo -e "${YELLOW}MTProto proxy is already stopped${NC}"
  fi

  sleep 2
}

mt_update() {
  render_header
  mt_require_installed || return 1
  mt_load_config

  if [[ ! -x "$MT_BUDDY_BIN" ]]; then
    echo -e "${RED}mtbuddy not found; cannot update${NC}"
    sleep 2
    return 1
  fi

  "$MT_BUDDY_BIN" upgrade

  systemctl restart "${MT_SERVICE}.service"
  if mt_verify_service_started; then
    echo -e "${GREEN}MTProto proxy updated successfully${NC}"
  fi

  sleep 2
}

mt_add_user() {
  render_header
  mt_require_installed || return 1

  local username
  read -r -p "Username: " username
  if [[ -z "$username" ]]; then
    echo -e "${RED}Username cannot be empty${NC}"
    sleep 2
    return 1
  fi

  if "$MT_BUDDY_BIN" user add "$username"; then
    mt_load_config
    echo
    echo -e "${YELLOW}Link for ${username}:${NC} $(mt_build_link "$username")"
  else
    echo
    echo "See 'mtbuddy --help' for user management commands."
  fi

  sleep 2
}

mt_show_active_ips() {
  render_header
  mt_require_installed || return 1
  mt_load_config

  echo -e "${YELLOW}Total ESTABLISHED connections:${NC}"
  ss -Htn state established "( sport = :${MT_PORT} )" 2>/dev/null | wc -l

  echo
  echo -e "${YELLOW}Unique active IPs:${NC}"
  mt_client_ip_count

  echo
  echo -e "${YELLOW}Top client IPs:${NC}"
  mt_client_ips_raw | sort | uniq -c | sort -nr | head -20

  echo
  pause
}

mt_show_logs() {
  render_header
  mt_require_installed || return 1
  journalctl -u "${MT_SERVICE}.service" -b -n 50 --no-pager || true
  echo
  pause
}

mt_show_status_link() {
  render_header
  mt_load_config
  echo -e "${YELLOW}MTProto proxy status:${NC} $(mt_service_status)"
  echo -e "${YELLOW}Port:${NC} ${MT_PORT}"
  echo -e "${YELLOW}TLS domain:${NC} ${MT_TLS_DOMAIN} (permanent)"
  echo -e "${YELLOW}Active IPs:${NC} $(mt_client_ip_count 2>/dev/null || echo 0)"
  echo

  local user found=0
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    found=1
    echo -e "${YELLOW}${user}:${NC} $(mt_build_link "$user" 2>/dev/null || true)"
  done < <(mt_list_users)
  ((found)) || echo "No proxy users configured."
  echo
  pause
}

mt_status_block() {
  mt_load_config
  local install_status service_status users link

  local proxy_users=0
  if mt_is_installed; then
    install_status="installed"
    service_status="$(mt_service_status)"
    users="$(mt_client_ip_count 2>/dev/null || echo 0)"
    proxy_users="$(mt_list_users | grep -c . || true)"
    if ((proxy_users == 1)); then
      link="$(mt_build_link 2>/dev/null || true)"
    else
      link="${proxy_users} users — see status/link"
    fi
  else
    install_status="not installed"
    service_status="-"
    users="0"
    link="-"
  fi

  # mtproto.zig by Aleksandr Kalashnikov (MIT), integrated by Nikitid
  echo -e "  ${CYAN}MTProto Proxy Manager by Nikitid${NC}"
  printf '%27b\n' "${WHITE}v${SCRIPT_VERSION}${NC}"
  echo

  status_line "Install status:" "$install_status"
  status_line "Service status:" "$service_status"
  status_line "Port:" "${MT_PORT:-}"
  status_line "TLS domain:" "${MT_TLS_DOMAIN:-}"
  status_line "Active IPs:" "$users"
  echo
  status_line "Link:" "$link"
  echo
}

# Menu keys stay in the same place regardless of service state: an entry
# that moves under the cursor is how an operator stops a proxy while meaning
# to update it. Removal sits on its own key, away from the routine actions.
mtproxy_menu() {
  local choice

  while true; do
    clear
    mt_status_block

    if ! mt_is_installed; then
      menu_item 1 "Install proxy"
      echo
      menu_enter_hint "Back"
      echo
      read_menu_choice choice

      case "$choice" in
        1) mt_install ;;
        "" | 0) return 0 ;;
        *) invalid_choice ;;
      esac
      continue
    fi

    if mt_service_is_running; then
      menu_item 1 "Restart proxy"
    else
      menu_item 1 "Start proxy"
    fi
    menu_item 2 "Stop proxy"
    menu_item 3 "Update proxy"
    echo
    menu_item 4 "Add user"
    menu_item 5 "Show active IPs"
    menu_item 6 "Show status/links"
    menu_item 7 "Show logs"
    echo
    menu_item 9 "Remove proxy"
    echo
    menu_enter_hint "Back"
    echo
    read_menu_choice choice

    case "$choice" in
      1) mt_restart_or_start_service ;;
      2) mt_stop ;;
      3) mt_update ;;
      4) mt_add_user ;;
      5) mt_show_active_ips ;;
      6) mt_show_status_link ;;
      7) mt_show_logs ;;
      9) mt_remove ;;
      "" | 0) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

show_client_info() {
  render_header
  cat <<EOF_INFO
Client parameters
-----------------
Server:        ${DOMAIN:-unset}
VPN type:      IKEv2
Auth method:   Username + password (EAP-MSCHAPv2)
IKE proposals: ${IKE_PROPOSALS}
ESP proposals: ${ESP_PROPOSALS}
Client DNS:    ${VPN_DNS}
Pool range:    ${VPN_POOL_RANGE}
IPv6 mode:     ${IPV6_MODE:-off}
Uplink iface:  ${UPLINK_IF:-unset}

Windows notes:
- VPN type: IKEv2
- Sign-in info: Username and password
- If Windows uses weak defaults, set IPsec policy explicitly to match this server.

Server cert layout:
- Leaf cert:   ${CERT_PATH}
- Issuer CA:   ${CA_PATH}
- Private key: ${KEY_PATH}
EOF_INFO
  pause
}

show_diagnostics() {
  render_header
  echo "Diagnostics"
  echo "-----------"
  echo "OS:           $(os_label)"
  echo "Topology:     $(detect_topology_hint)"
  echo "Service name: $(detect_service_name).service"
  echo "Service state: $(systemctl is-active "$(detect_service_name).service" 2>/dev/null || true)"
  echo "IPv4 forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  echo "Conntrack:    $(conntrack_status)"
  echo "ACME mode:    ${ACME_MODE:-dns-01}${DNS_PROVIDER:+ / ${DNS_PROVIDER}}"
  echo "Uplink iface: ${UPLINK_IF:-unset}"
  echo "Pool CIDR:    ${VPN_POOL_CIDR}"
  echo "Pool range:   ${VPN_POOL_RANGE}"
  echo "IPv6 mode:    ${IPV6_MODE:-off}"
  echo "Egress policy: ${EGRESS_POLICY:-internet-only}"
  echo "Host ports from pool: ${EGRESS_HOST_TCP_PORTS:-none} tcp / ${EGRESS_HOST_UDP_PORTS:-none} udp"
  echo "Cert key type: ${CERT_KEY_TYPE:-$DEFAULT_CERT_KEY_TYPE}"
  echo "IKE uniqueness: ${IKE_UNIQUE:-never}"
  echo "strongSwan:   $(strongswan_version || echo unknown)"
  if [[ "${IPV6_MODE:-off}" != "off" ]]; then
    echo "IPv6 pool:    ${VPN_POOL6_CIDR}"
    echo "IPv6 forward: $(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo '?')"
    echo "Global IPv6:  $(host_has_global_ipv6 && echo yes || echo no)"
  fi
  echo "Client DNS:   ${VPN_DNS}"
  echo
  echo "Kernel IPsec checks"
  echo "-------------------"
  echo "XFRM API:      $(ip xfrm state >/dev/null 2>&1 && echo yes || echo no)"
  echo "xfrm_stat:     $([[ -r /proc/net/xfrm_stat ]] && echo yes || echo no)"
  if command -v lsmod >/dev/null 2>&1; then
    echo "xfrm_user:     $(lsmod | awk '{print $1}' | grep -qx xfrm_user && echo loaded || echo missing)"
    echo "esp4:          $(lsmod | awk '{print $1}' | grep -qx esp4 && echo loaded || echo missing)"
    echo "esp6:          $(lsmod | awk '{print $1}' | grep -qx esp6 && echo loaded || echo missing)"
    echo "rfc4106/gcm:   $(lsmod | awk '{print $1}' | grep -Eq '^(rfc4106|gcm)$' && echo loaded || echo missing)"
  fi
  echo
  echo "Certificate summary"
  echo "-------------------"
  if [[ -f "$CERT_PATH" ]]; then
    openssl x509 -in "$CERT_PATH" -noout -subject -issuer -dates || true
    echo "Public Key Algorithm: $(cert_public_key_alg || true)"
    echo "Issuer CN:            $(cert_issuer_cn || echo unknown)"
    echo "Loaded CA chain files: $(ca_chain_file_count)"
  else
    echo "Certificate file missing: $CERT_PATH"
  fi
  echo
  echo "Firewall checks"
  echo "---------------"
  echo "NAT rule:      $(has_nat_rule && echo yes || echo no)"
  echo "Forward out:   $(has_forward_rule_out && echo yes || echo no)"
  echo "Forward in:    $(has_forward_rule_in && echo yes || echo no)"
  echo "MSS clamp:     $(has_mss_clamp_rule && echo yes || echo no)"
  echo "Isolation:     $(has_isolation_rule && echo yes || echo no) (configured: ${CLIENT_ISOLATION:-1})"
  echo "Hardening:     $(has_harden_chain && echo active || echo off) (configured: ${HARDEN_INPUT:-0})"
  echo "Egress chain:  $(has_egress_chain && echo active || echo off) (configured: ${EGRESS_POLICY:-internet-only})"
  echo "Host chain:    $(has_host_chain && echo active || echo off)"
  echo
  echo "Managed state"
  echo "-------------"
  local stale
  stale="$(stale_artifacts)"
  if [[ -n "$stale" ]]; then
    echo "Stale generated files (regenerated on next start):"
    print_indented "$stale"
  else
    echo "Generated files: current (v${SCRIPT_VERSION})"
  fi
  echo "Cert check timer: $(systemctl is-active ikev2-manager-certcheck.timer 2>/dev/null || echo inactive)"
  echo "Failed EAP auths (24h): $(failed_auth_count)"
  echo
  echo "Recent VPN log"
  echo "--------------"
  journalctl -u "$(detect_service_name).service" -n 30 --no-pager 2>/dev/null || true
  pause
}

reissue_certificate() {
  render_header
  echo "Reissue / reinstall certificate"
  echo "Mode: ${ACME_MODE:-dns-01}${DNS_PROVIDER:+ / ${DNS_PROVIDER}}"
  echo
  read -r -p "Continue? [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || return 0
  if ! issue_and_install_cert; then
    report_error "Certificate reissue failed."
    pause
    return 1
  fi
  save_config
  if ! reload_vpn_credentials; then
    report_error "VPN credentials reload failed after certificate update."
    pause
    return 1
  fi
  echo "Certificate reissued and installed."
  pause
}

reapply_firewall() {
  render_header
  if ! apply_firewall_rules; then
    report_error "Failed to reapply firewall rules."
    pause
    return 1
  fi
  echo "Firewall rules reapplied."
  pause
}

firewall_hardening_menu() {
  render_header
  echo "Inbound hardening / client isolation"
  echo "------------------------------------"
  echo "Hardening:      ${HARDEN_INPUT:-0} (1 = drop unlisted inbound traffic)"
  echo "Extra TCP:      ${HARDEN_TCP_PORTS:-none}"
  echo "Extra UDP:      ${HARDEN_UDP_PORTS:-none}"
  echo "Isolation:      ${CLIENT_ISOLATION:-1} (1 = drop client-to-client)"
  echo "Egress policy:  ${EGRESS_POLICY:-internet-only}"
  echo "Host TCP/UDP:   ${EGRESS_HOST_TCP_PORTS:-none} / ${EGRESS_HOST_UDP_PORTS:-none} (reachable from the tunnel)"
  echo
  echo "SSH, ICMP, IKEv2/ESP, DHCP, the MTProto proxy port and (in HTTP-01"
  echo "mode) TCP/80 for certificate renewal are always allowed."
  echo

  local harden tcp_ports udp_ports isolation egress
  harden=$(ask "Enable inbound hardening (1/0)" "${HARDEN_INPUT:-0}")
  [[ "$harden" == "0" || "$harden" == "1" ]] || {
    echo "Inbound hardening must be 0 or 1."
    pause
    return 1
  }
  tcp_ports="${HARDEN_TCP_PORTS:-}"
  udp_ports="${HARDEN_UDP_PORTS:-}"
  if [[ "$harden" == "1" ]]; then
    echo
    echo "Currently listening sockets (for reference):"
    ss -Hlntu 2>/dev/null | awk '{ print $1, $5 }' | sort -u | head -n 20 || true
    tcp_ports=$(ask "Extra allowed inbound TCP ports (comma-separated, empty for none)" "$tcp_ports")
    udp_ports=$(ask "Extra allowed inbound UDP ports (comma-separated, empty for none)" "$udp_ports")
    valid_port_list "$tcp_ports" || {
      echo "Extra TCP port list is invalid."
      pause
      return 1
    }
    valid_port_list "$udp_ports" || {
      echo "Extra UDP port list is invalid."
      pause
      return 1
    }
  fi
  isolation=$(ask "Drop VPN client-to-client traffic (1/0)" "${CLIENT_ISOLATION:-1}")
  [[ "$isolation" == "0" || "$isolation" == "1" ]] || {
    echo "Client isolation must be 0 or 1."
    pause
    return 1
  }

  echo
  echo "internet-only blocks cloud metadata, private networks and this host's"
  echo "own services for VPN clients; open routes everything."
  egress=$(ask "Egress policy (internet-only/open)" "${EGRESS_POLICY:-$DEFAULT_EGRESS_POLICY}")
  egress="${egress,,}"
  valid_egress_policy "$egress" || {
    echo "Egress policy must be internet-only or open."
    pause
    return 1
  }

  local host_tcp="${EGRESS_HOST_TCP_PORTS:-}" host_udp="${EGRESS_HOST_UDP_PORTS:-}"
  if [[ "$egress" == "internet-only" ]]; then
    host_tcp=$(ask "Host TCP ports reachable from VPN clients (empty for none)" "$host_tcp")
    host_udp=$(ask "Host UDP ports reachable from VPN clients (empty for none)" "$host_udp")
    valid_port_list "$host_tcp" || {
      echo "Host TCP port list is invalid."
      pause
      return 1
    }
    valid_port_list "$host_udp" || {
      echo "Host UDP port list is invalid."
      pause
      return 1
    }
  fi

  EGRESS_POLICY="$egress"
  EGRESS_HOST_TCP_PORTS=$(normalize_port_list "$host_tcp")
  EGRESS_HOST_UDP_PORTS=$(normalize_port_list "$host_udp")
  HARDEN_INPUT="$harden"
  HARDEN_TCP_PORTS=$(normalize_port_list "$tcp_ports")
  HARDEN_UDP_PORTS=$(normalize_port_list "$udp_ports")
  CLIENT_ISOLATION="$isolation"
  save_config

  if ! apply_firewall_rules; then
    report_error "Failed to apply firewall rules."
    pause
    return 1
  fi
  echo "Firewall rules applied."
  pause
}

start_vpn_service() {
  SERVICE_NAME="$(detect_service_name)"
  systemctl start "${SERVICE_NAME}.service"
}

stop_vpn_service() {
  SERVICE_NAME="$(detect_service_name)"
  systemctl stop "${SERVICE_NAME}.service"
}

restart_vpn_menu() {
  render_header
  if ! restart_vpn_service; then
    report_error "VPN service restart failed."
    pause
    return 1
  fi
  load_swanctl
  echo "VPN service restarted."
  pause
}

start_vpn_menu() {
  render_header
  if ! start_vpn_service; then
    report_error "VPN service start failed."
    pause
    return 1
  fi
  load_swanctl
  echo "VPN service started."
  pause
}

stop_vpn_menu() {
  render_header
  if ! stop_vpn_service; then
    report_error "VPN service stop failed."
    pause
    return 1
  fi
  echo "VPN service stopped."
  pause
}

show_recent_logs() {
  render_header
  journalctl -u "$(detect_service_name).service" -n 80 --no-pager 2>/dev/null || true
  pause
}

# Who is connected right now. The manager could terminate a user's sessions
# but never showed them.
show_active_sessions() {
  render_header
  echo "Active VPN sessions"
  echo "-------------------"
  if ! command -v swanctl >/dev/null 2>&1; then
    echo "swanctl is not available."
    pause
    return 0
  fi
  if ! service_active; then
    echo "VPN service is not running."
    pause
    return 0
  fi

  local output
  output="$(swanctl --list-sas --noblock 2>/dev/null || swanctl --list-sas 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    echo "No established IKE SAs."
  else
    printf '%s\n' "$output"
  fi
  echo
  echo "Failed EAP authentications in the last 24h: $(failed_auth_count)"
  pause
}

# Counts rejected EAP attempts in the journal; a spike means someone is
# guessing passwords.
failed_auth_count() {
  local service
  service="$(detect_service_name)"
  journalctl -u "${service}.service" --since "24 hours ago" --no-pager 2>/dev/null \
    | grep -c -E "EAP method EAP_MSCHAPV2 failed|authentication of .* failed|EAP_NAK" || true
}

vpn_users_menu() {
  local choice
  while true; do
    render_header
    echo "VPN users"
    echo "---------"
    menu_item 1 "Add or update VPN user"
    menu_item 2 "List VPN users"
    menu_item 3 "Remove VPN user"
    menu_item 4 "Generate client bundle locally"
    echo
    menu_enter_hint "Back"
    echo
    read_menu_choice choice
    case "$choice" in
      1) add_or_update_user ;;
      2) list_users_menu ;;
      3) remove_user_menu ;;
      4) generate_client_bundle_local ;;
      "" | 0) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

service_tools_menu() {
  local choice
  while true; do
    render_header
    echo "Service menu"
    echo "------------"
    menu_item 1 "Reissue certificate"
    menu_item 2 "Reapply firewall rules"
    menu_item 3 "Inbound hardening / client isolation / egress policy"
    echo
    menu_item 4 "Show diagnostics"
    menu_item 5 "Show active VPN sessions"
    menu_item 6 "Show logs"
    menu_item 7 "Show client info"
    echo
    menu_item 9 "Uninstall / cleanup"
    echo
    menu_enter_hint "Back"
    echo
    read_menu_choice choice
    case "$choice" in
      1) reissue_certificate ;;
      2) reapply_firewall ;;
      3) firewall_hardening_menu ;;
      4) show_diagnostics ;;
      5) show_active_sessions ;;
      6) show_recent_logs ;;
      7) show_client_info ;;
      9) uninstall_cleanup ;;
      "" | 0) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

# Anything this manager owns that is still on disk after a failed or partial
# installation. Without this the not-installed menu offered no way out of a
# half-configured host.
has_leftovers() {
  local path
  for path in "$MANAGER_DIR" "$SWANCTL_CONF" "$FIREWALL_SCRIPT" "$FIREWALL_SERVICE" \
    "$SYSCTL_FILE" "$MODULES_LOAD_FILE" "$CERT_CHECK_TIMER"; do
    [[ -e "$path" ]] && return 0
  done
  return 1
}

main_menu_not_installed() {
  local choice
  while true; do
    load_config
    if effective_installed; then
      return 0
    fi
    render_header
    menu_item 1 "Install IKEv2 server"
    echo
    menu_item 2 "MTProto proxy manager"
    menu_item 3 "Show diagnostics"
    if has_leftovers; then
      echo
      menu_item 9 "Uninstall / cleanup leftovers"
    fi
    echo
    menu_enter_hint "Exit"
    echo
    read_menu_choice choice
    case "$choice" in
      1) install_wizard ;;
      2) mtproxy_menu ;;
      3) show_diagnostics ;;
      9)
        if has_leftovers; then
          uninstall_cleanup
        else
          invalid_choice
        fi
        ;;
      "" | 0) exit 0 ;;
      *) invalid_choice ;;
    esac
  done
}

main_menu_installed() {
  local choice
  while true; do
    load_config
    if ! effective_installed; then
      return 0
    fi
    render_header

    if service_active; then
      menu_item 1 "Restart VPN service"
    else
      menu_item 1 "Start VPN service"
    fi
    menu_item 2 "Stop VPN service"
    menu_item 3 "Re-run install wizard"
    echo
    menu_item 4 "VPN users"
    menu_item 5 "MTProto proxy manager"
    menu_item 6 "Service menu"
    echo
    menu_enter_hint "Exit"
    echo
    read_menu_choice choice
    case "$choice" in
      1)
        if service_active; then
          restart_vpn_menu
        else
          start_vpn_menu
        fi
        ;;
      2) stop_vpn_menu ;;
      3) install_wizard ;;
      4) vpn_users_menu ;;
      5) mtproxy_menu ;;
      6) service_tools_menu ;;
      "" | 0) exit 0 ;;
      *) invalid_choice ;;
    esac
  done
}

usage() {
  cat <<EOF_USAGE
ikev2-manager ${SCRIPT_VERSION}

Usage: ikev2-manager.sh [command]

Without a command an interactive menu is started (requires a terminal).

Commands:
  --check        Report installation state and exit non-zero on a problem
  --reconcile    Regenerate managed files and reapply firewall/sysctl state
  --diagnostics  Print the full diagnostics report and exit
  --version      Print the version and exit
  --help         Print this help and exit

Supported: Ubuntu $(supported_os_list)
EOF_USAGE
}

# Non-interactive health report. Exits non-zero when something needs
# attention, so it can be used from cron or a monitoring check.
state_check() {
  local problems=0 days stale

  echo "ikev2-manager ${SCRIPT_VERSION}"
  echo "OS:            $(os_label)"
  if ! effective_installed; then
    echo "Install state: not installed"
    return 1
  fi
  echo "Install state: installed"
  echo "Domain:        ${DOMAIN:-unset}"
  echo "Service:       $(systemctl is-active "$(detect_service_name).service" 2>/dev/null || echo unknown)"
  service_active || problems=1

  if days="$(cert_days_left 2>/dev/null)"; then
    echo "Certificate:   ${days}d left"
    ((days <= 21)) && problems=1
  else
    echo "Certificate:   unreadable"
    problems=1
  fi

  echo "Users:         $(count_users)"
  echo "Conntrack:     $(conntrack_status)"
  echo "NAT rule:      $(has_nat_rule && echo yes || echo no)"
  has_nat_rule || problems=1
  echo "Forwarding:    $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"

  if [[ "${EGRESS_POLICY:-}" == "internet-only" ]] && ! has_egress_chain; then
    echo "Egress chain:  missing"
    problems=1
  fi

  stale="$(stale_artifacts)"
  if [[ -n "$stale" ]]; then
    echo "Stale files:"
    print_indented "$stale"
    problems=1
  fi

  return "$problems"
}

main() {
  case "${1:-}" in
    --version | -V)
      echo "ikev2-manager ${SCRIPT_VERSION}"
      return 0
      ;;
    --help | -h)
      usage
      return 0
      ;;
    --check)
      NONINTERACTIVE=1
      require_root
      load_config
      state_check
      return $?
      ;;
    --reconcile)
      NONINTERACTIVE=1
      require_root
      load_config
      if ! effective_installed; then
        echo "Not installed; nothing to reconcile."
        return 1
      fi
      reconcile_managed_state force
      state_check
      return $?
      ;;
    --diagnostics)
      NONINTERACTIVE=1
      require_root
      load_config
      show_diagnostics
      return 0
      ;;
    "") ;;
    *)
      echo "Unknown command: $1"
      usage
      return 1
      ;;
  esac

  require_root
  if [[ ! -t 0 ]]; then
    echo "This script needs a terminal for its menu."
    echo "Run it from an interactive shell, or use --check / --reconcile / --diagnostics."
    exit 1
  fi

  load_config
  migrate_config
  reconcile_managed_state

  while true; do
    load_config
    if effective_installed; then
      main_menu_installed
    else
      main_menu_not_installed
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
