#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

usage() {
    cat <<'EOF_USAGE'
00_manage.sh

Единый мастер-скрипт для AmneziaWG bundle.
Его можно запускать и на чистом сервере, и на сервере с уже установленным AmneziaWG.

Запуск:
  sudo ./scripts/00_manage.sh
или из корня архива:
  sudo ./install.sh

Режимы:
  --status     только показать найденное состояние и выйти
  --help       показать эту справку

Что делает при обычном запуске:
  1. Сканирует awg/awg-quick, модуль, sysctl, nftables, /etc/amnezia/amneziawg/*.conf.
  2. Показывает, что уже сделано.
  3. Если установка не найдена, предлагает установить из исходников.
  4. Если интерфейсов нет, предлагает создать первый интерфейс.
  5. Если интерфейсы есть, предлагает добавить клиента, добавить новый интерфейс, пересобрать firewall или обновить AWG.
EOF_USAGE
}

has_awg_tools() {
    local awg_bin awg_quick_bin
    awg_bin="$(detect_awg_bin)"
    awg_quick_bin="$(detect_awg_quick_bin)"
    [[ -n "$awg_bin" && -n "$awg_quick_bin" ]]
}

module_status() {
    if lsmod 2>/dev/null | grep -q '^amneziawg'; then
        printf 'loaded'
    elif command -v modinfo >/dev/null 2>&1 && modinfo amneziawg >/dev/null 2>&1; then
        printf 'available-not-loaded'
    else
        printf 'not-found'
    fi
}

service_state() {
    local service="$1"
    local active enabled
    if ! command -v systemctl >/dev/null 2>&1; then
        printf 'systemctl-unavailable'
        return 0
    fi
    active="$(systemctl is-active "$service" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
    printf '%s/%s' "${active:-unknown}" "${enabled:-unknown}"
}

status_report() {
    local awg_bin awg_quick_bin iface conf port mtu ipv4 ipv6 env_file client_mtu clients service ext_if ssh_port n
    awg_bin="$(detect_awg_bin)"
    awg_quick_bin="$(detect_awg_quick_bin)"

    printf '=== Состояние AmneziaWG bundle ===\n'
    printf 'Bundle:        %s\n' "$AMNEZIA_BUNDLE_ROOT"
    printf 'STATE_DIR:     %s\n' "$STATE_DIR"
    printf 'install.env:   %s\n' "$( [[ -f "$INSTALL_STATE_FILE" ]] && printf 'есть' || printf 'нет' )"
    printf 'awg:           %s\n' "${awg_bin:-не найден}"
    printf 'awg-quick:     %s\n' "${awg_quick_bin:-не найден}"
    printf 'module:        %s\n' "$(module_status)"
    printf 'sysctl file:   %s\n' "$( [[ -f "$SYSCTL_FILE" ]] && printf 'есть' || printf 'нет' )"
    if [[ -f "$SYSCTL_FILE" ]]; then
        printf 'ip_forward:    %s\n' "$(grep -E '^[[:space:]]*net.ipv4.ip_forward[[:space:]]*=' "$SYSCTL_FILE" | tail -n1 | sed -E 's/^[^=]+=[[:space:]]*//' || true)"
    fi
    source_env_if_exists "$FIREWALL_ENV_FILE"
    ext_if="${EXTERNAL_IF:-}"
    ssh_port="${SSH_PORT:-}"
    printf 'nftables.conf: %s\n' "$( [[ -f "$NFTABLES_CONF" ]] && printf 'есть' || printf 'нет' )"
    printf 'firewall.env:  %s\n' "$( [[ -f "$FIREWALL_ENV_FILE" ]] && printf 'есть' || printf 'нет' )"
    [[ -n "$ext_if" ]] && printf 'external_if:   %s\n' "$ext_if"
    [[ -n "$ssh_port" ]] && printf 'ssh_port:      %s\n' "$ssh_port"

    n="$(interface_count)"
    printf '\nИнтерфейсы: %s\n' "$n"
    if (( n == 0 )); then
        printf '  Не найдено файлов %s/*.conf\n' "$STATE_DIR"
    else
        while IFS= read -r iface; do
            conf="$(server_conf_for_iface "$iface")"
            port="$(get_conf_value "$conf" ListenPort || true)"
            mtu="$(get_server_mtu "$conf")"
            ipv4="$(get_server_ipv4_cidr "$conf" || true)"
            ipv6="$(get_server_ipv6_cidr "$conf" || true)"
            env_file="$(manager_env_for_iface "$iface")"
            client_mtu=""
            if [[ -f "$env_file" ]]; then
                # shellcheck disable=SC1090
                source "$env_file"
                client_mtu="${DEFAULT_CLIENT_MTU:-}"
            fi
            clients="$(count_clients_for_iface "$iface")"
            service="awg-quick@${iface}.service"
            printf '  - %s\n' "$iface"
            printf '      conf:        %s\n' "$conf"
            printf '      address:     %s / %s\n' "${ipv4:-?}" "${ipv6:-?}"
            printf '      listen_port: %s\n' "${port:-?}"
            printf '      server_mtu:  %s\n' "${mtu:-?}"
            printf '      client_mtu:  %s\n' "${client_mtu:-?}"
            printf '      clients:     %s (peers/files)\n' "$clients"
            printf '      service:     %s\n' "$(service_state "$service")"
        done < <(list_awg_interfaces_from_confs)
    fi
    printf '\n'
}

