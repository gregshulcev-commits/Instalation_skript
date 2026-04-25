#!/usr/bin/env bash
set -Eeuo pipefail

# Monitoring installer for existing AmneziaWG bundle.
# It adds/updates only monitoring-related files and services.
# It does not modify the AWG install/config/client scripts.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

MONITORING_DIR="${AMNEZIA_BUNDLE_ROOT}/monitoring"
WG_CONF_DIR="${WG_CONF_DIR:-${STATE_DIR}}"
WG_IFACES_INPUT="${WG_IFACES:-${WG_IFACE:-auto}}"
INCLUDE_INACTIVE_IFACES="${INCLUDE_INACTIVE_IFACES:-no}"

EXPORTER_USER="${EXPORTER_USER:-wgexporter}"
EXPORTER_PORT="${EXPORTER_PORT:-9586}"
PERSISTENT_EXPORTER_PORT="${PERSISTENT_EXPORTER_PORT:-9587}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
PROMETHEUS_RETENTION_TIME="${PROMETHEUS_RETENTION_TIME:-180d}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
GRAFANA_HTTP_ADDR="${GRAFANA_HTTP_ADDR:-0.0.0.0}"

SRC_DIR="${SRC_DIR:-/usr/local/src/prometheus_wireguard_exporter}"
EXPORTER_BIN="${EXPORTER_BIN:-/usr/local/bin/prometheus_wireguard_exporter}"
WGEXPORTER_DIR="${WGEXPORTER_DIR:-/etc/wgexporter}"
WGEXPORTER_PEERS_FILE="${WGEXPORTER_PEERS_FILE:-${WGEXPORTER_DIR}/peers.conf}"
WGEXPORTER_ENV_FILE="${WGEXPORTER_ENV_FILE:-${WGEXPORTER_DIR}/monitoring.env}"
WGEXPORTER_STATE_DIR="${WGEXPORTER_STATE_DIR:-/var/lib/wgexporter}"

INSTALL_PROMETHEUS="${INSTALL_PROMETHEUS:-yes}"
INSTALL_GRAFANA="${INSTALL_GRAFANA:-yes}"
INSTALL_PERSISTENT_EXPORTER="${INSTALL_PERSISTENT_EXPORTER:-yes}"
CONFIGURE_NFTABLES="${CONFIGURE_NFTABLES:-yes}"
UPDATE_EXPORTER="${UPDATE_EXPORTER:-no}"
MANAGE_EXISTING_GRAFANA_INI="${MANAGE_EXISTING_GRAFANA_INI:-no}"
PROMETHEUS_BIND_LOCALHOST="${PROMETHEUS_BIND_LOCALHOST:-yes}"
EXPORTER_INTERFACE_MODE="${EXPORTER_INTERFACE_MODE:-all}"  # all|explicit

AWG_MONITORING_BACKUP_DIR=""
MONITOR_IFACES=()
MONITOR_CONFS=()
GRAFANA_INSTALLED_BY_SCRIPT="no"

usage() {
    cat <<'USAGE'
11_setup_monitoring.sh

Install/update monitoring for all AmneziaWG interfaces without touching AWG setup scripts.

Usage:
  sudo ./scripts/11_setup_monitoring.sh
  sudo ./scripts/11_setup_monitoring.sh --status
  sudo WG_IFACES="awg0 awg1 awg800" ./scripts/11_setup_monitoring.sh

Important environment variables:
  WG_IFACES=auto|"awg0 awg1"          Interfaces to monitor. Default: auto.
  WG_CONF_DIR=/etc/amnezia/amneziawg  Config directory.
  INCLUDE_INACTIVE_IFACES=no|yes      Include configs even if awg show fails.
  EXPORTER_PORT=9586                  Raw exporter localhost port.
  PERSISTENT_EXPORTER_PORT=9587       Persistent totals exporter localhost port.
  PROMETHEUS_PORT=9090                Prometheus localhost port.
  GRAFANA_PORT=3000                   Grafana port.
  INSTALL_PROMETHEUS=yes|no           Install/configure Prometheus.
  INSTALL_GRAFANA=yes|no              Install/provision Grafana.
  INSTALL_PERSISTENT_EXPORTER=yes|no  Enable persistent traffic totals.
  CONFIGURE_NFTABLES=yes|no           Restrict Grafana port to AWG interfaces.
  UPDATE_EXPORTER=no|yes              Rebuild exporter even if binary exists.
  MANAGE_EXISTING_GRAFANA_INI=no|yes  Patch grafana.ini even if Grafana already existed.
  EXPORTER_INTERFACE_MODE=all|explicit Default all uses wg show all dump via wrapper.

Managed files:
  /etc/systemd/system/wgexporter.service
  /etc/systemd/system/awg-persistent-traffic.service
  /etc/wgexporter/monitoring.env
  /etc/wgexporter/peers.conf
  /etc/sudoers.d/wgexporter
  /etc/grafana/provisioning/datasources/awg-monitoring-prometheus.yml
  /etc/grafana/provisioning/dashboards/awg-monitoring.yml
  /var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json
USAGE
}

