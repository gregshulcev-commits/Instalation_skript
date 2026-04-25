#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

CONFIRM_REMOVE="${CONFIRM_REMOVE:-ask}"          # yes|no|ask
SKIP_FIREWALL_UPDATE="${SKIP_FIREWALL_UPDATE:-no}"
NFT_SAVE_CHANGES="${NFT_SAVE_CHANGES:-yes}"
NFT_APPLY_NOW="${NFT_APPLY_NOW:-ask}"

usage() {
    cat <<'EOF_USAGE'
09_remove_interface.sh [interface]

Удаляет интерфейс AmneziaWG и чистит связанные файлы:
  - останавливает и отключает awg-quick@<iface>.service;
  - удаляет /etc/amnezia/amneziawg/<iface>.conf;
  - удаляет manager-<iface>.env;
  - удаляет clients/keys папки интерфейса;
  - пересобирает nftables/NAT через 03_setup_nftables.sh, чтобы убрать UDP allow и masquerade удалённого интерфейса;
  - все изменяемые файлы складываются в одну timestamp backup папку с MANIFEST.tsv.

Переменные:
  CONFIRM_REMOVE=yes|no|ask      - подтверждение удаления. По умолчанию ask.
  SKIP_FIREWALL_UPDATE=yes       - не трогать nftables после удаления файлов.
  NFT_SAVE_CHANGES=yes|no|ask    - передаётся в 03_setup_nftables.sh. По умолчанию yes.
  NFT_APPLY_NOW=yes|no|ask       - применять nftables сразу или только сохранить файл. По умолчанию ask.
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

confirm_env_local() {
    local value="$1" question="$2" default="$3"
    case "$value" in
        yes|Y|y|1|true) return 0 ;;
        no|N|n|0|false) return 1 ;;
        ask|"") confirm "$question" "$default" ;;
        *) warn "Неизвестное значение ${value}; спрашиваю интерактивно"; confirm "$question" "$default" ;;
    esac
}

rewrite_manager_pointer_after_delete() {
    local deleted_if="$1"
    local next_if next_env
    next_if="$(list_awg_interfaces_from_confs | grep -vxF "$deleted_if" | head -n1 || true)"
    if [[ -n "$next_if" ]]; then
        next_env="$(manager_env_for_iface "$next_if")"
        if [[ -f "$next_env" ]]; then
            [[ -e "$MANAGER_ENV_FILE" ]] && operation_backup_path "$MANAGER_ENV_FILE" >/dev/null
            cat "$next_env" | replace_file_from_stdin "$MANAGER_ENV_FILE" 600 "${AWG_ACTIVE_BACKUP_DIR:-}"
            ok "manager.env переключён на оставшийся интерфейс: $next_if"
            return 0
        fi
    fi
    if [[ -e "$MANAGER_ENV_FILE" ]]; then
        operation_backup_path "$MANAGER_ENV_FILE" >/dev/null
        rm -f -- "$MANAGER_ENV_FILE"
        ok "manager.env удалён, потому что интерфейсов не осталось"
    fi
}

main() {
    local requested_if selected_if vpn_if server_conf clients_dir keys_dir iface_env service_name listen_port backup_dir

    require_root
    requested_if="${1:-${VPN_IF_OVERRIDE:-}}"
    selected_if="$(select_iface_interactive "$requested_if")"
    load_manager_env_for_iface "$selected_if"

    vpn_if="${VPN_IF:-$selected_if}"
    server_conf="${SERVER_CONF:-$(server_conf_for_iface "$vpn_if")}"
    clients_dir="${CLIENTS_DIR:-$(clients_dir_for_iface "$vpn_if")}"
    keys_dir="${KEYS_DIR:-$(keys_dir_for_iface "$vpn_if")}"
    iface_env="$(manager_env_for_iface "$vpn_if")"
    service_name="${SERVICE_NAME:-awg-quick@${vpn_if}.service}"
    listen_port="$(get_conf_value "$server_conf" ListenPort 2>/dev/null || true)"

    [[ -f "$server_conf" ]] || die "Не найден server.conf: $server_conf"
    printf 'Будет удалён интерфейс: %s\n' "$vpn_if"
    printf '  server_conf: %s\n' "$server_conf"
    printf '  clients_dir: %s\n' "$clients_dir"
    printf '  keys_dir:    %s\n' "$keys_dir"
    printf '  service:     %s\n' "$service_name"
    [[ -n "$listen_port" ]] && printf '  listen_port: %s\n' "$listen_port"

    if ! confirm_env_local "$CONFIRM_REMOVE" "Точно удалить интерфейс ${vpn_if} и его клиентов?" N; then
        warn "Удаление отменено"
        exit 0
    fi

    begin_safe_operation "remove-interface-${vpn_if}" >/dev/null
    backup_dir="$AWG_ACTIVE_BACKUP_DIR"
    warn "Backup/rollback папка операции: $backup_dir"

    [[ -e "$server_conf" ]] && operation_backup_path "$server_conf" >/dev/null
    [[ -e "$iface_env" ]] && operation_backup_path "$iface_env" >/dev/null
    [[ -e "$clients_dir" ]] && operation_backup_path "$clients_dir" >/dev/null
    [[ -e "$keys_dir" ]] && operation_backup_path "$keys_dir" >/dev/null

    systemctl stop "$service_name" 2>/dev/null || warn "Не удалось остановить $service_name или он уже не активен"
    systemctl disable "$service_name" 2>/dev/null || true

    rm -f -- "$server_conf" "$iface_env"
    rm -rf -- "$clients_dir" "$keys_dir"
    rewrite_manager_pointer_after_delete "$vpn_if"

    if [[ "$(normalise_yes_no "$SKIP_FIREWALL_UPDATE" 2>/dev/null || printf no)" != "yes" ]]; then
        FORCE_BACKUP_DIR="$backup_dir" \
        ALLOW_NO_INTERFACES=yes \
        EXTRA_AWG_PORTS_TO_REMOVE="$listen_port" \
        EXTRA_AWG_IFACES_TO_REMOVE="$vpn_if" \
        NFT_SAVE_CHANGES="$NFT_SAVE_CHANGES" \
        NFT_APPLY_NOW="$NFT_APPLY_NOW" \
        "${SCRIPT_DIR}/03_setup_nftables.sh"
    else
        warn "nftables не обновлялся: SKIP_FIREWALL_UPDATE=yes"
    fi

    commit_safe_operation
    ok "Интерфейс удалён: $vpn_if"
    ok "Backup папка: $backup_dir"
    printf '\nДля отката: sudo %s/10_restore_backup.sh %s\n' "$SCRIPT_DIR" "$backup_dir"
}

main "$@"
