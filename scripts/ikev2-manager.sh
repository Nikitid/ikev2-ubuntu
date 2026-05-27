#!/usr/bin/env bash
set -uo pipefail

SCRIPT_VERSION="1.0.1"
MANAGER_DIR="/opt/ikev2-manager"
CONFIG_FILE="$MANAGER_DIR/config.env"
ACME_ENV_FILE="$MANAGER_DIR/acme.env"
USERS_DB="$MANAGER_DIR/users.db"
EXPORTS_DIR="$MANAGER_DIR/exports"

# MTProxy manager paths
MT_SERVICE="mtproxy"
MT_INSTALL_DIR="/opt/MTProxy"
MT_STATE_DIR="/etc/mtproxy-manager"
MT_CONFIG_FILE="$MT_STATE_DIR/config"
MT_SECRET_FILE="$MT_STATE_DIR/secret"
MT_SERVICE_FILE="/etc/systemd/system/${MT_SERVICE}.service"
MT_SYSCTL_FILE="/etc/sysctl.d/99-mtproxy.conf"
MT_DEFAULT_PORT="443"
MT_DEFAULT_INTERNAL_PORT="8888"
MT_DEFAULT_TLS_DOMAIN="www.google.com"
MT_PID_MAX_LIMIT="65535"

# 3x-ui paths
XUI_SERVICE="x-ui"
XUI_DIR="/usr/local/x-ui"
XUI_INSTALL_CMD='bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)'

SWANCTL_CONF="/etc/swanctl/swanctl.conf"
SYSCTL_FILE="/etc/sysctl.d/99-ikev2-manager.conf"
FIREWALL_SCRIPT="$MANAGER_DIR/apply-firewall.sh"
FIREWALL_SERVICE="/etc/systemd/system/ikev2-manager-firewall.service"
ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
SERVICE_NAME=""
LAST_ERROR=""

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
DEFAULT_CERT_PATH="/etc/swanctl/x509/ikev2.pem"
DEFAULT_CA_PATH="/etc/swanctl/x509ca/issuer-ca.pem"
DEFAULT_KEY_PATH="/etc/swanctl/private/ikev2.key"
DEFAULT_POOL_RANGE="10.20.20.10-10.20.20.250"
DEFAULT_POOL_CIDR="10.20.20.0/24"
DEFAULT_DNS_FALLBACK="1.1.1.1,1.0.0.1"
DEFAULT_ACME_MODE="dns-01"
DEFAULT_DPD_DELAY="30s"
DEFAULT_IKE_PROPOSALS="aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048"
DEFAULT_ESP_PROPOSALS="aes256gcm16-ecp384,aes256-sha256"
DEFAULT_LOCAL_TS="0.0.0.0/0"

trap 'LAST_ERROR="Command failed on line $LINENO"' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
  fi
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
  KEY_PATH="${KEY_PATH:-$DEFAULT_KEY_PATH}"
  VPN_POOL_RANGE="${VPN_POOL_RANGE:-$DEFAULT_POOL_RANGE}"
  VPN_POOL_CIDR="${VPN_POOL_CIDR:-$DEFAULT_POOL_CIDR}"
  ACME_MODE="${ACME_MODE:-$DEFAULT_ACME_MODE}"
  VPN_DNS="${VPN_DNS:-$(detect_default_dns || true)}"
  VPN_DNS="${VPN_DNS:-$DEFAULT_DNS_FALLBACK}"
  DPD_DELAY="${DPD_DELAY:-$DEFAULT_DPD_DELAY}"
  IKE_PROPOSALS="${IKE_PROPOSALS:-$DEFAULT_IKE_PROPOSALS}"
  ESP_PROPOSALS="${ESP_PROPOSALS:-$DEFAULT_ESP_PROPOSALS}"
  LOCAL_TS="${LOCAL_TS:-$DEFAULT_LOCAL_TS}"
  UPLINK_IF="${UPLINK_IF:-$(detect_uplink_if || true)}"
  UPLINK_IF="${UPLINK_IF:-}"
  INSTALLED="${INSTALLED:-0}"
}

effective_installed() {
  [[ "${INSTALLED:-0}" == "1" && -f "$CONFIG_FILE" && -f "$SWANCTL_CONF" ]]
}

save_config() {
  mkdir -p "$MANAGER_DIR"
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
    printf 'VPN_DNS=%q\n' "${VPN_DNS:-}"
    printf 'UPLINK_IF=%q\n' "${UPLINK_IF:-}"
    printf 'DPD_DELAY=%q\n' "${DPD_DELAY:-}"
    printf 'IKE_PROPOSALS=%q\n' "${IKE_PROPOSALS:-}"
    printf 'ESP_PROPOSALS=%q\n' "${ESP_PROPOSALS:-}"
    printf 'LOCAL_TS=%q\n' "${LOCAL_TS:-}"
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

os_supported() {
  [[ -f /etc/os-release ]] || return 1
  local os_id version_id
  os_id=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
  version_id=$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
  [[ "$os_id" == "ubuntu" ]] || return 1
  [[ "$version_id" == "22.04" || "$version_id" == "24.04" ]]
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
    dns_list=$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '!seen[$0]++' | paste -sd, -)
  fi
  if [[ -z "$dns_list" ]]; then
    dns_list=$(awk '/^nameserver /{print $2}' /etc/resolv.conf 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | awk '!seen[$0]++' | paste -sd, -)
  fi
  echo "$dns_list"
}

normalize_dns_list() {
  local input="$1" out="" part
  input="${input// /}"
  input="${input//;/,}"
  while IFS=',' read -r -a __parts; do
    for part in "${__parts[@]}"; do
      if [[ "$part" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ -z "$out" ]]; then
          out="$part"
        else
          case ",$out," in
            *",$part,"*) ;;
            *) out+=",$part" ;;
          esac
        fi
      fi
    done
    break
  done <<<"$input"
  echo "$out"
}

valid_ipv4() {
  local ip="$1" IFS=.
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r o1 o2 o3 o4 <<<"$ip"
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$oct" =~ ^[0-9]+$ ]] || return 1
    ((oct >= 0 && oct <= 255)) || return 1
  done
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

infer_group_from_username() {
  local u="$1"
  u="${u%%-*}"
  [[ -n "$u" ]] && printf '%s\n' "$u" || printf 'default\n'
}

normalize_platform() {
  local p="${1,,}"
  case "$p" in
    win | windows | pc) echo "windows" ;;
    iphone | ios | ipad | phone) echo "ios" ;;
    mac | macos) echo "macos" ;;
    linux | ubuntu) echo "ubuntu" ;;
    "") echo "unknown" ;;
    *) echo "$p" ;;
  esac
}

