#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

usage() {
    cat <<'EOF_USAGE'
05_update_amneziawg.sh

Обновляет/восстанавливает установку AmneziaWG:
  - повторно запускает 01_install_from_source.sh;
  - обновляет исходники из интернета или локальных архивов;
  - пересобирает DKMS модуль и awg-tools;
  - вызывает dkms autoinstall;
  - перезапускает все найденные awg-quick@<iface>.service.

Используйте после обновления ядра, смены исходников или если модуль/утилиты сломались.
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

main() {
    local install_script iface service_name found

    require_root
    install_script="${SCRIPT_DIR}/01_install_from_source.sh"
    [[ -x "$install_script" ]] || die "Не найден ${install_script}"

    "$install_script"

    if command -v dkms >/dev/null 2>&1; then
        dkms autoinstall || warn "dkms autoinstall завершился с ошибкой"
    fi

    systemctl daemon-reload || true
    found="no"
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        found="yes"
        service_name="awg-quick@${iface}.service"
        if systemctl is-enabled "$service_name" >/dev/null 2>&1 || systemctl is-active "$service_name" >/dev/null 2>&1; then
            systemctl restart "$service_name" || warn "Не удалось перезапустить $service_name"
            ok "Сервис перезапущен: $service_name"
        else
            warn "Сервис $service_name ещё не включён. Это нормально, если интерфейс пока не запускали."
        fi
    done < <(list_awg_interfaces_from_confs)

    [[ "$found" == "yes" ]] || warn "Серверные интерфейсы пока не найдены: ${STATE_DIR}/*.conf"
    printf '\nГотово. DKMS отвечает за автоматическую пересборку модуля при установке новых ядер.\n'
}

main "$@"
