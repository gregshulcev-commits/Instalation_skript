#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

ROLLBACK_ON_RESTART_FAIL="${ROLLBACK_ON_RESTART_FAIL:-yes}"

usage() {
    cat <<'EOF_USAGE'
08_remove_client.sh <client_name> [interface]

Удаляет клиента из выбранного server.conf и удаляет его client.conf.
Перед изменениями создаёт timestamp backup с MANIFEST.tsv, поэтому состояние можно вернуть через 10_restore_backup.sh.

Что удаляется:
  - [Peer]-блок, где есть `# friendly_name=<client_name>`;
  - legacy-блок с маркером `### Client <client_name>`;
  - файл client.conf из папки clients интерфейса, если он найден.

Переменные:
  ROLLBACK_ON_RESTART_FAIL=yes|no  - откатить удаление, если restart awg-quick@iface не удался. По умолчанию yes.
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

remove_peer_from_server_conf() {
    local conf="$1"
    local client_name="$2"
    local tmp
    tmp="$(mktemp "${conf}.tmp.XXXXXX")"
    python3 -S - "$conf" "$tmp" "$client_name" <<'PY'
import sys
from pathlib import Path

src, dst, name = sys.argv[1:]
lines = Path(src).read_text().splitlines(True)
remove = [False] * len(lines)
removed = 0
peer_starts = [i for i, line in enumerate(lines) if line.strip() == '[Peer]']
peer_starts.append(len(lines))
for pos in range(len(peer_starts) - 1):
    start = peer_starts[pos]
    end = peer_starts[pos + 1]
    check_start = start
    if start > 0 and lines[start - 1].strip() == f'### Client {name}':
        check_start = start - 1
    block = ''.join(lines[check_start:end])
    markers = [f'# friendly_name={name}', f'### Client {name}']
    if any(marker in block for marker in markers):
        # Also remove one blank line immediately before the block for neatness.
        if check_start > 0 and lines[check_start - 1].strip() == '':
            check_start -= 1
        for i in range(check_start, end):
            remove[i] = True
        removed += 1

if removed == 0:
    print(f'client peer not found: {name}', file=sys.stderr)
    sys.exit(3)

out = ''.join(line for i, line in enumerate(lines) if not remove[i])
Path(dst).write_text(out.rstrip() + '\n')
print(removed)
PY
    mv -f -- "$tmp" "$conf"
}

main() {
    local client_name requested_if selected_if vpn_if server_conf clients_dir service_name client_conf_file backup_dir removed_count restart_ok

    require_root
    client_name="${1:-}"
    if [[ -z "$client_name" ]]; then
        client_name="$(prompt_default "Имя удаляемого клиента" "client1")"
    fi
    validate_client_name "$client_name"

    requested_if="${2:-${VPN_IF_OVERRIDE:-}}"
    selected_if="$(select_iface_interactive "$requested_if")"
    load_manager_env_for_iface "$selected_if"

    vpn_if="${VPN_IF:-$selected_if}"
    server_conf="${SERVER_CONF:-$(server_conf_for_iface "$vpn_if")}"
    clients_dir="${CLIENTS_DIR:-$(clients_dir_for_iface "$vpn_if")}"
    service_name="${SERVICE_NAME:-awg-quick@${vpn_if}.service}"
    client_conf_file="${clients_dir}/${client_name}.conf"

    [[ -f "$server_conf" ]] || die "Не найден server.conf: $server_conf"
    client_exists_in_conf "$server_conf" "$client_name" || die "Клиент ${client_name} не найден в ${server_conf}"

    begin_safe_operation "remove-client-${vpn_if}-${client_name}" >/dev/null
    backup_dir="$AWG_ACTIVE_BACKUP_DIR"
    warn "Backup/rollback папка операции: $backup_dir"
    operation_backup_path "$server_conf" >/dev/null
    [[ -e "$client_conf_file" ]] && operation_backup_path "$client_conf_file" >/dev/null

    removed_count="$(remove_peer_from_server_conf "$server_conf" "$client_name")"
    rm -f -- "$client_conf_file"

    restart_ok="yes"
    if ! systemctl restart "$service_name"; then
        restart_ok="no"
        warn "Не удалось перезапустить ${service_name}."
        if [[ "$(normalise_yes_no "$ROLLBACK_ON_RESTART_FAIL" 2>/dev/null || printf yes)" == "yes" ]]; then
            rollback_safe_operation 1
            AWG_OPERATION_COMMITTED="yes"
            trap - EXIT INT TERM
            systemctl restart "$service_name" >/dev/null 2>&1 || true
            die "Удаление клиента ${client_name} откачено из backup: $backup_dir"
        fi
    fi

    commit_safe_operation
    ok "Клиент удалён: ${client_name}"
    ok "Интерфейс: ${vpn_if}"
    ok "Удалено peer-блоков: ${removed_count}"
    [[ -e "$client_conf_file" ]] || ok "Клиентский конфиг удалён/отсутствует: ${client_conf_file}"
    [[ "$restart_ok" == "yes" ]] && ok "Сервис перезапущен: ${service_name}"
    ok "Backup папка: $backup_dir"
    printf '\nДля полного ручного отката: sudo %s/10_restore_backup.sh %s\n' "$SCRIPT_DIR" "$backup_dir"
}

main "$@"