escape_conf_value() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\'\\\'\'}"
  printf '%s' "$s"
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
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
  printf -v "$__var" '%s' "$__choice"
}

invalid_choice() {
  echo -e "${YELLOW}Invalid choice.${NC}"
  sleep 1
}

render_header() {
  clear
  load_config

  local install_state service_status cert_state users_state firewall_state auth_state quick_state topology_state os_state
  os_state="$(os_label)"
  topology_state="$(detect_topology_hint)"

  if effective_installed; then
    install_state="installed"
  else
    install_state="not installed"
  fi

  echo -e "${CYAN}Nikitid Network Manager${NC}"
  printf '%27b\n' "${WHITE}v${SCRIPT_VERSION}${NC}"
  echo

  if [[ "$install_state" != "installed" ]]; then
    status_line "Install status:" "$install_state"
    status_line "OS:" "$os_state"
    status_line "Topology hint:" "$topology_state"
    status_line "MTProxy:" "$(mt_service_status)"
    status_line "3x-ui:" "$(xui_status)"
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
  status_line "MTProxy:" "$(mt_service_status)"
  status_line "3x-ui:" "$(xui_status)"
  echo
  if [[ -n "$LAST_ERROR" ]]; then
    printf "${RED}Last error:${NC} %s\n\n" "$LAST_ERROR"
  fi
}
pause() {
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

ask_secret_multiline() {
  local prompt="$1"
  local line
  echo "$prompt"
  echo -e "${YELLOW}Enter KEY=VALUE lines. Empty line finishes input.${NC}"
  : >"$ACME_ENV_FILE"
  chmod 600 "$ACME_ENV_FILE"
  while true; do
    read -r -p "> " line || true
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

ask_secret_multiline_generic() {
  local line
  echo -e "${YELLOW}Enter KEY=VALUE lines. Empty line finishes input.${NC}"
  : >"$ACME_ENV_FILE"
  chmod 600 "$ACME_ENV_FILE"
  while true; do
    read -r -p "> " line || true
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
  mkdir -p "$MANAGER_DIR"
  : >"$ACME_ENV_FILE"
  chmod 600 "$ACME_ENV_FILE"

  case "$DNS_PROVIDER" in
    dns_timeweb)
      local token
      while true; do
        read -r -p "Timeweb Cloud JWT token: " token || true
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
  [[ -f "$target" ]] || return 0
  cp -a "$target" "${target}.bak.$(date +%Y%m%d-%H%M%S)"
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    curl \
    openssl \
    iproute2 \
    kmod \
    iptables \
    iptables-persistent \
    strongswan-swanctl \
    charon-systemd \
    strongswan-pki \
    libcharon-extra-plugins
}

ensure_acme_installed() {
  if [[ -x "$ACME_BIN" ]]; then
    return 0
  fi

  local installer="/tmp/acme-install.sh"
  curl -fsSL https://get.acme.sh -o "$installer"
  if [[ -n "${ACME_EMAIL:-}" ]]; then
    sh "$installer" email="$ACME_EMAIL"
  else
    sh "$installer"
  fi
  [[ -x "$ACME_BIN" ]]
}

write_firewall_script() {
  mkdir -p "$MANAGER_DIR"
  cat >"$FIREWALL_SCRIPT" <<EOF_FW
#!/usr/bin/env bash
set -Eeuo pipefail
POOL_CIDR='${VPN_POOL_CIDR}'
UPLINK_IF='${UPLINK_IF}'

# IKEv2 server ports. External NAT/security-group rules still have to allow UDP/500 and UDP/4500.
iptables -C INPUT -p udp --dport 500 -j ACCEPT >/dev/null 2>&1 || \
  iptables -I INPUT -p udp --dport 500 -j ACCEPT
iptables -C INPUT -p udp --dport 4500 -j ACCEPT >/dev/null 2>&1 || \
  iptables -I INPUT -p udp --dport 4500 -j ACCEPT

# Full-tunnel forwarding/NAT for VPN clients.
iptables -t nat -C POSTROUTING -s "\$POOL_CIDR" -o "\$UPLINK_IF" -j MASQUERADE >/dev/null 2>&1 || \
  iptables -t nat -I POSTROUTING -s "\$POOL_CIDR" -o "\$UPLINK_IF" -j MASQUERADE
iptables -C FORWARD -s "\$POOL_CIDR" -o "\$UPLINK_IF" -j ACCEPT >/dev/null 2>&1 || \
  iptables -I FORWARD -s "\$POOL_CIDR" -o "\$UPLINK_IF" -j ACCEPT
iptables -C FORWARD -d "\$POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "\$UPLINK_IF" -j ACCEPT >/dev/null 2>&1 || \
  iptables -I FORWARD -d "\$POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "\$UPLINK_IF" -j ACCEPT

if command -v iptables-save >/dev/null 2>&1; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 || true
fi
EOF_FW
  chmod 700 "$FIREWALL_SCRIPT"
}

write_firewall_service() {
  cat >"$FIREWALL_SERVICE" <<EOF_SVC
[Unit]
Description=IKEv2 Manager firewall rules
After=network-online.target
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
  while iptables -C INPUT -p udp --dport 500 -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p udp --dport 500 -j ACCEPT || break
  done
  while iptables -C INPUT -p udp --dport 4500 -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p udp --dport 4500 -j ACCEPT || break
  done

  if [[ -n "${UPLINK_IF:-}" ]]; then
    while iptables -t nat -C POSTROUTING -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j MASQUERADE >/dev/null 2>&1; do
      iptables -t nat -D POSTROUTING -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j MASQUERADE || break
    done
    while iptables -C FORWARD -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j ACCEPT >/dev/null 2>&1; do
      iptables -D FORWARD -s "$VPN_POOL_CIDR" -o "$UPLINK_IF" -j ACCEPT || break
    done
    while iptables -C FORWARD -d "$VPN_POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT >/dev/null 2>&1; do
      iptables -D FORWARD -d "$VPN_POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -i "$UPLINK_IF" -j ACCEPT || break
    done
  fi

  if [[ -f "$FIREWALL_SERVICE" ]]; then
    systemctl disable --now ikev2-manager-firewall.service >/dev/null 2>&1 || true
    rm -f "$FIREWALL_SERVICE"
    systemctl daemon-reload
  fi

  rm -f "$FIREWALL_SCRIPT"

  if command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save >/etc/iptables/rules.v4 || true
  fi
}

disable_sysctl() {
  rm -f "$SYSCTL_FILE"
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
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
  rm -f "${CERT_PATH}".bak.* "${CA_PATH}".bak.* "${KEY_PATH}".bak.* "${SWANCTL_CONF}".bak.* 2>/dev/null || true
  rm -f /etc/swanctl/conf.d/*.conf 2>/dev/null || true
  rmdir /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private /etc/swanctl/conf.d /etc/swanctl 2>/dev/null || true
}

purge_vpn_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y \
    strongswan-swanctl \
    charon-systemd \
    strongswan-pki \
    libcharon-extra-plugins \
    strongswan-libcharon \
    libcharon-extauth-plugins \
    libstrongswan-standard-plugins \
    libstrongswan >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
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
  echo "- purge strongSwan packages installed by this manager"
  echo "- reset IPv4 forwarding managed by this script"
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
  VPN_DNS="$DEFAULT_DNS_FALLBACK"
  UPLINK_IF="$(detect_uplink_if || true)"
  LAST_ERROR=""
  echo
  echo "IKEv2 manager setup removed."
  pause
}

ensure_kernel_ipsec_support() {
  local required_modules=(xfrm_user esp4)
  local optional_modules=(af_key ah4 xfrm4_tunnel rfc4106 gcm aes aesni_intel)
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

  if (( failed )); then
    echo "This kernel does not expose the IPsec/XFRM support required by strongSwan."
    echo "Use a distro/kernel with CONFIG_XFRM and ESP support enabled, or ask the VPS provider to enable IPsec."
    return 1
  fi
}

enable_sysctl() {
  cat >"$SYSCTL_FILE" <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -p "$SYSCTL_FILE" >/dev/null
}

escape_swanctl() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

generate_swanctl_conf() {
  migrate_users_db
  mkdir -p /etc/swanctl /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private
  backup_file "$SWANCTL_CONF"

  {
    cat <<EOF_HEAD
connections {
  ${CONN_NAME} {
    version = 2
    send_cert = always
    proposals = ${IKE_PROPOSALS}
    unique = never
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
        local_ts = ${LOCAL_TS}
        dpd_action = clear
        start_action = none
      }
    }

    pools = vpn_pool
  }
}

pools {
  vpn_pool {
    addrs = ${VPN_POOL_RANGE}
    dns = ${VPN_DNS}
  }
}

secrets {
EOF_HEAD

    if [[ -f "$USERS_DB" ]]; then
      local db_user db_pass db_group db_platform _db_rest esc_user esc_pass
      while IFS='|' read -r db_user db_pass db_group db_platform _db_rest; do
        [[ -z "${db_user// /}" || "$db_user" == "username" ]] && continue
        esc_user=$(escape_swanctl "$db_user")
        esc_pass=$(escape_swanctl "$db_pass")
        cat <<EOF_USER
  eap-${esc_user} {
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

issue_and_install_cert() {
  [[ -n "${DOMAIN:-}" ]] || {
    echo "Domain is not set."
    return 1
  }

  mkdir -p /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private
  backup_file "$CERT_PATH"
  backup_file "$CA_PATH"
  backup_file "$KEY_PATH"

  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null

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
      "$ACME_BIN" --issue -d "$DOMAIN" --dns "$DNS_PROVIDER" --keylength 2048
      ;;
    http-01)
      echo "Using HTTP-01 standalone mode."
      echo "The host must be reachable from the Internet on TCP/80 during validation."
      "$ACME_BIN" --issue -d "$DOMAIN" --standalone --keylength 2048
      ;;
    *)
      echo "Unsupported ACME mode: ${ACME_MODE}"
      return 1
      ;;
  esac

  "$ACME_BIN" --install-cert -d "$DOMAIN" \
    --cert-file "$CERT_PATH" \
    --ca-file "$CA_PATH" \
    --key-file "$KEY_PATH" \
    --reloadcmd "systemctl restart $(detect_service_name)"
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

  VPN_DNS=$(normalize_dns_list "$VPN_DNS")
  [[ -n "$VPN_DNS" ]] || {
    echo "VPN DNS is invalid. Use IPv4 addresses separated by commas."
    return 1
  }
}
install_wizard() {
  render_header
  echo -e "${WHITE}Install / reinstall IKEv2 fixed scenario${NC}"
  echo

  if ! os_supported; then
    echo "Unsupported OS. Official target: Ubuntu 22.04 / 24.04."
    pause
    return 1
  fi

  mkdir -p "$MANAGER_DIR"

  DOMAIN=$(ask "Domain name for VPN server" "${DOMAIN:-}")
  ACME_EMAIL=$(ask "Email for acme.sh (optional)" "${ACME_EMAIL:-}")
  ACME_MODE=$(ask "ACME validation mode (dns-01/http-01)" "${ACME_MODE:-dns-01}")
  ACME_MODE="${ACME_MODE,,}"

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
    echo "Package installation failed."
    pause
    return 1
  fi

  echo "Installing acme.sh..."
  if ! ensure_acme_installed; then
    echo "acme.sh installation failed."
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
    echo "Failed to enable IPv4 forwarding."
    pause
    return 1
  fi

  echo "Issuing and installing RSA certificate..."
  if ! issue_and_install_cert; then
    echo "Certificate issuance or installation failed."
    pause
    return 1
  fi

  echo "Generating swanctl configuration..."
  if ! generate_swanctl_conf; then
    echo "Failed to generate swanctl configuration."
    pause
    return 1
  fi

  echo "Validating swanctl configuration..."
  systemctl start "$(detect_service_name).service" >/dev/null 2>&1 || true
  if ! swanctl --load-all >/dev/null 2>&1; then
    echo "Generated swanctl configuration is invalid. Inspect /etc/swanctl/swanctl.conf and retry."
    INSTALLED=0
    save_config
    pause
    return 1
  fi

  echo "Starting VPN service..."
  if ! restart_vpn_service; then
    echo "Failed to start VPN service."
    pause
    return 1
  fi
  load_swanctl

  echo "Applying firewall rules..."
  if ! apply_firewall_rules; then
    echo "Failed to apply firewall rules."
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
  mkdir -p "$MANAGER_DIR"
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
    password=$(ask "Password")
    if [[ -z "$password" || "$password" == *'|'* || "$password" == *$'\t'* || "$password" == *$'\n'* ]]; then
      echo "Password is empty or contains invalid characters."
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
  if ! swanctl --load-all >/dev/null 2>&1; then
    echo "Generated swanctl configuration is invalid. User database was updated, but VPN config reload was blocked."
    pause
    return 1
  fi
  if ! restart_vpn_service; then
    echo "VPN service reload failed after user update."
    pause
    return 1
  fi
  load_swanctl

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
  if ! swanctl --load-all >/dev/null 2>&1; then
    echo "Generated swanctl configuration is invalid. User database was updated, but VPN config reload was blocked."
    pause
    return 1
  fi
  if ! restart_vpn_service; then
    echo "VPN service reload failed after user removal."
    pause
    return 1
  fi
  load_swanctl

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

list_groups() {
  ensure_users_db
  awk -F'|' 'NF && $1 !~ /^[[:space:]]*$/ && $1 != "username" {g=($3?$3:$1); sub(/-.*/,"",g); print g}' "$USERS_DB" | sort -u
}

