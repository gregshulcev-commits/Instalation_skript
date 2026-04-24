#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

VPN_IF_DEFAULT="${VPN_IF_DEFAULT:-$(next_iface_name)}"
LISTEN_PORT_DEFAULT="${LISTEN_PORT_DEFAULT:-56789}"
SERVER_ADDR_V4_DEFAULT="${SERVER_ADDR_V4_DEFAULT:-10.8.1.1/24}"
SERVER_ADDR_V6_DEFAULT="${SERVER_ADDR_V6_DEFAULT:-fd42:42:42::1/64}"
ENDPOINT_HOST_DEFAULT="${ENDPOINT_HOST_DEFAULT:-}"
DNS_SERVERS_DEFAULT="${DNS_SERVERS_DEFAULT:-1.1.1.1, 1.0.0.1, 8.8.8.8}"
SERVER_MTU_DEFAULT="${SERVER_MTU_DEFAULT:-1280}"
CLIENT_MTU_DEFAULT="${CLIENT_MTU_DEFAULT:-1280}"
OVERWRITE_EXISTING_IFACE="${OVERWRITE_EXISTING_IFACE:-ask}"

Jc_DEFAULT="${Jc_DEFAULT:-7}"
Jmin_DEFAULT="${Jmin_DEFAULT:-50}"
Jmax_DEFAULT="${Jmax_DEFAULT:-1000}"
S1_DEFAULT="${S1_DEFAULT:-68}"
S2_DEFAULT="${S2_DEFAULT:-149}"
H1_DEFAULT="${H1_DEFAULT:-1109457265}"
H2_DEFAULT="${H2_DEFAULT:-249455488}"
H3_DEFAULT="${H3_DEFAULT:-1208847463}"
H4_DEFAULT="${H4_DEFAULT:-1645644382}"

usage() {
    cat <<'EOF_USAGE'
02_create_server_config.sh

Создаёт новый серверный конфиг AmneziaWG для одного интерфейса.
Скрипт подходит и для первого интерфейса, и для второго/третьего интерфейса на том же сервере.

Что спрашивает:
  - имя интерфейса;
  - UDP ListenPort;
  - IPv4 /24 адрес сервера внутри туннеля;
  - IPv6 /64 ULA адрес сервера внутри туннеля;
  - публичный endpoint для клиентских конфигов;
  - DNS для клиентов;
  - MTU сервера;
  - MTU клиента по умолчанию;
  - параметры обфускации AmneziaWG: Jc/Jmin/Jmax/S1/S2/H1-H4.

Защита от поломки старого интерфейса:
  - по умолчанию предлагается следующее свободное имя awg0, awg1, ...;
  - если указать уже существующий интерфейс, скрипт откажется продолжать;
  - существующие .conf, ключи и клиенты не перезаписываются.

Переменные окружения для неинтерактивного запуска:
  VPN_IF_DEFAULT=awg1
  LISTEN_PORT_DEFAULT=443
  SERVER_ADDR_V4_DEFAULT=10.8.2.1/24
  SERVER_ADDR_V6_DEFAULT=fd42:42:43::1/64
  SERVER_MTU_DEFAULT=1280
  CLIENT_MTU_DEFAULT=1280
  OVERWRITE_EXISTING_IFACE оставлена только для совместимости; перезапись запрещена всегда.
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

generate_server_keys_if_needed() {
    local awg_bin="$1"
    local keys_dir="$2"
    local server_private="$keys_dir/server_private.key"
    local server_public="$keys_dir/server_public.key"
    local private_key public_key

    ensure_dir "$keys_dir"
    if [[ -s "$server_private" && -s "$server_public" ]]; then
        ok "Ключи сервера уже существуют: $keys_dir"
        return 0
    fi

    if [[ -s "$server_private" && ! -e "$server_public" ]]; then
        log "server_private.key уже есть, создаю отсутствующий server_public.key без изменения private key"
        public_key="$("$awg_bin" pubkey < "$server_private" | strip_cr)"
        printf '%s\n' "$public_key" | write_new_file_from_stdin "$server_public" 644
        return 0
    fi

    if [[ -e "$server_private" || -e "$server_public" ]]; then
        die "Найдены неполные/пустые ключи в ${keys_dir}. Не перезаписываю старые файлы; проверьте их вручную."
    fi

    log "Генерирую ключи сервера"
    private_key="$("$awg_bin" genkey | strip_cr)"
    public_key="$(printf '%s' "$private_key" | "$awg_bin" pubkey | strip_cr)"
    printf '%s\n' "$private_key" | write_new_file_from_stdin "$server_private" 600
    printf '%s\n' "$public_key" | write_new_file_from_stdin "$server_public" 644
    ok "Ключи сервера созданы"
}

write_server_config() {
    local conf_file="$1"
    local private_key_file="$2"
    local listen_port="$3"
    local addr_v4="$4"
    local addr_v6="$5"
    local mtu="$6"
    local jc="$7"
    local jmin="$8"
    local jmax="$9"
    local s1="${10}"
    local s2="${11}"
    local h1="${12}"
    local h2="${13}"
    local h3="${14}"
    local h4="${15}"
    local private_key

    private_key="$(strip_cr < "$private_key_file")"

    cat <<EOF_CONF | write_new_file_from_stdin "$conf_file" 600
[Interface]
PrivateKey = ${private_key}
Address = ${addr_v4}
Address = ${addr_v6}
ListenPort = ${listen_port}
MTU = ${mtu}
Jc = ${jc}
Jmin = ${jmin}
Jmax = ${jmax}
S1 = ${s1}
S2 = ${s2}
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}

# Клиенты добавляются ниже скриптом 04_add_client.sh.
# Повторное создание этого же интерфейса запрещено, чтобы сохранить клиентов.
EOF_CONF
}

