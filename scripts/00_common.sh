#!/usr/bin/env bash

# Shared helpers for the AmneziaWG bash bundle.

AMNEZIA_BUNDLE_ROOT="${AMNEZIA_BUNDLE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCES_DIR="${SOURCES_DIR:-${AMNEZIA_BUNDLE_ROOT}/sources}"
DOCS_DIR="${DOCS_DIR:-${AMNEZIA_BUNDLE_ROOT}/docs}"
STATE_DIR="${STATE_DIR:-/etc/amnezia/amneziawg}"
INSTALL_STATE_FILE="${INSTALL_STATE_FILE:-${STATE_DIR}/install.env}"
MANAGER_ENV_FILE="${MANAGER_ENV_FILE:-${STATE_DIR}/manager.env}"
FIREWALL_ENV_FILE="${FIREWALL_ENV_FILE:-${STATE_DIR}/firewall.env}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/00-amnezia.conf}"
NFTABLES_CONF="${NFTABLES_CONF:-/etc/nftables.conf}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
CACHE_DIR="${CACHE_DIR:-/usr/local/src/amneziawg-cache}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Запустите скрипт от root (sudo)."
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

ensure_dir() {
    mkdir -p "$1"
}

next_available_path() {
    local path="$1"
    local candidate suffix i
    if [[ ! -e "$path" ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    suffix="$(date +%Y%m%d-%H%M%S)-$$"
    candidate="${path}.${suffix}"
    if [[ ! -e "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    for i in $(seq 1 999); do
        candidate="${path}.${suffix}.${i}"
        if [[ ! -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    die "Не удалось подобрать свободный путь для: $path"
}

write_new_file_from_stdin() {
    local file="$1"
    local mode="${2:-600}"
    ensure_dir "$(dirname "$file")"
    if [[ -e "$file" ]]; then
        die "Отказ перезаписывать существующий файл: $file"
    fi
    if ! ( set -o noclobber; cat > "$file" ); then
        die "Не удалось безопасно создать новый файл: $file"
    fi
    chmod "$mode" "$file"
}

append_or_create_file_from_stdin() {
    local file="$1"
    local mode="${2:-600}"
    ensure_dir "$(dirname "$file")"
    if [[ -e "$file" ]]; then
        {
            printf '\n# --- Appended by AmneziaWG bash bundle at %s; previous content preserved. ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            cat
        } >> "$file"
    else
        write_new_file_from_stdin "$file" "$mode"
    fi
}

backup_file() {
    local file="$1"
    if [[ -e "$file" ]]; then
        local backup
        backup="$(next_available_path "${file}.bak")"
        cp -a -- "$file" "$backup"
        printf '%s\n' "$backup"
    fi
}

prompt_default() {
    local question="$1"
    local default="${2:-}"
    local reply=""
    if [[ -n "$default" ]]; then
        read -r -p "$question [$default]: " reply || reply=""
        printf '%s\n' "${reply:-$default}"
    else
        read -r -p "$question: " reply || reply=""
        printf '%s\n' "$reply"
    fi
}

confirm() {
    local question="$1"
    local default="${2:-N}"
    local prompt reply=""
    case "$default" in
        Y|y) prompt="[Y/n]" ;;
        *) prompt="[y/N]" ;;
    esac
    read -r -p "$question $prompt " reply || reply=""
    if [[ -z "$reply" ]]; then
        reply="$default"
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_choice() {
    local question="$1"
    local default="$2"
    local choices="$3"
    local reply=""
    while true; do
        read -r -p "$question [$default]: " reply || reply=""
        reply="${reply:-$default}"
        if [[ " $choices " == *" $reply "* ]]; then
            printf '%s\n' "$reply"
            return 0
        fi
        warn "Допустимые варианты: ${choices}"
    done
}

prompt_until_valid() {
    local question="$1"
    local default="$2"
    local validator="$3"
    local value
    while true; do
        value="$(prompt_default "$question" "$default")"
        if "$validator" "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done
}

ensure_sysctl_kv() {
    local file="$1"
    local key="$2"
    local value="$3"
    ensure_dir "$(dirname "$file")"
    if [[ -f "$file" ]] && grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$file"; then
        return 0
    fi
    {
        if [[ -f "$file" ]]; then
            printf '\n# Added by AmneziaWG bash bundle; existing sysctl lines above are preserved.\n'
        fi
        printf '%s = %s\n' "$key" "$value"
    } >> "$file"
}

remove_sysctl_key() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 0
    warn "Не удаляю ${key} из ${file}: политика безопасности запрещает менять старые строки. Добавьте новое значение в конец файла вручную, если нужно переопределение."
}

source_env_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        # shellcheck disable=SC1090
        source "$file"
    fi
}

write_install_state() {
    local file="$1"
    local awg_bin="$2"
    local awg_quick_bin="$3"
    local kmod_cache="$4"
    local tools_cache="$5"
    cat <<EOF_STATE | append_or_create_file_from_stdin "$file" 600
# Generated by 01_install_from_source.sh
STATE_DIR='${STATE_DIR}'
CACHE_DIR='${CACHE_DIR}'
INSTALL_PREFIX='${INSTALL_PREFIX}'
AWG_BIN='${awg_bin}'
AWG_QUICK_BIN='${awg_quick_bin}'
KMOD_CACHE_DIR='${kmod_cache}'
TOOLS_CACHE_DIR='${tools_cache}'
SYSCTL_FILE='${SYSCTL_FILE}'
TOOLS_INSTALL_ROOT='${TOOLS_INSTALL_ROOT:-}'
TOOLS_INSTALL_PREFIX='${TOOLS_INSTALL_PREFIX:-}'
EOF_STATE
}

write_manager_env() {
    local file="$1"
    local vpn_if="$2"
    local server_conf="$3"
    local clients_dir="$4"
    local keys_dir="$5"
    local endpoint_host="$6"
    local endpoint_port="$7"
    local service_name="$8"
    local awg_bin="$9"
    local awg_quick_bin="${10}"
    local dns_servers="${11}"
    local external_if="${12:-}"
    local ssh_port="${13:-22}"
    local default_client_mtu="${14:-1280}"
    cat <<EOF_MANAGER | append_or_create_file_from_stdin "$file" 600
# Generated by bundle scripts.
STATE_DIR='${STATE_DIR}'
SERVER_CONF='${server_conf}'
CLIENTS_DIR='${clients_dir}'
KEYS_DIR='${keys_dir}'
VPN_IF='${vpn_if}'
SERVICE_NAME='${service_name}'
ENDPOINT_HOST='${endpoint_host}'
ENDPOINT_PORT='${endpoint_port}'
AWG_BIN='${awg_bin}'
AWG_QUICK_BIN='${awg_quick_bin}'
DNS_SERVERS='${dns_servers}'
EXTERNAL_IF='${external_if}'
SSH_PORT='${ssh_port}'
DEFAULT_CLIENT_MTU='${default_client_mtu}'
SYSCTL_FILE='${SYSCTL_FILE}'
NFTABLES_CONF='${NFTABLES_CONF}'
FIREWALL_ENV_FILE='${FIREWALL_ENV_FILE}'
EOF_MANAGER
}

write_firewall_env() {
    local file="$1"
    local external_if="$2"
    local ssh_port="$3"
    cat <<EOF_FW | append_or_create_file_from_stdin "$file" 600
# Generated by 03_setup_nftables.sh
EXTERNAL_IF='${external_if}'
SSH_PORT='${ssh_port}'
NFTABLES_CONF='${NFTABLES_CONF}'
EOF_FW
}

detect_os() {
    if [[ -n "${DISTRO_ID_OVERRIDE:-}" ]]; then
        DISTRO_ID="$DISTRO_ID_OVERRIDE"
        DISTRO_LIKE="${DISTRO_LIKE_OVERRIDE:-}"
        return 0
    fi
    [[ -f /etc/os-release ]] || die "Не найден /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_LIKE="${ID_LIKE:-}"
}

is_debian_family() {
    [[ "${DISTRO_ID:-}" == "ubuntu" || "${DISTRO_ID:-}" == "debian" || "${DISTRO_LIKE:-}" == *debian* ]]
}

is_fedora_family() {
    [[ "${DISTRO_ID:-}" == "fedora" || "${DISTRO_LIKE:-}" == *fedora* || "${DISTRO_LIKE:-}" == *rhel* ]]
}

first_cmd_path() {
    local name="$1"
    shift || true
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    local candidate
    for candidate in "$@"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

first_existing_exec() {
    local candidate
    for candidate in "$@"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

detect_awg_bin() {
    source_env_if_exists "$INSTALL_STATE_FILE"
    first_cmd_path awg "${AWG_BIN:-}" "${INSTALL_PREFIX}/bin/awg" /usr/local/bin/awg /usr/bin/awg 2>/dev/null || true
}

detect_awg_quick_bin() {
    source_env_if_exists "$INSTALL_STATE_FILE"
    first_cmd_path awg-quick "${AWG_QUICK_BIN:-}" "${INSTALL_PREFIX}/bin/awg-quick" /usr/local/bin/awg-quick /usr/bin/awg-quick 2>/dev/null || true
}

detect_default_interface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [[ -z "$iface" ]]; then
        iface="$(ip -o route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    fi
    printf '%s\n' "$iface"
}

get_conf_value() {
    local conf="$1"
    local key="$2"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" | head -n1 | sed -E 's/^[^=]+=[[:space:]]*//'
}

get_server_ipv4_cidr() {
    local conf="$1"
    grep -E '^[[:space:]]*Address[[:space:]]*=[[:space:]]*[0-9]+\.' "$conf" | head -n1 | sed -E 's/^[^=]+=[[:space:]]*//'
}

get_server_ipv6_cidr() {
    local conf="$1"
    grep -E '^[[:space:]]*Address[[:space:]]*=[[:space:]]*[0-9A-Fa-f:]+/' "$conf" | head -n1 | sed -E 's/^[^=]+=[[:space:]]*//'
}

get_server_mtu() {
    local conf="$1"
    get_conf_value "$conf" "MTU" 2>/dev/null || true
}

get_obfuscation_block() {
    local conf="$1"
    local key value
    for key in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
        value="$(get_conf_value "$conf" "$key" || true)"
        if [[ -n "$value" ]]; then
            printf '%s = %s\n' "$key" "$value"
        fi
    done
}

validate_iface_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        warn "Имя интерфейса может содержать только A-Z, a-z, 0-9, _, . и -"
        return 1
    fi
    if (( ${#name} > 15 )); then
        warn "Имя интерфейса Linux должно быть не длиннее 15 символов"
        return 1
    fi
    return 0
}

validate_client_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Имя клиента может содержать только A-Z, a-z, 0-9, _ и -"
}

validate_port() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
        return 0
    fi
    warn "Порт должен быть числом от 1 до 65535"
    return 1
}

validate_mtu() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 576 && value <= 9000 )); then
        return 0
    fi
    warn "MTU должен быть числом от 576 до 9000. Для мобильных сетей обычно пробуют 1280 или 1360."
    return 1
}

validate_uint32() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= 4294967295 )); then
        return 0
    fi
    warn "Значение должно быть целым числом от 0 до 4294967295"
    return 1
}