select_group_prompt() {
  ensure_users_db
  local -a groups=()
  local line input

  while IFS= read -r line; do
    [[ -n "$line" ]] && groups+=("$line")
  done < <(list_groups)

  if ((${#groups[@]} == 0)); then
    echo "No groups found."
    return 1
  fi

  echo "Available groups"
  echo "----------------"
  local i
  for i in "${!groups[@]}"; do
    printf "%2d) %s\n" "$((i + 1))" "${groups[$i]}"
  done
  echo

  input=$(ask "Group/label to export (number or name)")
  input="$(trim "$input")"

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    if ((input >= 1 && input <= ${#groups[@]})); then
      printf '%s\n' "${groups[$((input - 1))]}"
      return 0
    fi
    echo "Group number out of range: $input"
    return 1
  fi

  if ! valid_group_name "$input"; then
    echo "Invalid group."
    return 1
  fi

  for line in "${groups[@]}"; do
    if [[ "$line" == "$input" ]]; then
      printf '%s\n' "$input"
      return 0
    fi
  done

  echo "Group not found: $input"
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
  cat >"$out_file" <<EOF_UBUNTU
#!/usr/bin/env bash
set -euo pipefail
read -r -p "Username: " VPN_USER
read -r -s -p "Password: " VPN_PASS
echo
sudo apt-get update
sudo apt-get install -y strongswan libcharon-extra-plugins libcharon-extauth-plugins
sudo tee /etc/ipsec.conf >/dev/null <<EOF
conn ikev2
    keyexchange=ikev2
    right=${host}
    rightid=@${host}
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

  local ts bundle_dir user _pass _g _platform file safe_user
  ts=$(date +%Y%m%d-%H%M%S)
  bundle_dir="$EXPORTS_DIR/${DOMAIN}_${group}_${ts}"
  mkdir -p "$bundle_dir/windows" "$bundle_dir/ios" "$bundle_dir/macos" "$bundle_dir/ubuntu"

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

  echo "Client bundle exported locally:"
  echo "$bundle_dir"
  echo
  find "$bundle_dir" -maxdepth 2 -type f | sort
  pause
}

# ------------------------- MTProxy manager -------------------------
mt_init_dirs() {
  mkdir -p "$MT_STATE_DIR"
  chmod 700 "$MT_STATE_DIR"
}

mt_is_installed() {
  [[ -d "$MT_INSTALL_DIR" && -f "$MT_SERVICE_FILE" ]]
}

mt_require_installed() {
  if ! mt_is_installed; then
    echo -e "${RED}MTProxy is not installed${NC}"
    sleep 2
    return 1
  fi
}

mt_load_from_service() {
  local exec_line parsed_mt_port parsed_internal_port parsed_tls_domain
  [[ -f "$MT_SERVICE_FILE" ]] || return 0

  exec_line="$(sed -n 's/^ExecStart=//p' "$MT_SERVICE_FILE" | head -n1)"
  [[ -n "$exec_line" ]] || return 0

  parsed_mt_port="$(sed -n 's/.* -H \([0-9]\+\)\>.*/\1/p' <<<"$exec_line" | head -n1)"
  parsed_internal_port="$(sed -n 's/.* -p \([0-9]\+\)\>.*/\1/p' <<<"$exec_line" | head -n1)"
  parsed_tls_domain="$(sed -n 's/.* -D \([^ ]\+\)\>.*/\1/p' <<<"$exec_line" | head -n1)"

  [[ -n "$parsed_mt_port" ]] && MT_PORT="$parsed_mt_port"
  [[ -n "$parsed_internal_port" ]] && MT_INTERNAL_PORT="$parsed_internal_port"
  [[ -n "$parsed_tls_domain" ]] && MT_TLS_DOMAIN="$parsed_tls_domain"
}

mt_load_config() {
  MT_PORT="$MT_DEFAULT_PORT"
  MT_INTERNAL_PORT="$MT_DEFAULT_INTERNAL_PORT"
  MT_TLS_DOMAIN="$MT_DEFAULT_TLS_DOMAIN"
  MT_SECRET=""

  if [[ -f "$MT_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MT_CONFIG_FILE"
  else
    mt_load_from_service
  fi

  if [[ -f "$MT_SECRET_FILE" ]]; then
    MT_SECRET="$(tr -d '\r\n' <"$MT_SECRET_FILE")"
  fi
}

mt_save_config() {
  mt_init_dirs
  cat >"$MT_CONFIG_FILE" <<EOF_MTCONF
MT_PORT="$MT_PORT"
MT_INTERNAL_PORT="$MT_INTERNAL_PORT"
MT_TLS_DOMAIN="$MT_TLS_DOMAIN"
EOF_MTCONF
  chmod 600 "$MT_CONFIG_FILE"
}

mt_generate_secret() {
  head -c 16 /dev/urandom | xxd -ps | tr -d '\n'
}

mt_download_file() {
  local url="$1" output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output"
  else
    echo -e "${RED}Neither curl nor wget is available${NC}"
    return 1
  fi
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
  mt_load_config
  local ip domain_hex

  ip="$(mt_get_server_ip 2>/dev/null || true)"
  ip="${ip:-YOUR_IP}"

  domain_hex="$(printf '%s' "$MT_TLS_DOMAIN" | xxd -ps -c 999 | tr -d '\n')"
  printf 'tg://proxy?server=%s&port=%s&secret=ee%s%s\n' "$ip" "$MT_PORT" "$MT_SECRET" "$domain_hex"
}

mt_check_tls_domain() {
  local domain="$1" tmp

  tmp="$(mktemp)"

  if timeout 8 openssl s_client \
    -connect "${domain}:443" \
    -servername "$domain" \
    -verify_hostname "$domain" \
    -verify_return_error \
    </dev/null >"$tmp" 2>&1; then
    if grep -q "Verify return code: 0 (ok)" "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  fi

  rm -f "$tmp"
  return 1
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

mt_check_required_commands() {
  local missing=()

  for cmd in git make openssl timeout ss iptables systemctl xxd ip curl awk sed grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    echo -e "${RED}Missing required commands:${NC} ${missing[*]}"
    return 1
  fi
}

mt_configure_pid_max() {
  local current
  current="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 0)"

  if [[ ! "$current" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if ((current > MT_PID_MAX_LIMIT)); then
    printf 'kernel.pid_max=%s\n' "$MT_PID_MAX_LIMIT" >"$MT_SYSCTL_FILE"
    sysctl -q -p "$MT_SYSCTL_FILE" || true
  fi
}

mt_show_pid_max_warning_if_needed() {
  local current
  current="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 0)"

  if [[ "$current" =~ ^[0-9]+$ ]] && ((current > MT_PID_MAX_LIMIT)); then
    echo -e "${YELLOW}Warning:${NC} kernel.pid_max=${current}. MTProxy may crash with PID > ${MT_PID_MAX_LIMIT}."
    echo -e "${YELLOW}Recommended fix:${NC} set kernel.pid_max=${MT_PID_MAX_LIMIT}"
    echo
  fi
}

mt_write_service() {
  cat >"$MT_SERVICE_FILE" <<EOF_MTSVC
[Unit]
Description=MTProto Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${MT_INSTALL_DIR}
ExecStartPre=/usr/bin/test -x ${MT_INSTALL_DIR}/objs/bin/mtproto-proxy
ExecStartPre=/usr/bin/test -f ${MT_INSTALL_DIR}/proxy-secret
ExecStartPre=/usr/bin/test -f ${MT_INSTALL_DIR}/proxy-multi.conf
ExecStart=${MT_INSTALL_DIR}/objs/bin/mtproto-proxy -u nobody -p ${MT_INTERNAL_PORT} -H ${MT_PORT} -S ${MT_SECRET} -D ${MT_TLS_DOMAIN} --aes-pwd ${MT_INSTALL_DIR}/proxy-secret ${MT_INSTALL_DIR}/proxy-multi.conf --max-accept-rate 1000 --max-dh-accept-rate 500 --msg-buffers-size 134217728 --http-stats
Restart=always
RestartSec=3
TimeoutStopSec=5
TimeoutStartSec=20
LimitNOFILE=100000
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
PrivateDevices=true
ProtectControlGroups=true
ProtectKernelTunables=true

[Install]
WantedBy=multi-user.target
EOF_MTSVC
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
      ((stable++))
      if ((stable >= 3)); then
        return 0
      fi
    elif [[ "$active_state" == "failed" || "$sub_state" == "failed" ]]; then
      break
    else
      stable=0
    fi

    sleep 1
    ((attempts--))
  done

  echo -e "${RED}MTProxy service failed to start${NC}"
  echo
  systemctl --no-pager --full status "${MT_SERVICE}.service" || true
  echo
  journalctl -u "${MT_SERVICE}.service" -n 30 --no-pager || true
  echo
  mt_show_pid_max_warning_if_needed
  return 1
}

mt_firewall_add() {
  iptables -C INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

mt_firewall_remove() {
  mt_load_config

  while iptables -C INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT || break
  done

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

mt_prompt_install_settings() {
  local input_mt_port input_internal_port input_tls_domain

  read -r -p "Client port [${MT_DEFAULT_PORT}]: " input_mt_port
  read -r -p "Internal port [${MT_DEFAULT_INTERNAL_PORT}]: " input_internal_port
  read -r -p "TLS domain [${MT_DEFAULT_TLS_DOMAIN}]: " input_tls_domain

  MT_PORT="${input_mt_port:-$MT_DEFAULT_PORT}"
  MT_INTERNAL_PORT="${input_internal_port:-$MT_DEFAULT_INTERNAL_PORT}"
  MT_TLS_DOMAIN="${input_tls_domain:-$MT_DEFAULT_TLS_DOMAIN}"

  if ! mt_validate_port "$MT_PORT"; then
    echo -e "${RED}Invalid client port${NC}"
    return 1
  fi

  if ! mt_validate_port "$MT_INTERNAL_PORT"; then
    echo -e "${RED}Invalid internal port${NC}"
    return 1
  fi

  if [[ "$MT_PORT" == "$MT_INTERNAL_PORT" ]]; then
    echo -e "${RED}Client port and internal port must be different${NC}"
    return 1
  fi

  if ! valid_domain_name "$MT_TLS_DOMAIN"; then
    echo -e "${RED}Invalid TLS domain${NC}"
    return 1
  fi

  if mt_port_in_use "$MT_PORT" && ! mt_is_installed; then
    echo -e "${RED}Client port ${MT_PORT} is already in use${NC}"
    return 1
  fi

  if mt_port_in_use "$MT_INTERNAL_PORT" && ! mt_is_installed; then
    echo -e "${RED}Internal port ${MT_INTERNAL_PORT} is already in use${NC}"
    return 1
  fi

  echo -e "${WHITE}Checking TLS domain...${NC}"
  if ! mt_check_tls_domain "$MT_TLS_DOMAIN"; then
    echo -e "${RED}Invalid TLS domain or certificate chain verification failed${NC}"
    return 1
  fi
}

mt_install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    git curl wget build-essential libssl-dev zlib1g-dev \
    ca-certificates openssl xxd iptables iptables-persistent iproute2
}

mt_install() {
  render_header
  echo -e "${CYAN}Installing MTProxy...${NC}"
  echo

  mt_load_config
  mt_prompt_install_settings || {
    sleep 2
    return 1
  }

  mt_install_packages
  mt_check_required_commands || {
    sleep 2
    return 1
  }
  mt_configure_pid_max

  rm -rf "$MT_INSTALL_DIR"
  git clone --depth 1 https://github.com/TelegramMessenger/MTProxy "$MT_INSTALL_DIR"
  make -C "$MT_INSTALL_DIR"

  if [[ ! -x "${MT_INSTALL_DIR}/objs/bin/mtproto-proxy" ]]; then
    echo -e "${RED}Build failed: mtproto-proxy binary not found${NC}"
    sleep 2
    return 1
  fi

  mt_download_file "https://core.telegram.org/getProxySecret" "${MT_INSTALL_DIR}/proxy-secret"
  mt_download_file "https://core.telegram.org/getProxyConfig" "${MT_INSTALL_DIR}/proxy-multi.conf"

  mt_init_dirs
  MT_SECRET="$(mt_generate_secret)"
  printf '%s\n' "$MT_SECRET" >"$MT_SECRET_FILE"
  chmod 600 "$MT_SECRET_FILE"

  mt_save_config
  mt_write_service
  mt_firewall_add

  systemctl daemon-reload
  systemctl enable "${MT_SERVICE}.service" >/dev/null 2>&1
  systemctl restart "${MT_SERVICE}.service"

  if mt_verify_service_started; then
    echo
    echo -e "${GREEN}MTProxy installed successfully${NC}"
    echo -e "${YELLOW}Link:${NC} $(mt_build_link)"
    echo
  fi

  pause
}

mt_remove() {
  render_header
  mt_require_installed || return 1
  mt_load_config

  read -r -p "Remove MTProxy? Type DELETE: " ans || true
  [[ "$ans" == "DELETE" ]] || return 0

  systemctl stop "${MT_SERVICE}.service" 2>/dev/null || true
  systemctl disable "${MT_SERVICE}.service" 2>/dev/null || true
  rm -f "$MT_SERVICE_FILE"

  if [[ -n "${MT_PORT:-}" ]]; then
    mt_firewall_remove
  fi

  rm -rf "$MT_INSTALL_DIR" "$MT_STATE_DIR"
  systemctl daemon-reload

  echo -e "${GREEN}MTProxy removed${NC}"
  sleep 2
}

mt_restart_or_start_service() {
  render_header
  mt_require_installed || return 1
  mt_check_required_commands || {
    sleep 2
    return 1
  }
  mt_configure_pid_max

  if mt_service_is_running; then
    systemctl restart "${MT_SERVICE}.service"
  else
    systemctl start "${MT_SERVICE}.service"
  fi

  if mt_verify_service_started; then
    echo -e "${GREEN}MTProxy service is running${NC}"
  fi

  sleep 2
}

mt_stop() {
  render_header
  mt_require_installed || return 1

  if mt_service_is_running; then
    systemctl stop "${MT_SERVICE}.service"
    echo -e "${GREEN}MTProxy stopped${NC}"
  else
    echo -e "${YELLOW}MTProxy is already stopped${NC}"
  fi

  sleep 2
}

mt_update() {
  render_header
  mt_require_installed || return 1
  mt_check_required_commands || {
    sleep 2
    return 1
  }
  mt_load_config
  mt_configure_pid_max

  git -C "$MT_INSTALL_DIR" pull --ff-only
  make -C "$MT_INSTALL_DIR"

  if [[ ! -x "${MT_INSTALL_DIR}/objs/bin/mtproto-proxy" ]]; then
    echo -e "${RED}Build failed: mtproto-proxy binary not found${NC}"
    sleep 2
    return 1
  fi

  mt_download_file "https://core.telegram.org/getProxySecret" "${MT_INSTALL_DIR}/proxy-secret"
  mt_download_file "https://core.telegram.org/getProxyConfig" "${MT_INSTALL_DIR}/proxy-multi.conf"

  systemctl restart "${MT_SERVICE}.service"

  if mt_verify_service_started; then
    echo -e "${GREEN}MTProxy updated successfully${NC}"
  fi

  sleep 2
}

mt_change_secret() {
  render_header
  mt_require_installed || return 1
  mt_load_config

  menu_item 1 "Generate new secret"
  menu_item 2 "Enter secret manually"
  echo
  menu_enter_hint "Back"
  echo
  read_menu_choice choice

  case "$choice" in
    1)
      MT_SECRET="$(mt_generate_secret)"
      ;;
    2)
      read -r -p "Enter 32-char hex secret: " MT_SECRET
      if [[ ! "$MT_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo -e "${RED}Invalid secret${NC}"
        sleep 2
        return 1
      fi
      MT_SECRET="${MT_SECRET,,}"
      ;;
    "" | 0)
      return 0
      ;;
    *)
      invalid_choice
      return 1
      ;;
  esac

  printf '%s\n' "$MT_SECRET" >"$MT_SECRET_FILE"
  chmod 600 "$MT_SECRET_FILE"

  mt_write_service
  systemctl daemon-reload
  systemctl restart "${MT_SERVICE}.service"

  if mt_verify_service_started; then
    echo -e "${GREEN}MTProxy secret updated${NC}"
    echo -e "${YELLOW}Link:${NC} $(mt_build_link)"
  fi

  sleep 2
}

mt_change_tls_domain() {
  render_header
  mt_require_installed || return 1
  mt_load_config

  read -r -p "Enter TLS domain [${MT_TLS_DOMAIN}]: " new_domain
  new_domain="${new_domain:-$MT_TLS_DOMAIN}"

  if ! valid_domain_name "$new_domain"; then
    echo -e "${RED}Invalid TLS domain${NC}"
    sleep 2
    return 1
  fi

  echo -e "${WHITE}Checking TLS domain...${NC}"
  if mt_check_tls_domain "$new_domain"; then
    MT_TLS_DOMAIN="$new_domain"
    mt_save_config
    mt_write_service
    systemctl daemon-reload
    systemctl restart "${MT_SERVICE}.service"

    if mt_verify_service_started; then
      echo -e "${GREEN}MTProxy TLS domain updated${NC}"
      echo -e "${YELLOW}Link:${NC} $(mt_build_link)"
    fi
  else
    echo -e "${RED}Invalid TLS domain or certificate chain verification failed${NC}"
  fi

  sleep 2
}

mt_client_ips_raw() {
  mt_load_config
  ss -Htn state established "( sport = :${MT_PORT} )" 2>/dev/null \
    | awk '{print $4}' \
    | cut -d: -f1 \
    | sed '/^$/d'
}

mt_client_ip_count() {
  mt_client_ips_raw | sort -u | wc -l
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
  echo -e "${YELLOW}Stats:${NC}"
  curl -fsS "http://127.0.0.1:${MT_INTERNAL_PORT}/stats" | sed -n '1,20p' || echo "Stats unavailable"

  echo
  pause
}

mt_show_logs() {
  render_header
  mt_require_installed || return 1
  journalctl -u "${MT_SERVICE}.service" -b -n 50 --no-pager || true
  echo
  mt_show_pid_max_warning_if_needed
  pause
}

mt_show_status_link() {
  render_header
  mt_load_config
  echo -e "${YELLOW}MTProxy status:${NC} $(mt_service_status)"
  echo -e "${YELLOW}Port:${NC} ${MT_PORT}"
  echo -e "${YELLOW}Internal port:${NC} ${MT_INTERNAL_PORT}"
  echo -e "${YELLOW}TLS domain:${NC} ${MT_TLS_DOMAIN}"
  echo -e "${YELLOW}Active IPs:${NC} $(mt_client_ip_count 2>/dev/null || echo 0)"
  echo
  echo -e "${YELLOW}Link:${NC} $(mt_build_link 2>/dev/null || true)"
  echo
  pause
}

mt_status_block() {
  mt_load_config
  local install_status service_status users link

  if mt_is_installed; then
    install_status="installed"
    service_status="$(mt_service_status)"
    users="$(mt_client_ip_count 2>/dev/null || echo 0)"
    link="$(mt_build_link 2>/dev/null || true)"
  else
    install_status="not installed"
    service_status="-"
    users="0"
    link="-"
  fi

  echo -e "  ${CYAN}MTProxy Manager by Nikitid${NC}"
  printf '%27b\n' "${WHITE}v1.2-integrated${NC}"
  echo

  status_line "Install status:" "$install_status"
  status_line "Service status:" "$service_status"
  status_line "Port:" "${MT_PORT:-}"
  status_line "Internal port:" "${MT_INTERNAL_PORT:-}"
  status_line "TLS domain:" "${MT_TLS_DOMAIN:-}"
  status_line "Active IPs:" "$users"
  echo
  status_line "Link:" "$link"
  echo
}

mtproxy_menu() {
  local choice

  while true; do
    clear
    mt_status_block

    if mt_is_installed; then
      if mt_service_is_running; then
        menu_item 1 "Remove proxy"
        menu_item 2 "Restart proxy"
        menu_item 3 "Stop proxy"
        menu_item 4 "Update proxy"
        menu_item 5 "Change secret"
        menu_item 6 "Change TLS domain"
        menu_item 7 "Show active IPs"
        menu_item 8 "Show status/link"
        menu_item 9 "Show logs"
        echo
        menu_enter_hint "Back"
        echo
        read_menu_choice choice

        case "$choice" in
          1) mt_remove ;;
          2) mt_restart_or_start_service ;;
          3) mt_stop ;;
          4) mt_update ;;
          5) mt_change_secret ;;
          6) mt_change_tls_domain ;;
          7) mt_show_active_ips ;;
          8) mt_show_status_link ;;
          9) mt_show_logs ;;
          "" | 0) return 0 ;;
          *) invalid_choice ;;
        esac
      else
        menu_item 1 "Remove proxy"
        menu_item 2 "Start proxy"
        menu_item 3 "Update proxy"
        menu_item 4 "Change secret"
        menu_item 5 "Change TLS domain"
        menu_item 6 "Show active IPs"
        menu_item 7 "Show status/link"
        menu_item 8 "Show logs"
        echo
        menu_enter_hint "Back"
        echo
        read_menu_choice choice

        case "$choice" in
          1) mt_remove ;;
          2) mt_restart_or_start_service ;;
          3) mt_update ;;
          4) mt_change_secret ;;
          5) mt_change_tls_domain ;;
          6) mt_show_active_ips ;;
          7) mt_show_status_link ;;
          8) mt_show_logs ;;
          "" | 0) return 0 ;;
          *) invalid_choice ;;
        esac
      fi
    else
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
    fi
  done
}