run_install_if_needed() {
    if has_awg_tools; then
        ok "awg и awg-quick уже найдены, установка пропущена"
        return 0
    fi
    if confirm "awg/awg-quick не найдены. Установить AmneziaWG из исходников сейчас?" Y; then
        "${SCRIPT_DIR}/01_install_from_source.sh"
    else
        die "Без awg и awg-quick нельзя создать интерфейс"
    fi
}

create_interface_flow() {
    local before after iface
    run_install_if_needed
    before="$(interface_count)"
    VPN_IF_DEFAULT="${VPN_IF_DEFAULT:-$(next_iface_name)}" "${SCRIPT_DIR}/02_create_server_config.sh"
    after="$(interface_count)"
    source_env_if_exists "$MANAGER_ENV_FILE"
    iface="${VPN_IF:-}"
    if (( after > before )); then
        ok "Добавлен новый интерфейс: ${iface:-$(next_iface_name)}"
    fi
    if confirm "Обновить nftables/NAT для всех AWG интерфейсов?" Y; then
        TARGET_VPN_IF="${iface:-}" "${SCRIPT_DIR}/03_setup_nftables.sh"
    else
        warn "Firewall/NAT не обновлён. Клиенты могут не подключиться извне, пока не выполнить 03_setup_nftables.sh."
    fi
    if confirm "Добавить клиента для этого интерфейса сейчас?" N; then
        add_client_flow "${iface:-}"
    fi
}

add_client_flow() {
    local requested_if="${1:-}"
    local iface client_name
    iface="$(select_iface_interactive "$requested_if")"
    client_name="$(prompt_default "Имя клиента" "client1")"
    "${SCRIPT_DIR}/04_add_client.sh" "$client_name" "$iface"
}

rebuild_firewall_flow() {
    "${SCRIPT_DIR}/03_setup_nftables.sh"
}

update_flow() {
    "${SCRIPT_DIR}/05_update_amneziawg.sh"
}

first_run_recommendation() {
    if ! has_awg_tools; then
        printf 'Рекомендация: выполнить полную установку, затем создать первый интерфейс.\n'
        if confirm "Запустить рекомендованный сценарий?" Y; then
            create_interface_flow
            return 0
        fi
    elif (( $(interface_count) == 0 )); then
        printf 'Рекомендация: AmneziaWG уже установлен, нужно создать первый интерфейс.\n'
        if confirm "Создать первый интерфейс?" Y; then
            create_interface_flow
            return 0
        fi
    else
        printf 'Рекомендация: установка уже есть. Обычно дальше нужно добавить клиента или новый интерфейс.\n'
    fi
    return 1
}

menu_loop() {
    local choice
    while true; do
        printf '\nЧто сделать?\n'
        printf '  1) Показать состояние\n'
        printf '  2) Установить/переустановить AmneziaWG из исходников\n'
        printf '  3) Создать новый интерфейс AWG\n'
        printf '  4) Добавить клиента в существующий интерфейс\n'
        printf '  5) Пересобрать nftables/NAT для всех интерфейсов\n'
        printf '  6) Обновить/восстановить AWG и перезапустить интерфейсы\n'
        printf '  0) Выход\n'
        choice="$(prompt_choice "Выбор" "4" "0 1 2 3 4 5 6")"
        case "$choice" in
            1) status_report ;;
            2) "${SCRIPT_DIR}/01_install_from_source.sh" ;;
            3) create_interface_flow ;;
            4) add_client_flow ;;
            5) rebuild_firewall_flow ;;
            6) update_flow ;;
            0) return 0 ;;
        esac
    done
}

main() {
    require_root
    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --status) status_report; exit 0 ;;
    esac

    status_report
    first_run_recommendation || menu_loop
}

main "$@"
