#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

ROLLBACK_ON_RESTART_FAIL="${ROLLBACK_ON_RESTART_FAIL:-yes}"

usage() {
    cat <<'EOF_USAGE'
08_remove_client.sh [client_name|--interactive|--public-key <public_key>] [interface]

Удаляет клиента из выбранного server.conf и удаляет его client.conf, если он найден.
Перед изменениями создаётся timestamp backup с MANIFEST.tsv, поэтому состояние можно вернуть через 10_restore_backup.sh.

Рекомендуемый интерактивный режим:
  sudo ./scripts/08_remove_client.sh --interactive

Что удаляется:
  - выбранный [Peer]-блок;
  - legacy-блок с маркером `### Client <name>`, если он относится к выбранному peer;
  - файл client.conf из папки clients интерфейса, если имя клиента известно.

Переменные:
  ROLLBACK_ON_RESTART_FAIL=yes|no  - откатить удаление, если restart awg-quick@iface не удался. По умолчанию yes.
EOF_USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

remove_peer_from_server_conf() {
    local conf="$1"
    local mode="$2"
    local value="$3"
    local tmp
    tmp="$(mktemp "${conf}.tmp.XXXXXX")"
    python3 -S - "$conf" "$tmp" "$mode" "$value" <<'PY'
import re
import sys
from pathlib import Path

src, dst, mode, value = sys.argv[1:]
lines = Path(src).read_text(encoding='utf-8', errors='replace').splitlines(True)
remove = [False] * len(lines)
removed = 0
peer_starts = [i for i, line in enumerate(lines) if line.strip() == '[Peer]']
peer_starts.append(len(lines))

def block_matches(block: str) -> bool:
    if mode == 'public_key':
        for line in block.splitlines():
            m = re.match(r'^\s*PublicKey\s*=\s*(.+?)\s*$', line)
            if m and m.group(1).strip() == value:
                return True
        return False
    if mode == 'name':
        for line in block.splitlines():
            stripped = line.strip()
            m = re.match(r'^#\s*friendly_name\s*=\s*(.+?)\s*$', stripped)
            if m and m.group(1).strip() == value:
                return True
            m = re.match(r'^###\s*Client\s+(.+?)\s*$', stripped)
            if m and m.group(1).strip() == value:
                return True
        return False
    raise SystemExit(f'unknown mode: {mode}')

for pos in range(len(peer_starts) - 1):
    start = peer_starts[pos]
    end = peer_starts[pos + 1]
    check_start = start
    if start > 0 and re.match(r'^\s*###\s*Client\s+', lines[start - 1].strip()):
        check_start = start - 1
    block = ''.join(lines[check_start:end])
    if block_matches(block):
        if check_start > 0 and lines[check_start - 1].strip() == '':
            check_start -= 1
        for i in range(check_start, end):
            remove[i] = True
        removed += 1
        if mode == 'public_key':
            break

if removed == 0:
    print(f'client peer not found by {mode}: {value}', file=sys.stderr)
    sys.exit(3)

out = ''.join(line for i, line in enumerate(lines) if not remove[i])
Path(dst).write_text(out.rstrip() + '\n', encoding='utf-8')
print(removed)
PY
    mv -f -- "$tmp" "$conf"
}

main() {
    local selector_mode selector_value requested_if selected_if vpn_if server_conf clients_dir service_name client_name public_key allowed_ips selected_line idx
    local client_conf_file backup_dir removed_count restart_ok arg1

    require_root
    ensure_startup_full_backup "script-start-remove-client"

    arg1="${1:-}"
    selector_mode="name"
    selector_value="${arg1}"

    if [[ -z "$arg1" || "$arg1" == "--interactive" ]]; then
        selector_mode="interactive"
        selector_value=""
        requested_if="${2:-${VPN_IF_OVERRIDE:-}}"
    elif [[ "$arg1" == "--public-key" ]]; then
        selector_mode="public_key"
        selector_value="${2:-}"
        [[ -n "$selector_value" ]] || die "После --public-key нужно указать публичный ключ клиента"
        requested_if="${3:-${VPN_IF_OVERRIDE:-}}"
    else
        validate_client_name "$selector_value"
        requested_if="${2:-${VPN_IF_OVERRIDE:-}}"
    fi

    selected_if="$(select_iface_interactive "$requested_if")"
    load_manager_env_for_iface "$selected_if"

    vpn_if="${VPN_IF:-$selected_if}"
    server_conf="${SERVER_CONF:-$(server_conf_for_iface "$vpn_if")}"
    clients_dir="${CLIENTS_DIR:-$(clients_dir_for_iface "$vpn_if")}"
    service_name="${SERVICE_NAME:-awg-quick@${vpn_if}.service}"

    [[ -f "$server_conf" ]] || die "Не найден server.conf: $server_conf"

    client_name=""
    public_key=""
    allowed_ips=""
    if [[ "$selector_mode" == "interactive" ]]; then
        selected_line="$(select_client_interactive "$vpn_if")"
        IFS=$'\t' read -r idx client_name public_key allowed_ips <<<"$selected_line"
        [[ -n "$public_key" ]] || die "У выбранного клиента нет PublicKey в ${server_conf}; удаление по номеру небезопасно"
        selector_mode="public_key"
        selector_value="$public_key"
        ok "Выбран клиент #${idx}: ${client_name} (${allowed_ips:-без AllowedIPs})"
    elif [[ "$selector_mode" == "name" ]]; then
        client_name="$selector_value"
        client_exists_in_conf "$server_conf" "$client_name" || die "Клиент ${client_name} не найден в ${server_conf}"
    else
        public_key="$selector_value"
        client_name="$(list_clients_for_iface_tsv "$vpn_if" | awk -F '\t' -v key="$public_key" '$3 == key {print $2; exit}')"
        [[ -n "$client_name" ]] || client_name="unknown-public-key"
    fi

    client_conf_file=""
    if [[ -n "$client_name" && "$client_name" != "unknown-public-key" ]]; then
        client_conf_file="${clients_dir}/${client_name}.conf"
    fi

    begin_safe_operation "remove-client-${vpn_if}-${client_name:-by-public-key}" >/dev/null
    backup_dir="$AWG_ACTIVE_BACKUP_DIR"
    warn "Backup/rollback папка операции: $backup_dir"
    operation_backup_path "$server_conf" >/dev/null
    [[ -n "$client_conf_file" && -e "$client_conf_file" ]] && operation_backup_path "$client_conf_file" >/dev/null

    removed_count="$(remove_peer_from_server_conf "$server_conf" "$selector_mode" "$selector_value")"
    [[ -n "$client_conf_file" ]] && rm -f -- "$client_conf_file"

    restart_ok="yes"
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl restart "$service_name"; then
            restart_ok="no"
            warn "Не удалось перезапустить ${service_name}."
            if [[ "$(normalise_yes_no "$ROLLBACK_ON_RESTART_FAIL" 2>/dev/null || printf yes)" == "yes" ]]; then
                rollback_safe_operation 1
                AWG_OPERATION_COMMITTED="yes"
                trap - EXIT INT TERM
                systemctl restart "$service_name" >/dev/null 2>&1 || true
                die "Удаление клиента ${client_name:-$selector_value} откачено из backup: $backup_dir"
            fi
        fi
    else
        warn "systemctl не найден; restart ${service_name} пропущен"
    fi

    commit_safe_operation
    ok "Клиент удалён: ${client_name:-$selector_value}"
    ok "Интерфейс: ${vpn_if}"
    ok "Удалено peer-блоков: ${removed_count}"
    [[ -z "$client_conf_file" || ! -e "$client_conf_file" ]] && ok "Клиентский конфиг удалён/отсутствует: ${client_conf_file:-не определён}"
    [[ "$restart_ok" == "yes" ]] && ok "Сервис перезапущен: ${service_name}"
    ok "Backup папка операции: $backup_dir"
    ok "Full backup запуска: ${AWG_STARTUP_BACKUP_DIR:-создан ранее}"
    printf '\nДля полного ручного отката операции: sudo %s/10_restore_backup.sh %s\n' "$SCRIPT_DIR" "$backup_dir"
}

main "$@"