validate_small_nonneg_int() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= 10000 )); then
        return 0
    fi
    warn "Значение должно быть неотрицательным целым числом"
    return 1
}

validate_ipv4_cidr_24() {
    local value="$1"
    local a b c d p
    if [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"; p="${BASH_REMATCH[5]}"
        if (( a <= 255 && b <= 255 && c <= 255 && d <= 255 && p == 24 )); then
            return 0
        fi
    fi
    warn "IPv4 адрес сервера должен быть в формате 10.8.X.1/24. Автовыдача клиентов сейчас рассчитана на /24."
    return 1
}

validate_ipv6_cidr_64() {
    local value="$1"
    if [[ "$value" =~ ^[0-9A-Fa-f:]+::(1)?/64$ ]]; then
        return 0
    fi
    warn "IPv6 адрес сервера должен быть в формате fd42:42:42::1/64 или fd42:42:42::/64"
    return 1
}

client_exists_in_conf() {
    local conf="$1"
    local name="$2"
    grep -q "^### Client ${name}$" "$conf"
}

next_free_ipv4() {
    local conf="$1"
    local server_cidr="$2"
    local server_ip network_prefix used candidate i
    server_ip="${server_cidr%/*}"
    network_prefix="${server_ip%.*}"
    used="$(grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$conf" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || true)"
    used="${used}"$'\n'"${server_ip}"
    for i in $(seq 2 254); do
        candidate="${network_prefix}.${i}"
        if ! grep -qx "$candidate" <<<"$used"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

ipv6_base_from_server_cidr() {
    local cidr="$1"
    local ip
    ip="${cidr%/*}"
    if [[ "$ip" =~ ^(.+)::1$ ]]; then
        printf '%s::\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$ip" =~ ^(.+)::$ ]]; then
        printf '%s::\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    die "IPv6 адрес сервера должен быть в формате ...::1/64 или ...::/64, получено: ${cidr}"
}

client_ipv6_from_server_cidr() {
    local cidr="$1"
    local host_id="$2"
    local base
    base="$(ipv6_base_from_server_cidr "$cidr")"
    printf '%s%s\n' "$base" "$host_id"
}

find_source_archive() {
    local base_name="$1"
    local candidate
    for candidate in \
        "${SOURCES_DIR}/${base_name}.tar.gz" \
        "${SOURCES_DIR}/${base_name}-master.tar.gz" \
        "${SOURCES_DIR}/${base_name}.tgz" \
        "${SOURCES_DIR}/${base_name}-main.tar.gz"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

extract_source_archive() {
    local archive="$1"
    local dest_root="$2"
    local actual_dest
    actual_dest="$(next_available_path "$dest_root")"
    mkdir -p "$actual_dest"
    tar -xzf "$archive" -C "$actual_dest"
    find "$actual_dest" -mindepth 1 -maxdepth 1 -type d | head -n1
}

create_awg_quick_service_template() {
    local awg_quick_bin="$1"
    local unit_file="${SYSTEMD_DIR}/awg-quick@.service"
    local tmp candidate awg_quick_dir
    awg_quick_dir="$(dirname "$awg_quick_bin")"
    ensure_dir "$SYSTEMD_DIR"
    tmp="$(mktemp "${unit_file}.tmp.XXXXXX")"
    cat > "$tmp" <<EOF_UNIT
[Unit]
Description=AmneziaWG interface %i via awg-quick
After=network-online.target
Wants=network-online.target
Documentation=man:awg-quick(8) man:awg(8)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${awg_quick_bin} up ${STATE_DIR}/%i.conf
ExecStop=${awg_quick_bin} down ${STATE_DIR}/%i.conf
Environment=PATH=${awg_quick_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 644 "$tmp"
    if [[ -e "$unit_file" ]]; then
        if cmp -s "$tmp" "$unit_file"; then
            rm -f "$tmp"
        else
            candidate="$(next_available_path "${unit_file}.candidate")"
            mv -- "$tmp" "$candidate"
            warn "systemd unit уже существует и не перезаписан: $unit_file"
            warn "Новый вариант сохранён отдельно: $candidate"
        fi
    else
        mv -- "$tmp" "$unit_file"
    fi
    printf '%s\n' "$unit_file"
}

calc_public_key() {
    local awg_bin="$1"
    local private_key_file="$2"
    "$awg_bin" pubkey < "$private_key_file"
}

manager_env_for_iface() {
    local vpn_if="$1"
    printf '%s/manager-%s.env\n' "$STATE_DIR" "$vpn_if"
}

write_manager_env_for_iface() {
    local pointer_file="$1"
    local vpn_if="$2"
    local server_conf="$3"
    local clients_dir="$4"
    local keys_dir="$5"
    local endpoint_host="$6"
    local endpoint_port="$7"
    local service_name="$8"
    local awg_bin="$9"
    local awg_quick_bin="${10}"
    local dns_servers="${11}"
    local external_if="${12:-}"
    local ssh_port="${13:-22}"
    local default_client_mtu="${14:-1280}"
    local iface_env
    iface_env="$(manager_env_for_iface "$vpn_if")"
    write_manager_env "$iface_env" "$vpn_if" "$server_conf" "$clients_dir" "$keys_dir" "$endpoint_host" "$endpoint_port" "$service_name" "$awg_bin" "$awg_quick_bin" "$dns_servers" "$external_if" "$ssh_port" "$default_client_mtu"
    # Backward-compatible pointer to the most recently configured interface.
    # The pointer is append-only: older blocks remain intact and shell source uses the last assignments.
    write_manager_env "$pointer_file" "$vpn_if" "$server_conf" "$clients_dir" "$keys_dir" "$endpoint_host" "$endpoint_port" "$service_name" "$awg_bin" "$awg_quick_bin" "$dns_servers" "$external_if" "$ssh_port" "$default_client_mtu"
}

load_manager_env_for_iface() {
    local requested_if="${1:-}"
    local iface_env
    if [[ -n "$requested_if" ]]; then
        iface_env="$(manager_env_for_iface "$requested_if")"
        [[ -f "$iface_env" ]] || die "Не найден файл настроек интерфейса: $iface_env"
        source_env_if_exists "$iface_env"
    else
        source_env_if_exists "$MANAGER_ENV_FILE"
    fi
}

server_conf_for_iface() {
    local vpn_if="$1"
    printf '%s/%s.conf\n' "$STATE_DIR" "$vpn_if"
}

keys_dir_for_iface() {
    local vpn_if="$1"
    if [[ "$vpn_if" == "awg0" ]]; then
        if [[ -d "$STATE_DIR/keys" || ! -d "$STATE_DIR/awg0/keys" ]]; then
            printf '%s/keys\n' "$STATE_DIR"
        else
            printf '%s/%s/keys\n' "$STATE_DIR" "$vpn_if"
        fi
    else
        printf '%s/%s/keys\n' "$STATE_DIR" "$vpn_if"
    fi
}

clients_dir_for_iface() {
    local vpn_if="$1"
    if [[ "$vpn_if" == "awg0" ]]; then
        if [[ -d "$STATE_DIR/clients" || ! -d "$STATE_DIR/awg0/clients" ]]; then
            printf '%s/clients\n' "$STATE_DIR"
        else
            printf '%s/%s/clients\n' "$STATE_DIR" "$vpn_if"
        fi
    else
        printf '%s/%s/clients\n' "$STATE_DIR" "$vpn_if"
    fi
}

list_awg_interfaces_from_confs() {
    local conf base
    shopt -s nullglob
    for conf in "$STATE_DIR"/*.conf; do
        base="$(basename "$conf" .conf)"
        [[ -n "$base" ]] && printf '%s\n' "$base"
    done | sort -V
    shopt -u nullglob
}

interface_count() {
    list_awg_interfaces_from_confs | sed '/^$/d' | wc -l | tr -d ' '
}

next_iface_name() {
    local i name
    for i in $(seq 0 99); do
        name="awg${i}"
        if [[ ! -e "$(server_conf_for_iface "$name")" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    die "Не удалось подобрать свободное имя интерфейса awg0..awg99"
}

select_iface_interactive() {
    local requested="${1:-}"
    local ifaces iface count idx choice
    if [[ -n "$requested" ]]; then
        printf '%s\n' "$requested"
        return 0
    fi
    mapfile -t ifaces < <(list_awg_interfaces_from_confs)
    count="${#ifaces[@]}"
    if (( count == 0 )); then
        die "Не найдено ни одного интерфейса в ${STATE_DIR}/*.conf"
    fi
    if (( count == 1 )); then
        printf '%s\n' "${ifaces[0]}"
        return 0
    fi
    printf 'Доступные интерфейсы:\n' >&2
    idx=1
    for iface in "${ifaces[@]}"; do
        printf '  %s) %s\n' "$idx" "$iface" >&2
        idx=$((idx + 1))
    done
    while true; do
        read -r -p "Выберите интерфейс [1]: " choice || choice=""
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            printf '%s\n' "${ifaces[$((choice - 1))]}"
            return 0
        fi
        warn "Введите номер от 1 до ${count}"
    done
}

count_clients_for_iface() {
    local iface="$1"
    local conf clients_dir by_conf by_files
    conf="$(server_conf_for_iface "$iface")"
    by_conf=0
    [[ -f "$conf" ]] && by_conf="$(grep -c '^### Client ' "$conf" || true)"
    clients_dir="$(clients_dir_for_iface "$iface")"
    by_files=0
    if [[ -d "$clients_dir" ]]; then
        by_files="$(find "$clients_dir" -maxdepth 1 -type f -name '*.conf' | wc -l | tr -d ' ')"
    fi
    printf '%s/%s\n' "$by_conf" "$by_files"
}

strip_cr() {
    tr -d '\r'
}
