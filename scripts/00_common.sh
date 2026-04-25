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

timestamp_for_backup() {
    date +%Y%m%d-%H%M%S
}

create_timestamped_backup_dir() {
    local label="${1:-backup}"
    local root="${BACKUP_ROOT:-${STATE_DIR}/backups}"
    local stamp dir i
    if [[ -n "${FORCE_BACKUP_DIR:-}" ]]; then
        dir="$FORCE_BACKUP_DIR"
        mkdir -p "$dir"
        chmod 700 "$dir" 2>/dev/null || true
        [[ -f "${dir}/INFO" ]] || printf 'label=%s
created_at=%s
' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${dir}/INFO"
        [[ -f "${dir}/MANIFEST.tsv" ]] || : > "${dir}/MANIFEST.tsv"
        chmod 600 "${dir}/INFO" "${dir}/MANIFEST.tsv" 2>/dev/null || true
        printf '%s
' "$dir"
        return 0
    fi
    stamp="$(timestamp_for_backup)"
    label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_')"
    dir="${root}/${stamp}-${label}"
    if [[ ! -e "$dir" ]]; then
        mkdir -p "$dir"
        chmod 700 "$dir" 2>/dev/null || true
        printf 'label=%s\ncreated_at=%s\n' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${dir}/INFO"
        : > "${dir}/MANIFEST.tsv"
        chmod 600 "${dir}/INFO" "${dir}/MANIFEST.tsv" 2>/dev/null || true
        printf '%s\n' "$dir"
        return 0
    fi
    for i in $(seq 1 999); do
        dir="${root}/${stamp}-${label}.${i}"
        if [[ ! -e "$dir" ]]; then
            mkdir -p "$dir"
            chmod 700 "$dir" 2>/dev/null || true
            printf 'label=%s\ncreated_at=%s\n' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${dir}/INFO"
            : > "${dir}/MANIFEST.tsv"
            chmod 600 "${dir}/INFO" "${dir}/MANIFEST.tsv" 2>/dev/null || true
            printf '%s\n' "$dir"
            return 0
        fi
    done
    die "Не удалось создать backup directory в ${root}"
}

backup_path_to_dir() {
    local path="$1"
    local dir="$2"
    local rel target kind
    [[ -e "$path" ]] || return 0
    ensure_dir "$dir"
    rel="${path#/}"
    target="${dir}/files/${rel}"
    if [[ -e "$target" ]]; then
        target="$(next_available_path "$target")"
    fi
    ensure_dir "$(dirname "$target")"
    if [[ -d "$path" && ! -L "$path" ]]; then
        kind="dir"
    else
        kind="file"
    fi
    cp -a -- "$path" "$target"
    printf '%s\t%s\t%s\n' "$kind" "$path" "${target#${dir}/}" >> "${dir}/MANIFEST.tsv"
    printf '%s\n' "$target"
}

backup_file_to_dir() {
    backup_path_to_dir "$@"
}

backup_file() {
    local file="$1"
    local label="${2:-}"
    if [[ -z "$label" ]]; then
        label="$(basename "$file")"
    fi
    if [[ -e "$file" ]]; then
        local dir backup
        dir="$(create_timestamped_backup_dir "$label")"
        backup="$(backup_path_to_dir "$file" "$dir")"
        printf '%s\n' "$backup"
    fi
}

# Full infrastructure backup used at the start of management/install runs.
# It intentionally skips ${STATE_DIR}/backups to avoid recursive backups.
_backup_existing_paths_to_dir() {
    local dir="$1"
    shift || true
    local path
    for path in "$@"; do
        [[ -e "$path" || -L "$path" ]] || continue
        backup_path_to_dir "$path" "$dir" >/dev/null
    done
}

