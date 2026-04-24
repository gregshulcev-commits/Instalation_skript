#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

usage() {
    cat <<'EOF_USAGE'
07_add_interface.sh

Совместимый shortcut для добавления ещё одного интерфейса.
Новый рекомендуемый способ: sudo ./install.sh или sudo ./scripts/00_manage.sh, пункт "Создать новый интерфейс AWG".

Этот скрипт:
  1. проверяет, что awg/awg-quick уже установлены;
  2. запускает 02_create_server_config.sh со свободным именем awgN по умолчанию;
  3. предлагает обновить nftables для всех интерфейсов;
  4. предлагает добавить клиента.
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

main() {
    local iface client_name
    require_root
    source_env_if_exists "$INSTALL_STATE_FILE"

    if [[ -z "$(detect_awg_bin)" || -z "$(detect_awg_quick_bin)" ]]; then
        die "awg/awg-quick не найдены. Запустите sudo ./install.sh и выберите установку."
    fi

    printf '=== Создание нового интерфейса AmneziaWG ===\n'
    VPN_IF_DEFAULT="${VPN_IF_DEFAULT:-$(next_iface_name)}" "${SCRIPT_DIR}/02_create_server_config.sh"

    source_env_if_exists "$MANAGER_ENV_FILE"
    iface="${VPN_IF:-}"

    if confirm "Обновить nftables для всех AWG интерфейсов?" Y; then
        TARGET_VPN_IF="$iface" "${SCRIPT_DIR}/03_setup_nftables.sh"
    fi

    if confirm "Добавить клиента для нового интерфейса сейчас?" N; then
        client_name="$(prompt_default "Имя клиента" "client1")"
        "${SCRIPT_DIR}/04_add_client.sh" "$client_name" "$iface"
    fi

    printf '\nГотово. Клиента для этого интерфейса можно добавить так:\n'
    printf '  sudo %s/04_add_client.sh <client_name> %s\n' "$SCRIPT_DIR" "${iface:-<iface>}"
}

main "$@"