main() {
    local awg_bin awg_quick_bin vpn_if listen_port endpoint_host addr_v4 addr_v6 dns_servers server_mtu client_mtu
    local jc jmin jmax s1 s2 h1 h2 h3 h4
    local keys_dir server_conf clients_dir service_name unit_file existing_conf_count

    require_root
    source_env_if_exists "$INSTALL_STATE_FILE"

    awg_bin="${AWG_BIN:-$(detect_awg_bin)}"
    awg_quick_bin="${AWG_QUICK_BIN:-$(detect_awg_quick_bin)}"
    [[ -n "$awg_bin" ]] || die "Не найден awg. Сначала выполните scripts/01_install_from_source.sh или scripts/00_manage.sh"
    [[ -n "$awg_quick_bin" ]] || die "Не найден awg-quick. Сначала выполните scripts/01_install_from_source.sh или scripts/00_manage.sh"

    existing_conf_count="$(interface_count)"
    if (( existing_conf_count > 0 )); then
        printf 'Уже найдено интерфейсов: %s. Для нового интерфейса безопаснее принять свободное имя [%s].\n' "$existing_conf_count" "$VPN_IF_DEFAULT"
    fi

    vpn_if="$(prompt_until_valid "Имя VPN интерфейса" "$VPN_IF_DEFAULT" validate_iface_name)"
    listen_port="$(prompt_until_valid "UDP порт для VPN" "$LISTEN_PORT_DEFAULT" validate_port)"
    addr_v4="$(prompt_until_valid "IPv4 адрес сервера в туннеле" "$SERVER_ADDR_V4_DEFAULT" validate_ipv4_cidr_24)"
    addr_v6="$(prompt_until_valid "IPv6 адрес сервера в туннеле (ULA, задел на будущее)" "$SERVER_ADDR_V6_DEFAULT" validate_ipv6_cidr_64)"

    while true; do
        endpoint_host="$(prompt_default "Публичный IPv4 адрес или домен сервера для клиентов" "$ENDPOINT_HOST_DEFAULT")"
        if [[ -n "$endpoint_host" ]]; then
            break
        fi
        warn "Endpoint не может быть пустым"
    done

    dns_servers="$(prompt_default "DNS для клиентских конфигов" "$DNS_SERVERS_DEFAULT")"
    server_mtu="$(prompt_until_valid "MTU сервера" "$SERVER_MTU_DEFAULT" validate_mtu)"
    client_mtu="$(prompt_until_valid "MTU клиента по умолчанию" "$CLIENT_MTU_DEFAULT" validate_mtu)"

    if (( server_mtu < 1280 || client_mtu < 1280 )); then
        warn "MTU ниже 1280 может конфликтовать с IPv6. Это допустимо для теста IPv4-only, но безопасный старт обычно 1280."
    fi

    printf '\nПараметры обфускации AmneziaWG. Нажмите Enter, чтобы оставить значение по умолчанию.\n'
    jc="$(prompt_until_valid "Jc" "$Jc_DEFAULT" validate_small_nonneg_int)"
    jmin="$(prompt_until_valid "Jmin" "$Jmin_DEFAULT" validate_small_nonneg_int)"
    jmax="$(prompt_until_valid "Jmax" "$Jmax_DEFAULT" validate_small_nonneg_int)"
    s1="$(prompt_until_valid "S1" "$S1_DEFAULT" validate_small_nonneg_int)"
    s2="$(prompt_until_valid "S2" "$S2_DEFAULT" validate_small_nonneg_int)"
    h1="$(prompt_until_valid "H1" "$H1_DEFAULT" validate_uint32)"
    h2="$(prompt_until_valid "H2" "$H2_DEFAULT" validate_uint32)"
    h3="$(prompt_until_valid "H3" "$H3_DEFAULT" validate_uint32)"
    h4="$(prompt_until_valid "H4" "$H4_DEFAULT" validate_uint32)"

    keys_dir="$(keys_dir_for_iface "$vpn_if")"
    clients_dir="$(clients_dir_for_iface "$vpn_if")"
    server_conf="$(server_conf_for_iface "$vpn_if")"

    if [[ -f "$server_conf" ]]; then
        [[ "$OVERWRITE_EXISTING_IFACE" != "ask" ]] && warn "OVERWRITE_EXISTING_IFACE=${OVERWRITE_EXISTING_IFACE} проигнорирована: перезапись запрещена политикой сохранения старых данных"
        die "Интерфейс $vpn_if уже существует: $server_conf. Создайте новый интерфейс со свободным именем ($(next_iface_name)) или добавьте клиента через 04_add_client.sh."
    fi

    service_name="awg-quick@${vpn_if}.service"

    generate_server_keys_if_needed "$awg_bin" "$keys_dir"
    ensure_dir "$STATE_DIR"
    ensure_dir "$clients_dir"
    write_server_config "$server_conf" "$keys_dir/server_private.key" "$listen_port" "$addr_v4" "$addr_v6" "$server_mtu" "$jc" "$jmin" "$jmax" "$s1" "$s2" "$h1" "$h2" "$h3" "$h4"

    unit_file="$(create_awg_quick_service_template "$awg_quick_bin")"
    write_manager_env_for_iface "$MANAGER_ENV_FILE" "$vpn_if" "$server_conf" "$clients_dir" "$keys_dir" "$endpoint_host" "$listen_port" "$service_name" "$awg_bin" "$awg_quick_bin" "$dns_servers" "${EXTERNAL_IF:-}" "${SSH_PORT:-22}" "$client_mtu"

    systemctl daemon-reload
    ok "Конфиг сервера записан: $server_conf"
    ok "Папка клиентских конфигов: $clients_dir"
    ok "manager env интерфейса: $(manager_env_for_iface "$vpn_if")"
    ok "systemd unit: $unit_file"

    if confirm "Поднять интерфейс ${vpn_if} прямо сейчас?" Y; then
        if systemctl is-active "$service_name" >/dev/null 2>&1; then
            warn "${service_name} уже активен. Не останавливаю и не перезапускаю существующий service автоматически; запустите вручную после проверки."
        else
            systemctl start "$service_name"
            ok "Интерфейс ${vpn_if} поднят"
        fi
    else
        warn "Интерфейс не поднят. Позже можно выполнить: sudo systemctl start $service_name"
    fi

    printf '\nСледующий шаг: scripts/03_setup_nftables.sh или единый мастер scripts/00_manage.sh\n'
}

main "$@"