# ------------------------- 3x-ui manager -------------------------
xui_is_installed() { command -v x-ui >/dev/null 2>&1 || [[ -x "$XUI_DIR/x-ui" || -f /etc/systemd/system/x-ui.service || -f /usr/lib/systemd/system/x-ui.service ]]; }
xui_status() {
  if ! xui_is_installed; then
    echo "not-installed"
    return 0
  fi
  local a s
  a=$(systemctl show -p ActiveState --value "${XUI_SERVICE}.service" 2>/dev/null || true)
  s=$(systemctl show -p SubState --value "${XUI_SERVICE}.service" 2>/dev/null || true)
  [[ -n "$a" ]] && echo "${a}${s:+/$s}" || echo "unknown"
}
xui_install() {
  render_header
  echo "This will run official 3x-ui installer from MHSanaei/3x-ui."
  echo "Command: $XUI_INSTALL_CMD"
  echo
  read -r -p "Continue? [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || return 0
  apt-get update
  apt-get install -y curl ca-certificates
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  echo
  echo "3x-ui status: $(xui_status)"
  pause
}
xui_info() {
  render_header
  if ! xui_is_installed; then
    echo "3x-ui is not installed."
    pause
    return 0
  fi
  echo "3x-ui status: $(xui_status)"
  echo
  if command -v x-ui >/dev/null 2>&1; then
    x-ui status 2>/dev/null || true
    echo
    x-ui settings 2>/dev/null || true
  elif [[ -x "$XUI_DIR/x-ui" ]]; then
    "$XUI_DIR/x-ui" status 2>/dev/null || true
    echo
    "$XUI_DIR/x-ui" settings 2>/dev/null || true
  fi
  echo
  journalctl -u x-ui -n 40 --no-pager 2>/dev/null || true
  pause
}
xui_restart() {
  render_header
  if ! xui_is_installed; then
    echo "3x-ui is not installed."
    pause
    return 0
  fi
  systemctl restart x-ui
  echo "3x-ui restarted."
  pause
}
xui_menu() {
  local choice
  while true; do
    render_header
    echo "3x-ui"
    echo "-----"

    if ! xui_is_installed; then
      menu_item 1 "Install 3x-ui"
      echo
      menu_enter_hint "Back"
      echo
      read_menu_choice choice
      case "$choice" in
        1) xui_install ;;
        "" | 0) return 0 ;;
        *) invalid_choice ;;
      esac
    else
      menu_item 1 "Show 3x-ui status/settings/logs"
      menu_item 2 "Restart 3x-ui"
      menu_item 3 "Reinstall 3x-ui"
      echo
      menu_enter_hint "Back"
      echo
      read_menu_choice choice
      case "$choice" in
        1) xui_info ;;
        2) xui_restart ;;
        3) xui_install ;;
        "" | 0) return 0 ;;
        *) invalid_choice ;;
      esac
    fi
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
  echo "ACME mode:    ${ACME_MODE:-dns-01}${DNS_PROVIDER:+ / ${DNS_PROVIDER}}"
  echo "Uplink iface: ${UPLINK_IF:-unset}"
  echo "Pool CIDR:    ${VPN_POOL_CIDR}"
  echo "Pool range:   ${VPN_POOL_RANGE}"
  echo "Client DNS:   ${VPN_DNS}"
  echo
  echo "Kernel IPsec checks"
  echo "-------------------"
  echo "XFRM API:      $(ip xfrm state >/dev/null 2>&1 && echo yes || echo no)"
  echo "xfrm_stat:     $([[ -r /proc/net/xfrm_stat ]] && echo yes || echo no)"
  if command -v lsmod >/dev/null 2>&1; then
    echo "xfrm_user:     $(lsmod | awk '{print $1}' | grep -qx xfrm_user && echo loaded || echo missing)"
    echo "esp4:          $(lsmod | awk '{print $1}' | grep -qx esp4 && echo loaded || echo missing)"
    echo "rfc4106/gcm:   $(lsmod | awk '{print $1}' | grep -Eq '^(rfc4106|gcm)$' && echo loaded || echo missing)"
  fi
  echo
  echo "Certificate summary"
  echo "-------------------"
  if [[ -f "$CERT_PATH" ]]; then
    openssl x509 -in "$CERT_PATH" -noout -subject -issuer -dates || true
    echo "Public Key Algorithm: $(cert_public_key_alg || true)"
  else
    echo "Certificate file missing: $CERT_PATH"
  fi
  echo
  echo "Firewall checks"
  echo "---------------"
  echo "NAT rule:      $(has_nat_rule && echo yes || echo no)"
  echo "Forward out:   $(has_forward_rule_out && echo yes || echo no)"
  echo "Forward in:    $(has_forward_rule_in && echo yes || echo no)"
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
    echo "Certificate reissue failed."
    pause
    return 1
  fi
  if ! restart_vpn_service; then
    echo "VPN service restart failed after certificate update."
    pause
    return 1
  fi
  load_swanctl
  echo "Certificate reissued and installed."
  pause
}