mon_log() { printf '\n== %s ==\n' "$*"; }
mon_warn() { printf '[monitoring warning] %s\n' "$*" >&2; }
mon_fail() { printf '[monitoring error] %s\n' "$*" >&2; exit 1; }

backup_mon_file() {
    local path="$1"
    [[ -n "$AWG_MONITORING_BACKUP_DIR" ]] || AWG_MONITORING_BACKUP_DIR="$(create_timestamped_backup_dir monitoring)"
    backup_path_to_dir "$path" "$AWG_MONITORING_BACKUP_DIR" >/dev/null || true
}

backup_runtime_nftables() {
    [[ -n "$AWG_MONITORING_BACKUP_DIR" ]] || AWG_MONITORING_BACKUP_DIR="$(create_timestamped_backup_dir monitoring)"
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset >"${AWG_MONITORING_BACKUP_DIR}/nftables-runtime.rules" 2>/dev/null || true
        chmod 600 "${AWG_MONITORING_BACKUP_DIR}/nftables-runtime.rules" 2>/dev/null || true
    fi
}

bool_yes() {
    case "${1:-}" in
        yes|YES|y|Y|1|true|TRUE) return 0 ;;
        *) return 1 ;;
    esac
}

split_words() {
    printf '%s\n' "$1" | tr ',;' '  '
}

contains_word() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

join_by_space() {
    local IFS=' '
    printf '%s\n' "$*"
}

version_or_absent() {
    local label="$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        printf '%-34s %s\n' "$label:" "$($@ 2>&1 | head -n1 || true)"
    else
        printf '%-34s %s\n' "$label:" "not installed"
    fi
}

pkg_version_or_absent() {
    local pkg="$1"
    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status} ${Version}\n' "$pkg" 2>/dev/null | grep -q '^install ok installed'; then
        printf '%-34s %s\n' "package ${pkg}:" "$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
    else
        printf '%-34s %s\n' "package ${pkg}:" "not installed"
    fi
}

print_versions() {
    mon_log "Installed component versions"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        printf '%-34s %s\n' "os:" "${PRETTY_NAME:-unknown}"
    fi
    version_or_absent "awg" awg --version
    version_or_absent "awg-quick" awg-quick --version
    version_or_absent "wg wrapper" /usr/local/bin/wg --version
    version_or_absent "prometheus" prometheus --version
    version_or_absent "grafana-server" grafana-server -v
    version_or_absent "rustc" rustc --version
    version_or_absent "cargo" cargo --version
    if [[ -x "$EXPORTER_BIN" ]]; then
        printf '%-34s %s\n' "prometheus_wireguard_exporter:" "installed at ${EXPORTER_BIN}"
    else
        printf '%-34s %s\n' "prometheus_wireguard_exporter:" "not installed"
    fi
    pkg_version_or_absent prometheus
    pkg_version_or_absent grafana
}

monitoring_status() {
    print_versions
    mon_log "Monitoring services"
    local svc
    for svc in wgexporter awg-persistent-traffic prometheus grafana-server; do
        printf '%-34s %s\n' "${svc}:" "$(service_state "$svc")"
    done
    mon_log "Monitoring files"
    local path
    for path in \
        "$WGEXPORTER_ENV_FILE" \
        "$WGEXPORTER_PEERS_FILE" \
        /etc/sudoers.d/wgexporter \
        /etc/systemd/system/wgexporter.service \
        /etc/systemd/system/awg-persistent-traffic.service \
        /etc/grafana/provisioning/datasources/awg-monitoring-prometheus.yml \
        /etc/grafana/provisioning/dashboards/awg-monitoring.yml \
        /var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json; do
        printf '%-70s %s\n' "$path" "$([[ -e "$path" ]] && printf exists || printf absent)"
    done
}

awg_iface_active() {
    local iface="$1"
    command -v awg >/dev/null 2>&1 || return 1
    awg show "$iface" dump >/dev/null 2>&1
}

