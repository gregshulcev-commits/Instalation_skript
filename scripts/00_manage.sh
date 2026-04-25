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
  --status              только показать найденное состояние и выйти
  --monitoring          развернуть/обновить мониторинг Prometheus/Grafana
  --monitoring-status   показать состояние мониторинга
  --help                показать эту справку

Что делает при обычном запуске:
  1. Сканирует awg/awg-quick, модуль, sysctl, nftables, /etc/amnezia/amneziawg/*.conf.
  2. Показывает, что уже сделано.
  3. Если установка не найдена, предлагает установить из исходников.
  4. Если интерфейсов нет, предлагает создать первый интерфейс.
  5. Если интерфейсы есть, предлагает добавить/удалить клиента, добавить/удалить интерфейс, пересобрать firewall, восстановить backup или обновить AWG.
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
    local awg_bin awg_quick_bin iface conf port mtu ipv4 ipv6 env_file client_mtu server_enable_ipv6 clients service ext_if ssh_port n ipv6_peer_routes
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
            server_enable_ipv6=""
            if [[ -f "$env_file" ]]; then
                DEFAULT_CLIENT_MTU=""
                SERVER_ENABLE_IPV6=""
                # shellcheck disable=SC1090
                source "$env_file"
                client_mtu="${DEFAULT_CLIENT_MTU:-}"
                server_enable_ipv6="${SERVER_ENABLE_IPV6:-}"
            fi
            clients="$(count_clients_for_iface "$iface")"
            ipv6_peer_routes="$(grep -Ec '^[[:space:]]*AllowedIPs[[:space:]]*=.*:' "$conf" 2>/dev/null || true)"
            service="awg-quick@${iface}.service"
            printf '  - %s\n' "$iface"
            printf '      conf:        %s\n' "$conf"
            printf '      address:     %s / %s\n' "${ipv4:-?}" "${ipv6:-?}"
            printf '      listen_port: %s\n' "${port:-?}"
            printf '      server_mtu:  %s\n' "${mtu:-?}"
            printf '      client_mtu:  %s\n' "${client_mtu:-?}"
            printf '      ipv6_mode:   %s\n' "${server_enable_ipv6:-auto}"
            printf '      clients:     %s (peers/files)\n' "$clients"
            if [[ "${mtu:-0}" =~ ^[0-9]+$ && "${mtu:-0}" -lt 1280 && -n "${ipv6:-}" ]]; then
                printf '      warning:     IPv6 address + MTU %s < 1280. Лучше отключить IPv6 или поднять MTU.\n' "$mtu"
            fi
            if [[ "$ipv6_peer_routes" != "0" ]]; then
                printf '      ipv6_peers:  %s peer route(s) in AllowedIPs\n' "$ipv6_peer_routes"
            fi
            printf '      service:     %s\n' "$(service_state "$service")"
        done < <(list_awg_interfaces_from_confs)
    fi
    printf '\nМониторинг:\n'
    printf '  wgexporter:  %s\n' "$(service_state wgexporter)"
    printf '  prometheus:  %s\n' "$(service_state prometheus)"
    printf '  grafana:     %s\n' "$(service_state grafana-server)"
    printf '  dashboard:   %s\n' "$( [[ -f /var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json ]] && printf 'есть' || printf 'нет' )"
    printf '\n'
}

monitoring_status_report() {
    printf '=== Состояние мониторинга AWG ===\n'
    if [[ -f /etc/wgexporter/monitoring.env ]]; then
        # shellcheck disable=SC1091
        source /etc/wgexporter/monitoring.env
        printf 'monitoring.env: есть\n'
        printf 'WG_IFACES:      %s\n' "${WG_IFACES:-?}"
        printf 'ports:          exporter=%s persistent=%s prometheus=%s grafana=%s\n' "${EXPORTER_PORT:-9586}" "${PERSISTENT_EXPORTER_PORT:-9587}" "${PROMETHEUS_PORT:-9090}" "${GRAFANA_PORT:-3000}"
    else
        printf 'monitoring.env: нет\n'
    fi
    printf 'wgexporter:     %s\n' "$(service_state wgexporter)"
    printf 'persistent:     %s\n' "$(service_state awg-persistent-traffic)"
    printf 'prometheus:     %s\n' "$(service_state prometheus)"
    printf 'grafana:        %s\n' "$(service_state grafana-server)"
    printf 'dashboard:      %s\n' "$( [[ -f /var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json ]] && printf 'есть' || printf 'нет' )"
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

remove_client_flow() {
    local iface client_name
    iface="$(select_iface_interactive "")"
    client_name="$(prompt_default "Имя клиента для удаления" "client1")"
    "${SCRIPT_DIR}/08_remove_client.sh" "$client_name" "$iface"
}

remove_interface_flow() {
    local iface
    iface="$(select_iface_interactive "")"
    "${SCRIPT_DIR}/09_remove_interface.sh" "$iface"
}

restore_backup_flow() {
    "${SCRIPT_DIR}/10_restore_backup.sh"
}

rebuild_firewall_flow() {
    "${SCRIPT_DIR}/03_setup_nftables.sh"
}

update_flow() {
    "${SCRIPT_DIR}/05_update_amneziawg.sh"
}


setup_monitoring_flow() {
    "${SCRIPT_DIR}/11_setup_monitoring.sh"
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
        printf '  7) Удалить клиента из интерфейса\n'
        printf '  8) Удалить интерфейс AWG\n'
        printf '  9) Восстановить состояние из backup\n'
        printf '  10) Развернуть/обновить мониторинг Prometheus/Grafana для всех интерфейсов\n'
        printf '  11) Показать состояние мониторинга\n'
        printf '  0) Выход\n'
        choice="$(prompt_choice "Выбор" "4" "0 1 2 3 4 5 6 7 8 9 10 11")"
        case "$choice" in
            1) status_report ;;
            2) "${SCRIPT_DIR}/01_install_from_source.sh" ;;
            3) create_interface_flow ;;
            4) add_client_flow ;;
            5) rebuild_firewall_flow ;;
            6) update_flow ;;
            7) remove_client_flow ;;
            8) remove_interface_flow ;;
            9) restore_backup_flow ;;
            10) setup_monitoring_flow ;;
            11) monitoring_status_report ;;
            0) return 0 ;;
        esac
    done
}

main() {
    require_root
    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --status) status_report; exit 0 ;;
        --monitoring) setup_monitoring_flow; exit 0 ;;
        --monitoring-status) monitoring_status_report; exit 0 ;;
    esac

    status_report
    first_run_recommendation || menu_loop
}

main "$@"
