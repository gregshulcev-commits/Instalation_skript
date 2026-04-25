#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

RESTORE_APPLY_NFT="${RESTORE_APPLY_NFT:-ask}"              # yes|no|ask
RESTORE_RESTART_SERVICES="${RESTORE_RESTART_SERVICES:-ask}" # yes|no|ask
RESTORE_CONFIRM="${RESTORE_CONFIRM:-ask}"                 # yes|no|ask

usage() {
    cat <<'EOF_USAGE'
10_restore_backup.sh [backup_dir]

Восстанавливает состояние из timestamp backup папки, созданной скриптами bundle.
Backup должен содержать MANIFEST.tsv. Если в backup есть CREATED_PATHS, эти пути будут удалены перед восстановлением старых файлов.

Примеры:
  sudo ./scripts/10_restore_backup.sh
  sudo ./scripts/10_restore_backup.sh /etc/amnezia/amneziawg/backups/20260425-120000-remove-client-awg0-phone

Переменные:
  RESTORE_APPLY_NFT=yes|no|ask       - применить восстановленный nftables.conf. По умолчанию ask.
  RESTORE_RESTART_SERVICES=yes|no|ask - перезапустить awg-quick@*.service после restore. По умолчанию ask.
  RESTORE_CONFIRM=yes|no|ask       - подтверждение restore. По умолчанию ask.
EOF_USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
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

select_backup_dir() {
    local requested="${1:-}"
    local root="${BACKUP_ROOT:-${STATE_DIR}/backups}"
    local backups idx choice
    if [[ -n "$requested" ]]; then
        printf '%s\n' "$requested"
        return 0
    fi
    mapfile -t backups < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    if (( ${#backups[@]} == 0 )); then
        die "Backup-папки не найдены в $root"
    fi
    printf 'Доступные backup-папки:\n' >&2
    idx=1
    for dir in "${backups[@]}"; do
        printf '  %s) %s\n' "$idx" "$dir" >&2
        idx=$((idx + 1))
    done
    while true; do
        read -r -p "Выберите backup [1]: " choice || choice=""
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#backups[@]} )); then
            printf '%s\n' "${backups[$((choice - 1))]}"
            return 0
        fi
        warn "Введите номер от 1 до ${#backups[@]}"
    done
}

backup_current_before_restore() {
    local backup_dir="$1"
    local pre_dir manifest kind original rel path
    pre_dir="$(create_timestamped_backup_dir pre-restore)"
    manifest="${backup_dir}/MANIFEST.tsv"
    while IFS=$'\t' read -r kind original rel; do
        [[ -n "${original:-}" ]] || continue
        [[ -e "$original" ]] && backup_path_to_dir "$original" "$pre_dir" >/dev/null
    done < "$manifest"
    if [[ -f "${backup_dir}/CREATED_PATHS" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" && -e "$path" ]] && backup_path_to_dir "$path" "$pre_dir" >/dev/null
        done < "${backup_dir}/CREATED_PATHS"
    fi
    printf '%s\n' "$pre_dir"
}

remove_created_paths_from_backup() {
    local backup_dir="$1"
    local tmp path
    [[ -f "${backup_dir}/CREATED_PATHS" ]] || return 0
    tmp="$(mktemp)"
    tac "${backup_dir}/CREATED_PATHS" > "$tmp"
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        rm -rf -- "$path"
    done < "$tmp"
    rm -f "$tmp"
}

restart_awg_services() {
    local iface service found="no"
    systemctl daemon-reload || true
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        found="yes"
        service="awg-quick@${iface}.service"
        if systemctl is-enabled "$service" >/dev/null 2>&1 || systemctl is-active "$service" >/dev/null 2>&1; then
            systemctl restart "$service" || warn "Не удалось перезапустить $service"
        fi
    done < <(list_awg_interfaces_from_confs)
    [[ "$found" == "yes" ]] || warn "После restore AWG интерфейсы не найдены"
}

main() {
    local backup_dir pre_restore_dir
    require_root
    backup_dir="$(select_backup_dir "${1:-}")"
    [[ -d "$backup_dir" ]] || die "Backup directory не найден: $backup_dir"
    [[ -f "${backup_dir}/MANIFEST.tsv" ]] || die "MANIFEST.tsv не найден в $backup_dir"

    printf 'Будет восстановлен backup:\n  %s\n' "$backup_dir"
    [[ -f "${backup_dir}/INFO" ]] && sed 's/^/  /' "${backup_dir}/INFO"
    if ! confirm_env_local "$RESTORE_CONFIRM" "Продолжить restore? Текущее состояние будет предварительно сохранено в отдельный pre-restore backup." N; then
        warn "Restore отменён"
        exit 0
    fi

    pre_restore_dir="$(backup_current_before_restore "$backup_dir")"
    warn "Pre-restore backup текущего состояния: $pre_restore_dir"

    remove_created_paths_from_backup "$backup_dir"
    restore_backup_dir "$backup_dir"
    ok "Файлы восстановлены из backup: $backup_dir"

    if [[ -f "$NFTABLES_CONF" ]] && confirm_env_local "$RESTORE_APPLY_NFT" "Проверить и применить восстановленный nftables.conf сейчас?" N; then
        if command -v nft >/dev/null 2>&1; then
            nft -c -f "$NFTABLES_CONF"
            nft -f "$NFTABLES_CONF"
            ok "nftables применён"
        else
            warn "nft не найден; примените firewall вручную"
        fi
    fi

    if confirm_env_local "$RESTORE_RESTART_SERVICES" "Перезапустить awg-quick services после restore?" N; then
        restart_awg_services
        ok "Перезапуск AWG services выполнен"
    fi

    ok "Restore завершён"
    ok "Откат самого restore возможен из pre-restore backup: $pre_restore_dir"
}

main "$@"