create_full_infrastructure_backup() {
    local label="${1:-startup-full}"
    local dir entry unit
    dir="$(create_timestamped_backup_dir "$label")"
    {
        printf 'backup_type=full-infrastructure\n'
        printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf unknown)"
        printf 'created_by=%s\n' "${0:-unknown}"
        printf 'note=%s\n' 'Automatic backup before any management/install action. STATE_DIR/backups is excluded.'
    } >> "${dir}/INFO"

    if [[ -d "$STATE_DIR" ]]; then
        shopt -s nullglob dotglob
        for entry in "$STATE_DIR"/*; do
            [[ "$(basename "$entry")" == "backups" ]] && continue
            backup_path_to_dir "$entry" "$dir" >/dev/null
        done
        shopt -u nullglob dotglob
    fi

    _backup_existing_paths_to_dir "$dir" \
        "$NFTABLES_CONF" \
        "$SYSCTL_FILE" \
        /etc/default/prometheus \
        /etc/prometheus/prometheus.yml \
        /etc/grafana/grafana.ini \
        /etc/grafana/provisioning/datasources/awg-monitoring-prometheus.yml \
        /etc/grafana/provisioning/dashboards/awg-monitoring.yml \
        /var/lib/grafana/dashboards/awg-managed \
        /etc/wgexporter \
        /etc/sudoers.d/wgexporter \
        /usr/local/bin/wg \
        /usr/local/bin/prometheus_wireguard_exporter \
        /usr/local/sbin/awg-exporter-sync-peers \
        /usr/local/sbin/awg-persistent-traffic-exporter \
        /usr/local/sbin/check-awg-monitoring

    shopt -s nullglob
    for unit in \
        /etc/systemd/system/awg-quick@.service \
        /etc/systemd/system/wgexporter.service \
        /etc/systemd/system/awg-persistent-traffic.service; do
        [[ -e "$unit" ]] && backup_path_to_dir "$unit" "$dir" >/dev/null
    done
    shopt -u nullglob

    printf '%s\n' "$dir"
}

ensure_startup_full_backup() {
    local label="${1:-startup-full}"
    local dir
    if [[ "${AWG_DISABLE_STARTUP_BACKUP:-no}" == "yes" ]]; then
        warn "Startup full backup disabled by AWG_DISABLE_STARTUP_BACKUP=yes"
        return 0
    fi
    if [[ "${AWG_STARTUP_BACKUP_DONE:-no}" == "yes" ]]; then
        return 0
    fi
    dir="$(create_full_infrastructure_backup "$label")"
    export AWG_STARTUP_BACKUP_DONE=yes
    export AWG_STARTUP_BACKUP_DIR="$dir"
    ok "Full backup перед запуском: $dir"
}

restore_backup_dir() {
    local dir="$1"
    local manifest="${dir}/MANIFEST.tsv"
    local kind original rel backup_path tmp_list
    [[ -d "$dir" ]] || die "Backup directory не найден: $dir"
    [[ -f "$manifest" ]] || die "В backup нет MANIFEST.tsv: $manifest"
    tmp_list="$(mktemp)"
    tac "$manifest" > "$tmp_list"
    while IFS=$'\t' read -r kind original rel; do
        [[ -n "${kind:-}" && -n "${original:-}" && -n "${rel:-}" ]] || continue
        backup_path="${dir}/${rel}"
        [[ -e "$backup_path" ]] || { warn "В backup не найден объект: $backup_path"; continue; }
        ensure_dir "$(dirname "$original")"
        rm -rf -- "$original"
        cp -a -- "$backup_path" "$original"
    done < "$tmp_list"
    rm -f "$tmp_list"
}

replace_file_from_stdin() {
    local file="$1"
    local mode="${2:-600}"
    local backup_dir="${3:-}"
    local tmp
    ensure_dir "$(dirname "$file")"
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    if [[ -e "$file" && -n "$backup_dir" ]]; then
        backup_path_to_dir "$file" "$backup_dir" >/dev/null
    fi
    mv -f -- "$tmp" "$file"
}

# Transaction helpers for scripts that create several files and may be interrupted.
declare -ag AWG_CREATED_PATHS=()
AWG_ACTIVE_BACKUP_DIR=""
AWG_OPERATION_COMMITTED="yes"

begin_safe_operation() {
    local label="${1:-operation}"
    AWG_ACTIVE_BACKUP_DIR="$(create_timestamped_backup_dir "$label")"
    AWG_CREATED_PATHS=()
    AWG_OPERATION_COMMITTED="no"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'rollback_safe_operation "$?"' EXIT
    printf '%s\n' "$AWG_ACTIVE_BACKUP_DIR"
}

track_created_path() {
    local path="$1"
    AWG_CREATED_PATHS+=("$path")
    if [[ -n "${AWG_ACTIVE_BACKUP_DIR:-}" ]]; then
        printf '%s
' "$path" >> "${AWG_ACTIVE_BACKUP_DIR}/CREATED_PATHS"
        chmod 600 "${AWG_ACTIVE_BACKUP_DIR}/CREATED_PATHS" 2>/dev/null || true
    fi
}

operation_backup_path() {
    local path="$1"
    [[ -n "${AWG_ACTIVE_BACKUP_DIR:-}" ]] || die "operation_backup_path вызван без begin_safe_operation"
    backup_path_to_dir "$path" "$AWG_ACTIVE_BACKUP_DIR"
}

commit_safe_operation() {
    AWG_OPERATION_COMMITTED="yes"
    trap - EXIT INT TERM
}

rollback_safe_operation() {
    local code="${1:-1}"
    local i path
    if [[ "${AWG_OPERATION_COMMITTED:-yes}" == "yes" || "$code" == "0" ]]; then
        return 0
    fi
    warn "Операция прервана/завершилась ошибкой. Выполняю откат созданных файлов. Backup: ${AWG_ACTIVE_BACKUP_DIR:-нет}"
    if [[ -n "${AWG_ACTIVE_BACKUP_DIR:-}" && -f "${AWG_ACTIVE_BACKUP_DIR}/MANIFEST.tsv" ]]; then
        restore_backup_dir "$AWG_ACTIVE_BACKUP_DIR" || true
    fi
    for (( i=${#AWG_CREATED_PATHS[@]}-1; i>=0; i-- )); do
        path="${AWG_CREATED_PATHS[$i]}"
        [[ -n "$path" ]] && rm -rf -- "$path" 2>/dev/null || true
    done
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
    local backup_dir="${AWG_ACTIVE_BACKUP_DIR:-}"
    if [[ -z "$backup_dir" && -e "$file" ]]; then
        backup_dir="$(create_timestamped_backup_dir install-env)"
    fi
    cat <<EOF_STATE | replace_file_from_stdin "$file" 600 "$backup_dir"
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
    local server_enable_ipv6="${15:-yes}"
    local backup_dir="${AWG_ACTIVE_BACKUP_DIR:-}"
    if [[ -z "$backup_dir" && -e "$file" ]]; then
        backup_dir="$(create_timestamped_backup_dir manager-env-$(basename "$file"))"
    fi
    cat <<EOF_MANAGER | replace_file_from_stdin "$file" 600 "$backup_dir"
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
SERVER_ENABLE_IPV6='${server_enable_ipv6}'
SYSCTL_FILE='${SYSCTL_FILE}'
NFTABLES_CONF='${NFTABLES_CONF}'
FIREWALL_ENV_FILE='${FIREWALL_ENV_FILE}'
EOF_MANAGER
}

write_firewall_env() {
    local file="$1"
    local external_if="$2"
    local ssh_port="$3"
    local awg_ports="${4:-}"
    local awg_ifaces="${5:-}"
    local backup_dir="${AWG_ACTIVE_BACKUP_DIR:-}"
    if [[ -z "$backup_dir" && -e "$file" ]]; then
        backup_dir="$(create_timestamped_backup_dir firewall-env)"
    fi
    cat <<EOF_FW | replace_file_from_stdin "$file" 600 "$backup_dir"
# Generated by 03_setup_nftables.sh
EXTERNAL_IF='${external_if}'
SSH_PORT='${ssh_port}'
NFTABLES_CONF='${NFTABLES_CONF}'
AWG_PORTS='${awg_ports}'
AWG_IFACES='${awg_ifaces}'
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


detect_default_ipv4_source() {
    local src
    src="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/ src / {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
    if [[ -z "$src" ]]; then
        src="$(hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')"
    fi
    printf '%s\n' "$src"
}

next_ipv4_cidr_default() {
    local used="" conf cidr ip third i
    shopt -s nullglob
    for conf in "$STATE_DIR"/*.conf; do
        cidr="$(get_server_ipv4_cidr "$conf" 2>/dev/null || true)"
        ip="${cidr%/*}"
        if [[ "$ip" =~ ^10\.8\.([0-9]{1,3})\.1$ ]]; then
            third="${BASH_REMATCH[1]}"
            used="${used}"$'\n'"${third}"
        fi
    done
    shopt -u nullglob
    for i in $(seq 1 254); do
        if ! grep -qx "$i" <<< "$used"; then
            printf '10.8.%s.1/24\n' "$i"
            return 0
        fi
    done
    printf '10.8.1.1/24\n'
}

ipv4_cidr_third_octet() {
    local cidr="$1" ip
    ip="${cidr%/*}"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3})\.[0-9]{1,3}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

default_ipv6_cidr_for_ipv4() {
    local ipv4_cidr="$1"
    local idx third
    idx="$(ipv4_cidr_third_octet "$ipv4_cidr" 2>/dev/null || printf '1')"
    third="$(printf '%x' $((0x42 + idx - 1)))"
    printf 'fd42:42:%s::1/64\n' "$third"
}

next_ipv6_cidr_default() {
    local ipv4_cidr="${1:-}"
    [[ -n "$ipv4_cidr" ]] || ipv4_cidr="$(next_ipv4_cidr_default)"
    default_ipv6_cidr_for_ipv4 "$ipv4_cidr"
}

normalise_yes_no() {
    local value="$1"
    case "$value" in
        yes|Y|y|1|true|True|TRUE|да|Да|ДА) printf 'yes\n' ;;
        no|N|n|0|false|False|FALSE|нет|Нет|НЕТ) printf 'no\n' ;;
        *) return 1 ;;
    esac
}

validate_yes_no() {
    normalise_yes_no "$1" >/dev/null || { warn "Введите yes/no"; return 1; }
}

server_conf_has_ipv6() {
    local conf="$1"
    [[ -n "$(get_server_ipv6_cidr "$conf" 2>/dev/null || true)" ]]
}

server_conf_ipv6_safe_for_mtu() {
    local conf="$1"
    local mtu
    mtu="$(get_server_mtu "$conf" 2>/dev/null || true)"
    [[ -z "$mtu" || ! "$mtu" =~ ^[0-9]+$ || "$mtu" -ge 1280 ]]
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
    [[ -f "$conf" ]] || return 1
    grep -Eq "^([[:space:]]*### Client ${name}|[[:space:]]*#[[:space:]]*friendly_name[[:space:]]*=[[:space:]]*${name})[[:space:]]*$" "$conf"
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
    local server_enable_ipv6="${15:-yes}"
    local iface_env
    iface_env="$(manager_env_for_iface "$vpn_if")"
    write_manager_env "$iface_env" "$vpn_if" "$server_conf" "$clients_dir" "$keys_dir" "$endpoint_host" "$endpoint_port" "$service_name" "$awg_bin" "$awg_quick_bin" "$dns_servers" "$external_if" "$ssh_port" "$default_client_mtu" "$server_enable_ipv6"
    # Backward-compatible pointer to the most recently configured interface.
    write_manager_env "$pointer_file" "$vpn_if" "$server_conf" "$clients_dir" "$keys_dir" "$endpoint_host" "$endpoint_port" "$service_name" "$awg_bin" "$awg_quick_bin" "$dns_servers" "$external_if" "$ssh_port" "$default_client_mtu" "$server_enable_ipv6"
}

derive_minimal_env_for_iface() {
    local vpn_if="$1"
    VPN_IF="$vpn_if"
    SERVER_CONF="$(server_conf_for_iface "$vpn_if")"
    CLIENTS_DIR="$(clients_dir_for_iface "$vpn_if")"
    KEYS_DIR="$(keys_dir_for_iface "$vpn_if")"
    SERVICE_NAME="awg-quick@${vpn_if}.service"
    AWG_BIN="$(detect_awg_bin)"
    AWG_QUICK_BIN="$(detect_awg_quick_bin)"
}

load_manager_env_for_iface() {
    local requested_if="${1:-}"
    local iface_env
    if [[ -n "$requested_if" ]]; then
        iface_env="$(manager_env_for_iface "$requested_if")"
        if [[ -f "$iface_env" ]]; then
            source_env_if_exists "$iface_env"
        elif [[ -f "$(server_conf_for_iface "$requested_if")" ]]; then
            warn "Файл настроек интерфейса не найден: $iface_env; использую безопасные значения из имени интерфейса и server.conf"
            derive_minimal_env_for_iface "$requested_if"
        else
            die "Не найден ни файл настроек интерфейса, ни server.conf: $iface_env / $(server_conf_for_iface "$requested_if")"
        fi
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
    # Count actual [Peer] blocks. Older bundle versions used ### Client comments,
    # while the Grafana-friendly format now uses # friendly_name=<name>.
    [[ -f "$conf" ]] && by_conf="$(grep -cE '^[[:space:]]*\[Peer\][[:space:]]*$' "$conf" || true)"
    clients_dir="$(clients_dir_for_iface "$iface")"
    by_files=0
    if [[ -d "$clients_dir" ]]; then
        by_files="$(find "$clients_dir" -maxdepth 1 -type f -name '*.conf' | wc -l | tr -d ' ')"
    fi
    printf '%s/%s\n' "$by_conf" "$by_files"
}


list_clients_for_iface_tsv() {
    local iface="$1"
    local conf
    conf="$(server_conf_for_iface "$iface")"
    [[ -f "$conf" ]] || die "Не найден server.conf: $conf"
    python3 -S - "$conf" <<'PY'
import re
import sys
from pathlib import Path

conf = Path(sys.argv[1])
lines = conf.read_text(encoding='utf-8', errors='replace').splitlines()
peers = []
pending_legacy = ''
current = None

def finish(peer):
    if not peer:
        return
    idx = len(peers) + 1
    name = peer.get('friendly') or peer.get('legacy') or f'peer_{idx}'
    public = peer.get('public_key', '')
    allowed = peer.get('allowed_ips', '')
    peers.append((idx, name, public, allowed))

for raw in lines:
    stripped = raw.strip()
    m = re.match(r'^###\s*Client\s+(.+?)\s*$', stripped)
    if m:
        pending_legacy = m.group(1).strip()
        if current is not None and not current.get('legacy'):
            current['legacy'] = pending_legacy
        continue
    if stripped == '[Peer]':
        finish(current)
        current = {'legacy': pending_legacy}
        pending_legacy = ''
        continue
    if current is None:
        continue
    m = re.match(r'^#\s*friendly_name\s*=\s*(.+?)\s*$', stripped)
    if m:
        current['friendly'] = m.group(1).strip()
        continue
    m = re.match(r'^PublicKey\s*=\s*(.+?)\s*$', stripped)
    if m:
        current['public_key'] = m.group(1).strip()
        continue
    m = re.match(r'^AllowedIPs\s*=\s*(.+?)\s*$', stripped)
    if m:
        current['allowed_ips'] = m.group(1).strip()
        continue
finish(current)
for idx, name, public, allowed in peers:
    safe = lambda s: str(s).replace('\t', ' ').replace('\n', ' ').strip()
    print(f"{idx}\t{safe(name)}\t{safe(public)}\t{safe(allowed)}")
PY
}

select_client_interactive() {
    local iface="$1"
    local clients count choice line idx name public allowed
    mapfile -t clients < <(list_clients_for_iface_tsv "$iface")
    count="${#clients[@]}"
    if (( count == 0 )); then
        die "В интерфейсе ${iface} не найдено клиентов ([Peer] блоков)."
    fi
    printf 'Доступные клиенты в %s:\n' "$iface" >&2
    for line in "${clients[@]}"; do
        IFS=$'\t' read -r idx name public allowed <<<"$line"
        [[ -n "$name" ]] || name="peer_${idx}"
        [[ -n "$public" ]] || public="NO_PUBLIC_KEY"
        [[ -n "$allowed" ]] || allowed="NO_ALLOWED_IPS"
        printf '  %s) %-24s %-24s %.16s...\n' "$idx" "$name" "$allowed" "$public" >&2
    done
    while true; do
        read -r -p "Выберите клиента [1]: " choice || choice=""
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            printf '%s\n' "${clients[$((choice - 1))]}"
            return 0
        fi
        warn "Введите номер от 1 до ${count}"
    done
}

strip_cr() {
    tr -d '\r'
}