reapply_firewall() {
  render_header
  if ! apply_firewall_rules; then
    echo "Failed to reapply firewall rules."
    pause
    return 1
  fi
  echo "Firewall rules reapplied."
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
    echo "VPN service restart failed."
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
    echo "VPN service start failed."
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
    echo "VPN service stop failed."
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
    menu_item 3 "Show diagnostics"
    menu_item 4 "Show logs"
    menu_item 5 "Show client info"
    menu_item 6 "Uninstall / cleanup"
    echo
    menu_enter_hint "Back"
    echo
    read_menu_choice choice
    case "$choice" in
      1) reissue_certificate ;;
      2) reapply_firewall ;;
      3) show_diagnostics ;;
      4) show_recent_logs ;;
      5) show_client_info ;;
      6) uninstall_cleanup ;;
      "" | 0) return 0 ;;
      *) invalid_choice ;;
    esac
  done
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
    menu_item 2 "MTProxy manager"
    menu_item 3 "3x-ui manager"
    echo
    menu_item 4 "Show diagnostics"
    echo
    menu_enter_hint "Exit"
    echo
    read_menu_choice choice
    case "$choice" in
      1) install_wizard ;;
      2) mtproxy_menu ;;
      3) xui_menu ;;
      4) show_diagnostics ;;
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
      menu_item 2 "Stop VPN service"
      menu_item 3 "Re-run install wizard"
      echo
      menu_item 4 "VPN users"
      echo
      menu_item 5 "MTProxy manager"
      menu_item 6 "3x-ui manager"
      echo
      menu_item 7 "Service menu"
      echo
      menu_enter_hint "Exit"
      echo
      read_menu_choice choice
      case "$choice" in
        1) restart_vpn_menu ;;
        2) stop_vpn_menu ;;
        3) install_wizard ;;
        4) vpn_users_menu ;;
        5) mtproxy_menu ;;
        6) xui_menu ;;
        7) service_tools_menu ;;
        "" | 0) exit 0 ;;
        *) invalid_choice ;;
      esac
    else
      menu_item 1 "Start VPN service"
      menu_item 2 "Re-run install wizard"
      echo
      menu_item 3 "VPN users"
      echo
      menu_item 4 "MTProxy manager"
      menu_item 5 "3x-ui manager"
      echo
      menu_item 6 "Service menu"
      echo
      menu_enter_hint "Exit"
      echo
      read_menu_choice choice
      case "$choice" in
        1) start_vpn_menu ;;
        2) install_wizard ;;
        3) vpn_users_menu ;;
        4) mtproxy_menu ;;
        5) xui_menu ;;
        6) service_tools_menu ;;
        "" | 0) exit 0 ;;
        *) invalid_choice ;;
      esac
    fi
  done
}

main() {
  require_root
  while true; do
    load_config
    if effective_installed; then
      main_menu_installed
    else
      main_menu_not_installed
    fi
  done
}

main "$@"