resolve_config_for_iface() {
    local iface="$1"
    local candidate="${WG_CONF_DIR}/${iface}.conf"
    [[ -f "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

detect_interfaces() {
    mon_log "Detecting AWG interfaces for monitoring"
    command -v awg >/dev/null 2>&1 || mon_fail "awg command not found. Install/start AmneziaWG first."

    local input="$WG_IFACES_INPUT"
    local iface conf
    local discovered=()
    local active_from_awg=()

    if [[ "$input" == "auto" ]]; then
        if awg show interfaces >/dev/null 2>&1; then
            # shellcheck disable=SC2207
            active_from_awg=($(awg show interfaces 2>/dev/null || true))
        fi

        shopt -s nullglob
        for conf in "${WG_CONF_DIR}"/*.conf; do
            iface="$(basename "$conf" .conf)"
            contains_word "$iface" "${discovered[@]}" && continue
            if awg_iface_active "$iface"; then
                discovered+=("$iface")
            elif bool_yes "$INCLUDE_INACTIVE_IFACES"; then
                mon_warn "$iface has a config but is not active; included because INCLUDE_INACTIVE_IFACES=yes"
                discovered+=("$iface")
            else
                mon_warn "$iface has a config but awg show $iface dump failed; skipped"
            fi
        done
        shopt -u nullglob

        for iface in "${active_from_awg[@]}"; do
            contains_word "$iface" "${discovered[@]}" && continue
            discovered+=("$iface")
        done
    else
        for iface in $(split_words "$input"); do
            [[ -n "$iface" ]] || continue
            contains_word "$iface" "${discovered[@]}" || discovered+=("$iface")
        done
    fi

    [[ "${#discovered[@]}" -gt 0 ]] || mon_fail "No interfaces selected. Use WG_IFACES='awg0 awg1'."

    MONITOR_IFACES=()
    MONITOR_CONFS=()
    for iface in "${discovered[@]}"; do
        if ! awg_iface_active "$iface"; then
            if bool_yes "$INCLUDE_INACTIVE_IFACES"; then
                mon_warn "awg show $iface dump failed, but keeping it because INCLUDE_INACTIVE_IFACES=yes"
            else
                mon_fail "awg show $iface dump failed. Start it first or remove it from WG_IFACES."
            fi
        fi
        MONITOR_IFACES+=("$iface")
        if conf="$(resolve_config_for_iface "$iface")"; then
            MONITOR_CONFS+=("$conf")
        else
            mon_warn "Config not found for $iface: ${WG_CONF_DIR}/${iface}.conf. Friendly names may be absent."
        fi
    done

    [[ "${#MONITOR_CONFS[@]}" -gt 0 ]] || mon_fail "No readable configs found in ${WG_CONF_DIR}; cannot build friendly-name metadata."
    printf 'Interfaces: %s\n' "$(join_by_space "${MONITOR_IFACES[@]}")"
    printf 'Configs:    %s\n' "$(join_by_space "${MONITOR_CONFS[@]}")"
}

install_packages_if_needed() {
    mon_log "Installing/checking base packages"
    detect_os
    is_debian_family || mon_fail "This monitoring installer is currently prepared for Debian/Ubuntu servers."
    apt-get update
    apt-get install -y git curl wget tar adduser sudo libfontconfig1 apt-transport-https gnupg ca-certificates software-properties-common python3 python3-yaml nftables
}

install_rust_if_needed() {
    if command -v cargo >/dev/null 2>&1; then
        printf 'cargo already installed: %s\n' "$(cargo --version 2>/dev/null || true)"
        return 0
    fi
    mon_log "Installing Rust toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
    rustc --version
    cargo --version
}

exporter_has_required_flags() {
    [[ -x "$EXPORTER_BIN" ]] || return 1
    local help
    help="$($EXPORTER_BIN -h 2>&1 || true)"
    grep -q -- '-i' <<<"$help" && grep -q -- '-n' <<<"$help" && grep -q -- '-a' <<<"$help"
}

install_exporter_binary() {
    if exporter_has_required_flags && ! bool_yes "$UPDATE_EXPORTER"; then
        mon_log "prometheus_wireguard_exporter already installed"
        "$EXPORTER_BIN" -h >/dev/null 2>&1 || true
        return 0
    fi

    install_rust_if_needed
    mon_log "Building prometheus_wireguard_exporter"
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
    mkdir -p /usr/local/src
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" fetch --all --tags --prune
        git -C "$SRC_DIR" pull --ff-only || mon_warn "git pull failed; building existing source tree"
    else
        git clone https://github.com/MindFlavor/prometheus_wireguard_exporter.git "$SRC_DIR"
    fi
    (cd "$SRC_DIR" && cargo install --path .)
    backup_mon_file "$EXPORTER_BIN"
    install -m 0755 "$HOME/.cargo/bin/prometheus_wireguard_exporter" "$EXPORTER_BIN"
    exporter_has_required_flags || mon_fail "Installed exporter does not expose required -i/-n/-a flags."
    printf 'Exporter installed: %s\n' "$EXPORTER_BIN"
}

create_exporter_user() {
    mon_log "Creating/checking exporter user"
    if ! getent group "$EXPORTER_USER" >/dev/null; then
        groupadd --system "$EXPORTER_USER"
    fi
    if id "$EXPORTER_USER" >/dev/null 2>&1; then
        printf 'User exists: %s\n' "$EXPORTER_USER"
    else
        useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$EXPORTER_USER" "$EXPORTER_USER"
        printf 'Created user: %s\n' "$EXPORTER_USER"
    fi
    mkdir -p "$WGEXPORTER_DIR" "$WGEXPORTER_STATE_DIR"
    chown root:"$EXPORTER_USER" "$WGEXPORTER_DIR"
    chmod 0750 "$WGEXPORTER_DIR"
    chown "$EXPORTER_USER":"$EXPORTER_USER" "$WGEXPORTER_STATE_DIR"
    chmod 0750 "$WGEXPORTER_STATE_DIR"
}

install_support_scripts() {
    mon_log "Installing monitoring support scripts"
    [[ -f "$MONITORING_DIR/src/awg_exporter_sync_peers.py" ]] || mon_fail "Missing awg_exporter_sync_peers.py"
    [[ -f "$MONITORING_DIR/src/awg_persistent_traffic_exporter.py" ]] || mon_fail "Missing awg_persistent_traffic_exporter.py"
    [[ -f "$MONITORING_DIR/src/check_awg_monitoring.sh" ]] || mon_fail "Missing check_awg_monitoring.sh"

    backup_mon_file /usr/local/sbin/awg-exporter-sync-peers
    backup_mon_file /usr/local/sbin/awg-persistent-traffic-exporter
    backup_mon_file /usr/local/sbin/check-awg-monitoring
    install -m 0755 "$MONITORING_DIR/src/awg_exporter_sync_peers.py" /usr/local/sbin/awg-exporter-sync-peers
    install -m 0755 "$MONITORING_DIR/src/awg_persistent_traffic_exporter.py" /usr/local/sbin/awg-persistent-traffic-exporter
    install -m 0755 "$MONITORING_DIR/src/check_awg_monitoring.sh" /usr/local/sbin/check-awg-monitoring

    backup_mon_file "$WGEXPORTER_ENV_FILE"
    cat >"$WGEXPORTER_ENV_FILE" <<ENV_EOF
WG_IFACES="$(join_by_space "${MONITOR_IFACES[@]}")"
WG_CONF_DIR="${WG_CONF_DIR}"
EXPORTER_USER="${EXPORTER_USER}"
EXPORTER_PORT="${EXPORTER_PORT}"
PERSISTENT_EXPORTER_PORT="${PERSISTENT_EXPORTER_PORT}"
PROMETHEUS_PORT="${PROMETHEUS_PORT}"
GRAFANA_PORT="${GRAFANA_PORT}"
WGEXPORTER_PEERS_FILE="${WGEXPORTER_PEERS_FILE}"
WGEXPORTER_STATE_DIR="${WGEXPORTER_STATE_DIR}"
EXPORTER_INTERFACE_MODE="${EXPORTER_INTERFACE_MODE}"
ENV_EOF
    chown root:"$EXPORTER_USER" "$WGEXPORTER_ENV_FILE"
    chmod 0640 "$WGEXPORTER_ENV_FILE"

    /usr/bin/python3 /usr/local/sbin/awg-exporter-sync-peers \
        --output "$WGEXPORTER_PEERS_FILE" \
        --owner "root:${EXPORTER_USER}" \
        --mode 0640 \
        --configs "${MONITOR_CONFS[@]}"
}

install_awg_wrapper() {
    mon_log "Installing /usr/local/bin/wg wrapper"
    local wrapper=/usr/local/bin/wg
    if [[ -e "$wrapper" || -L "$wrapper" ]]; then
        if ! grep -q 'AWG_PROMETHEUS_EXPORTER_WRAPPER' "$wrapper" 2>/dev/null; then
            backup_mon_file "$wrapper"
        fi
    fi
    cat >"$wrapper" <<'WRAPPER_EOF'
#!/bin/sh
# AWG_PROMETHEUS_EXPORTER_WRAPPER
# prometheus_wireguard_exporter calls either:
#   wg show all dump
# or:
#   wg show <interface> dump
# On AmneziaWG servers we translate these calls to awg.
AWG_BIN="${AWG_BIN:-/usr/bin/awg}"
ENV_FILE="${WGEXPORTER_ENV_FILE:-/etc/wgexporter/monitoring.env}"
if [ ! -x "$AWG_BIN" ]; then
  AWG_BIN="$(command -v awg 2>/dev/null || true)"
fi
if [ -z "$AWG_BIN" ]; then
  echo "awg binary not found" >&2
  exit 127
fi
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
fi
IFACES="${WG_IFACES:-}"
if [ -z "$IFACES" ]; then
  IFACES="$($AWG_BIN show interfaces 2>/dev/null || true)"
fi
if [ -z "$IFACES" ]; then
  for conf in /etc/amnezia/amneziawg/*.conf; do
    [ -e "$conf" ] || continue
    base="$(basename "$conf" .conf)"
    IFACES="$IFACES $base"
  done
fi

if [ "${1:-}" = "show" ] && [ "${2:-}" = "interfaces" ] && [ "$#" -eq 2 ]; then
  printf '%s\n' $IFACES
  exit 0
fi

if [ "${1:-}" = "show" ] && [ "${2:-}" = "all" ] && [ "${3:-}" = "dump" ] && [ "$#" -eq 3 ]; then
  for iface in $IFACES; do
    "$AWG_BIN" show "$iface" dump 2>/dev/null | awk -v iface="$iface" 'NF { print iface "\t" $0 }'
  done
  exit 0
fi

if [ "${1:-}" = "show" ] && [ "${3:-}" = "dump" ] && [ "$#" -eq 3 ]; then
  exec "$AWG_BIN" show "$2" dump
fi

exec "$AWG_BIN" "$@"
WRAPPER_EOF
    chmod 0755 "$wrapper"
    local iface
    for iface in "${MONITOR_IFACES[@]}"; do
        "$wrapper" show "$iface" dump >/dev/null
    done
    "$wrapper" show all dump >/dev/null
}

install_sudoers_rule() {
    mon_log "Installing sudoers rule for exporter"
    local sudoers=/etc/sudoers.d/wgexporter
    backup_mon_file "$sudoers"
    {
        echo "Defaults:${EXPORTER_USER} !requiretty"
        echo "Defaults:${EXPORTER_USER} secure_path=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
        printf '%s ALL=(root) NOPASSWD: /usr/local/bin/wg show all dump' "$EXPORTER_USER"
        local iface
        for iface in "${MONITOR_IFACES[@]}"; do
            printf ', /usr/local/bin/wg show %s dump' "$iface"
        done
        printf '\n'
    } >"$sudoers"
    chmod 0440 "$sudoers"
    visudo -cf "$sudoers"
    sudo -u "$EXPORTER_USER" sudo -n /usr/local/bin/wg show all dump >/dev/null
    local iface
    for iface in "${MONITOR_IFACES[@]}"; do
        sudo -u "$EXPORTER_USER" sudo -n /usr/local/bin/wg show "$iface" dump >/dev/null
    done
}

install_exporter_service() {
    mon_log "Installing raw exporter systemd service"
    local iface_args="" iface config_args="" conf
    if [[ "$EXPORTER_INTERFACE_MODE" == "explicit" ]]; then
        # Some old/current exporter builds reject repeated -i; pass one -i followed by all interfaces.
        iface_args=" -i"
        for iface in "${MONITOR_IFACES[@]}"; do
            iface_args+=" ${iface}"
        done
    elif [[ "$EXPORTER_INTERFACE_MODE" == "all" ]]; then
        # Default: no -i. The exporter asks wg show all dump, and our wrapper expands all selected AWG interfaces.
        iface_args=""
    else
        mon_fail "Unsupported EXPORTER_INTERFACE_MODE=${EXPORTER_INTERFACE_MODE}; use all or explicit"
    fi
    for conf in "${MONITOR_CONFS[@]}"; do
        config_args+=" ${conf}"
    done
    backup_mon_file /etc/systemd/system/wgexporter.service
    cat >/etc/systemd/system/wgexporter.service <<SERVICE_EOF
[Unit]
Description=Prometheus WireGuard Exporter for AmneziaWG
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${EXPORTER_USER}
Group=${EXPORTER_USER}
Environment="PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStartPre=+/usr/bin/python3 /usr/local/sbin/awg-exporter-sync-peers --output ${WGEXPORTER_PEERS_FILE} --owner root:${EXPORTER_USER} --mode 0640 --configs${config_args}
ExecStart=${EXPORTER_BIN} -a true -l 127.0.0.1 -p ${EXPORTER_PORT} -d true -n ${WGEXPORTER_PEERS_FILE}${iface_args}
Restart=on-failure
RestartSec=5
PrivateTmp=yes
ProtectHome=yes
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    systemctl daemon-reload
    systemctl enable --now wgexporter
    systemctl restart wgexporter
    sleep 2
    systemctl status wgexporter --no-pager || true
}

install_persistent_exporter_service() {
    bool_yes "$INSTALL_PERSISTENT_EXPORTER" || { mon_warn "Skipping persistent traffic exporter"; return 0; }
    mon_log "Installing persistent traffic exporter service"
    backup_mon_file /etc/systemd/system/awg-persistent-traffic.service
    cat >/etc/systemd/system/awg-persistent-traffic.service <<SERVICE_EOF
[Unit]
Description=Persistent AmneziaWG traffic counters exporter
After=network-online.target wgexporter.service
Wants=network-online.target
Requires=wgexporter.service

[Service]
Type=simple
User=${EXPORTER_USER}
Group=${EXPORTER_USER}
Environment=AWG_TRAFFIC_SOURCE_URL=http://127.0.0.1:${EXPORTER_PORT}/metrics
Environment=AWG_TRAFFIC_STATE_FILE=${WGEXPORTER_STATE_DIR}/traffic_totals.json
ExecStart=/usr/bin/python3 /usr/local/sbin/awg-persistent-traffic-exporter --listen 127.0.0.1 --port ${PERSISTENT_EXPORTER_PORT}
Restart=on-failure
RestartSec=5
PrivateTmp=yes
ProtectHome=yes
ReadWritePaths=${WGEXPORTER_STATE_DIR}

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    systemctl daemon-reload
    systemctl enable --now awg-persistent-traffic
    systemctl restart awg-persistent-traffic
    sleep 2
    systemctl status awg-persistent-traffic --no-pager || true
}

configure_prometheus_defaults() {
    [[ -f /etc/default/prometheus ]] || return 0
    backup_mon_file /etc/default/prometheus
    PROMETHEUS_PORT="$PROMETHEUS_PORT" PROMETHEUS_RETENTION_TIME="$PROMETHEUS_RETENTION_TIME" PROMETHEUS_BIND_LOCALHOST="$PROMETHEUS_BIND_LOCALHOST" /usr/bin/python3 - <<'PY'
from pathlib import Path
import os, shlex
path = Path('/etc/default/prometheus')
text = path.read_text(encoding='utf-8', errors='replace').splitlines()
port = os.environ['PROMETHEUS_PORT']
retention = os.environ['PROMETHEUS_RETENTION_TIME']
bind_localhost = os.environ.get('PROMETHEUS_BIND_LOCALHOST', 'yes').lower() in {'yes','y','1','true'}
out = []
found = False
for line in text:
    if line.startswith('ARGS='):
        found = True
        raw = line.split('=', 1)[1].strip()
        try:
            args = shlex.split(raw)
        except ValueError:
            args = raw.strip('"').split()
        args = [a for a in args if not a.startswith('--storage.tsdb.retention.time=')]
        if bind_localhost:
            args = [a for a in args if not a.startswith('--web.listen-address=')]
            args.append(f'--web.listen-address=127.0.0.1:{port}')
        args.append(f'--storage.tsdb.retention.time={retention}')
        out.append('ARGS=' + shlex.quote(' '.join(args)))
    else:
        out.append(line)
if not found:
    args = []
    if bind_localhost:
        args.append(f'--web.listen-address=127.0.0.1:{port}')
    args.append(f'--storage.tsdb.retention.time={retention}')
    out.append('ARGS=' + shlex.quote(' '.join(args)))
path.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY
}

patch_prometheus_config() {
    local conf=/etc/prometheus/prometheus.yml
    local tmp
    backup_mon_file "$conf"
    tmp="$(mktemp /tmp/prometheus.yml.XXXXXX)"
    PROMETHEUS_CONF="$conf" PROMETHEUS_TMP="$tmp" EXPORTER_PORT="$EXPORTER_PORT" PERSISTENT_EXPORTER_PORT="$PERSISTENT_EXPORTER_PORT" /usr/bin/python3 - <<'PY'
from pathlib import Path
import os, sys
try:
    import yaml
except Exception as exc:
    print(f'python3-yaml is required: {exc}', file=sys.stderr)
    raise
conf = Path(os.environ['PROMETHEUS_CONF'])
tmp = Path(os.environ['PROMETHEUS_TMP'])
exporter_port = os.environ['EXPORTER_PORT']
persistent_port = os.environ['PERSISTENT_EXPORTER_PORT']
managed_names = {'awg_wgexporter_raw', 'wgexporter_raw', 'wgexporter', 'awg_persistent_traffic'}
if conf.exists():
    data = yaml.safe_load(conf.read_text(encoding='utf-8', errors='replace'))
else:
    data = None
if data is None:
    data = {}
if not isinstance(data, dict):
    raise SystemExit('Prometheus config root is not a mapping')
if 'global' not in data or data['global'] is None:
    data['global'] = {'scrape_interval': '15s', 'evaluation_interval': '15s'}
scrapes = data.get('scrape_configs') or []
if not isinstance(scrapes, list):
    raise SystemExit('scrape_configs is not a list')
filtered = []
for job in scrapes:
    if isinstance(job, dict) and job.get('job_name') in managed_names:
        continue
    filtered.append(job)
filtered.append({
    'job_name': 'awg_wgexporter_raw',
    'static_configs': [{'targets': [f'127.0.0.1:{exporter_port}']}],
})
filtered.append({
    'job_name': 'awg_persistent_traffic',
    'static_configs': [{'targets': [f'127.0.0.1:{persistent_port}']}],
})
data['scrape_configs'] = filtered
tmp.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True), encoding='utf-8')
PY
    if command -v promtool >/dev/null 2>&1; then
        promtool check config "$tmp"
    fi
    install -m 0644 "$tmp" "$conf"
    rm -f "$tmp"
}

install_prometheus() {
    bool_yes "$INSTALL_PROMETHEUS" || { mon_warn "Skipping Prometheus install/configuration"; return 0; }
    mon_log "Installing/configuring Prometheus"
    if command -v prometheus >/dev/null 2>&1; then
        prometheus --version 2>&1 | head -n1 || true
    else
        apt-get install -y prometheus
    fi
    patch_prometheus_config
    configure_prometheus_defaults
    systemctl enable --now prometheus
    systemctl restart prometheus
    sleep 2
    curl -fsS "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy" >/dev/null
}

install_grafana_package_if_needed() {
    if command -v grafana-server >/dev/null 2>&1; then
        grafana-server -v 2>/dev/null | head -n1 || true
        GRAFANA_INSTALLED_BY_SCRIPT="no"
        return 0
    fi
    mon_log "Installing Grafana from official APT repository"
    apt-get install -y apt-transport-https wget gnupg
    mkdir -p /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/grafana.asc ]]; then
        wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
        chmod 0644 /etc/apt/keyrings/grafana.asc
    fi
    echo 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' >/etc/apt/sources.list.d/grafana.list
    apt-get update
    apt-get install -y grafana
    GRAFANA_INSTALLED_BY_SCRIPT="yes"
}

patch_grafana_ini() {
    local ini=/etc/grafana/grafana.ini
    [[ -f "$ini" ]] || return 0
    if [[ "$GRAFANA_INSTALLED_BY_SCRIPT" != "yes" ]] && ! bool_yes "$MANAGE_EXISTING_GRAFANA_INI"; then
        mon_warn "Existing Grafana detected; grafana.ini preserved. Set MANAGE_EXISTING_GRAFANA_INI=yes to patch bind/port."
        return 0
    fi
    backup_mon_file "$ini"
    GRAFANA_PORT="$GRAFANA_PORT" GRAFANA_HTTP_ADDR="$GRAFANA_HTTP_ADDR" /usr/bin/python3 - <<'PY'
from pathlib import Path
import os
path = Path('/etc/grafana/grafana.ini')
text = path.read_text(encoding='utf-8', errors='replace').splitlines()
port = os.environ['GRAFANA_PORT']
addr = os.environ['GRAFANA_HTTP_ADDR']
sections = {'server': {'http_addr': addr, 'http_port': port}, 'users': {'allow_sign_up': 'false'}}
out = []
current = None
seen = {section: set() for section in sections}
existing = set()
def close(section):
    if section in sections:
        for key, value in sections[section].items():
            if key not in seen[section]:
                out.append(f'{key} = {value}')
                seen[section].add(key)
for line in text:
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        close(current)
        current = stripped.strip('[]').strip()
        existing.add(current)
        out.append(line)
        continue
    if current in sections:
        raw = stripped.lstrip(';#')
        key = raw.split('=', 1)[0].strip() if '=' in raw else raw.strip()
        if key in sections[current]:
            out.append(f'{key} = {sections[current][key]}')
            seen[current].add(key)
            continue
    out.append(line)
close(current)
for section, values in sections.items():
    if section not in existing:
        out.append('')
        out.append(f'[{section}]')
        for key, value in values.items():
            out.append(f'{key} = {value}')
path.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY
}

provision_grafana() {
    mon_log "Provisioning Grafana datasource and traffic dashboard"
    mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards/awg-managed
    backup_mon_file /etc/grafana/provisioning/datasources/awg-monitoring-prometheus.yml
    backup_mon_file /etc/grafana/provisioning/dashboards/awg-monitoring.yml
    cat >/etc/grafana/provisioning/datasources/awg-monitoring-prometheus.yml <<DS_EOF
apiVersion: 1

datasources:
  - name: AWG Prometheus
    uid: awg-prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:${PROMETHEUS_PORT}
    isDefault: false
    editable: true
    version: 2
DS_EOF
    cat >/etc/grafana/provisioning/dashboards/awg-monitoring.yml <<DASH_EOF
apiVersion: 1

providers:
  - name: 'AmneziaWG managed monitoring'
    orgId: 1
    folder: 'AmneziaWG'
    type: file
    disableDeletion: true
    allowUiUpdates: true
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards/awg-managed
DASH_EOF
    [[ -f "$MONITORING_DIR/grafana/awg-traffic-by-client-dashboard.json" ]] || mon_fail "Dashboard JSON is missing"
    backup_mon_file /var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json
    install -m 0644 "$MONITORING_DIR/grafana/awg-traffic-by-client-dashboard.json" /var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json
    if id grafana >/dev/null 2>&1; then
        chown -R grafana:grafana /var/lib/grafana/dashboards/awg-managed
    fi
}

install_grafana() {
    bool_yes "$INSTALL_GRAFANA" || { mon_warn "Skipping Grafana install/provisioning"; return 0; }
    install_grafana_package_if_needed
    patch_grafana_ini
    provision_grafana
    systemctl enable --now grafana-server
    systemctl restart grafana-server
    sleep 3
    systemctl status grafana-server --no-pager || true
}

delete_nft_rules_by_comment() {
    local chain="$1" marker="$2" handles handle
    handles="$(nft -a list chain inet filter "$chain" 2>/dev/null | awk -v marker="$marker" '$0 ~ marker {print $NF}' || true)"
    for handle in $handles; do
        nft delete rule inet filter "$chain" handle "$handle" 2>/dev/null || true
    done
}

configure_nftables() {
    bool_yes "$CONFIGURE_NFTABLES" || { mon_warn "Skipping nftables configuration"; return 0; }
    mon_log "Configuring nftables guard for Grafana"
    systemctl enable --now nftables || true
    backup_mon_file /etc/nftables.conf
    backup_runtime_nftables
    if ! nft list table inet filter >/dev/null 2>&1; then
        mon_warn "inet filter table not found; creating with policy accept to avoid accidental SSH lockout"
        nft add table inet filter
    fi
    if ! nft list chain inet filter input >/dev/null 2>&1; then
        mon_warn "inet filter input chain not found; creating with policy accept"
        nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
    fi
    delete_nft_rules_by_comment input 'awg-monitoring-grafana'
    nft insert rule inet filter input tcp dport "$GRAFANA_PORT" drop comment 'awg-monitoring-grafana-drop'
    nft insert rule inet filter input iifname lo tcp dport "$GRAFANA_PORT" accept comment 'awg-monitoring-grafana-loopback'
    local idx iface
    for (( idx=${#MONITOR_IFACES[@]}-1; idx>=0; idx-- )); do
        iface="${MONITOR_IFACES[$idx]}"
        nft insert rule inet filter input iifname "$iface" tcp dport "$GRAFANA_PORT" accept comment "awg-monitoring-grafana-allow-${iface}"
    done
    nft list ruleset >/etc/nftables.conf
    nft -c -f /etc/nftables.conf
    systemctl restart nftables || true
}

final_checks() {
    mon_log "Final checks"
    systemctl is-active --quiet wgexporter && echo 'wgexporter: OK' || echo 'wgexporter: FAIL'
    if bool_yes "$INSTALL_PERSISTENT_EXPORTER"; then
        systemctl is-active --quiet awg-persistent-traffic && echo 'awg-persistent-traffic: OK' || echo 'awg-persistent-traffic: FAIL'
    fi
    if bool_yes "$INSTALL_PROMETHEUS"; then
        systemctl is-active --quiet prometheus && echo 'prometheus: OK' || echo 'prometheus: FAIL'
    fi
    if bool_yes "$INSTALL_GRAFANA"; then
        systemctl is-active --quiet grafana-server && echo 'grafana-server: OK' || echo 'grafana-server: FAIL'
    fi
    curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" | grep -q '^wireguard_received_bytes_total' \
        && echo 'Raw exporter metrics: OK' || echo 'Raw exporter metrics: FAIL'
    if bool_yes "$INSTALL_PERSISTENT_EXPORTER"; then
        curl -fsS "http://127.0.0.1:${PERSISTENT_EXPORTER_PORT}/metrics" | grep -q '^awg_persistent_traffic_scrape_success' \
            && echo 'Persistent exporter endpoint: OK' || echo 'Persistent exporter endpoint: FAIL'
    fi
    echo "Diagnostics: sudo /usr/local/sbin/check-awg-monitoring"
    echo "Grafana dashboard: folder AmneziaWG, dashboard AWG traffic by client"
    echo "Backups: ${AWG_MONITORING_BACKUP_DIR:-none created}"
}

main() {
    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --status) monitoring_status; exit 0 ;;
    esac
    require_root
    ensure_startup_full_backup "script-start-monitoring"
    print_versions
    detect_interfaces
    install_packages_if_needed
    install_exporter_binary
    create_exporter_user
    install_support_scripts
    install_awg_wrapper
    install_sudoers_rule
    install_exporter_service
    install_persistent_exporter_service
    install_prometheus
    install_grafana
    configure_nftables
    final_checks
}

main "$@"
