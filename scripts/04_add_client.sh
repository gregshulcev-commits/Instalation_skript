#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

ENDPOINT_HOST_OVERRIDE="${ENDPOINT_HOST_OVERRIDE:-}"
ENDPOINT_PORT_OVERRIDE="${ENDPOINT_PORT_OVERRIDE:-}"
DNS_SERVERS_OVERRIDE="${DNS_SERVERS_OVERRIDE:-}"
CLIENT_MTU="${CLIENT_MTU:-}"
CLIENT_ENABLE_IPV6_WAS_SET="${CLIENT_ENABLE_IPV6+x}"
CLIENT_ENABLE_IPV6="${CLIENT_ENABLE_IPV6:-no}"
PERSISTENT_KEEPALIVE="${PERSISTENT_KEEPALIVE:-25}"
QR_OUTPUT="${QR_OUTPUT:-yes}"
ROLLBACK_ON_RESTART_FAIL="${ROLLBACK_ON_RESTART_FAIL:-no}"

usage() {
    cat <<'EOF_USAGE'
04_add_client.sh <client_name> [interface]

Добавляет клиента в выбранный интерфейс AmneziaWG.
Если interface не указан и интерфейсов несколько, скрипт предложит выбрать нужный.

Что делает:
  - читает manager-<interface>.env;
  - генерирует ключи клиента и PresharedKey;
  - выбирает следующий свободный IPv4 внутри /24 подсети интерфейса;
  - спрашивает/использует MTU клиента;
  - добавляет [Peer] в серверный .conf;
  - создаёт готовый клиентский .conf;
  - перезапускает awg-quick@<iface>.service.

Переменные:
  CLIENT_MTU=1280                  - MTU в клиентском конфиге без вопроса
  CLIENT_ENABLE_IPV6=yes|no        - добавить IPv6 Address и ::/0 в AllowedIPs. По умолчанию no.
  ENDPOINT_HOST_OVERRIDE=example   - endpoint host для client.conf
  ENDPOINT_PORT_OVERRIDE=443       - endpoint port для client.conf
  DNS_SERVERS_OVERRIDE='1.1.1.1'   - DNS для client.conf
  ROLLBACK_ON_RESTART_FAIL оставлена для совместимости; откат отключён, чтобы не перезаписывать server.conf
  QR_OUTPUT=no                     - не печатать QR-код
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

append_peer_to_server_conf() {
    local conf="$1"
    local client_name="$2"
    local client_pubkey="$3"
    local client_psk="$4"
    local allowed_ips="$5"

    cat >> "$conf" <<EOF_PEER

### Client ${client_name}
[Peer]
PublicKey = ${client_pubkey}
PresharedKey = ${client_psk}
AllowedIPs = ${allowed_ips}
EOF_PEER
}

generate_client_conf() {
    local file="$1"
    local client_privkey="$2"
    local client_ipv4="$3"
    local client_ipv6="$4"
    local dns_servers="$5"
    local client_mtu="$6"
    local obfs_block="$7"
    local server_pubkey="$8"
    local psk="$9"
    local endpoint="${10}"
    local allowed_ips="${11}"
    local enable_ipv6="${12}"

    {
        cat <<EOF_CLIENT
[Interface]
PrivateKey = ${client_privkey}
Address = ${client_ipv4}/32
EOF_CLIENT
        if [[ "$enable_ipv6" == "yes" ]]; then
            printf 'Address = %s/128\n' "$client_ipv6"
        else
            printf '# Address = %s/128\n' "$client_ipv6"
        fi
        cat <<EOF_CLIENT
DNS = ${dns_servers}
MTU = ${client_mtu}

${obfs_block}
[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${psk}
AllowedIPs = ${allowed_ips}
Endpoint = ${endpoint}
PersistentKeepalive = ${PERSISTENT_KEEPALIVE}
EOF_CLIENT
    } | write_new_file_from_stdin "$file" 600
}

main() {
    local client_name requested_if selected_if awg_bin server_conf clients_dir keys_dir vpn_if service_name endpoint_host endpoint_port endpoint
    local dns_servers server_ipv4_cidr server_ipv6_cidr client_ipv4 client_ipv6 obfs_block
    local client_privkey client_pubkey client_psk server_pubkey_file server_public_key server_private_key_file backup
    local client_conf_file host_id client_mtu enable_ipv6 server_allowed_ips client_allowed_ips restart_ok

    require_root
    source_env_if_exists "$INSTALL_STATE_FILE"

    client_name="${1:-}"
    if [[ -z "$client_name" ]]; then
        client_name="$(prompt_default "Имя клиента" "client1")"
    fi
    validate_client_name "$client_name"

    requested_if="${2:-${VPN_IF_OVERRIDE:-}}"
    selected_if="$(select_iface_interactive "$requested_if")"
    load_manager_env_for_iface "$selected_if"

    awg_bin="${AWG_BIN:-$(detect_awg_bin)}"
    [[ -n "$awg_bin" ]] || die "Не найден awg"

    vpn_if="${VPN_IF:-$selected_if}"
    server_conf="${SERVER_CONF:-$(server_conf_for_iface "$vpn_if")}"
    clients_dir="${CLIENTS_DIR:-$(clients_dir_for_iface "$vpn_if")}"
    keys_dir="${KEYS_DIR:-$(keys_dir_for_iface "$vpn_if")}"
    service_name="${SERVICE_NAME:-awg-quick@${vpn_if}.service}"

    [[ -n "$vpn_if" ]] || die "Не найден VPN_IF в manager env"
    [[ -n "$server_conf" && -f "$server_conf" ]] || die "Не найден server.conf для ${vpn_if}"

    client_exists_in_conf "$server_conf" "$client_name" && die "Клиент с таким именем уже существует в ${server_conf}"
    client_conf_file="${clients_dir}/${client_name}.conf"
    [[ ! -e "$client_conf_file" ]] || die "Клиентский конфиг уже существует: $client_conf_file"

    endpoint_host="${ENDPOINT_HOST_OVERRIDE:-${ENDPOINT_HOST:-}}"
    endpoint_port="${ENDPOINT_PORT_OVERRIDE:-${ENDPOINT_PORT:-$(get_conf_value "$server_conf" "ListenPort" || true)}}"
    [[ -n "$endpoint_host" ]] || die "Не задан endpoint host. Укажите его в manager env или через ENDPOINT_HOST_OVERRIDE"
    [[ -n "$endpoint_port" ]] || die "Не задан endpoint port"
    dns_servers="${DNS_SERVERS_OVERRIDE:-${DNS_SERVERS:-1.1.1.1, 1.0.0.1, 8.8.8.8}}"

    server_ipv4_cidr="$(get_server_ipv4_cidr "$server_conf" || true)"
    server_ipv6_cidr="$(get_server_ipv6_cidr "$server_conf" || true)"
    [[ -n "$server_ipv4_cidr" ]] || die "Не удалось определить IPv4 адрес сервера в ${server_conf}"
    [[ -n "$server_ipv6_cidr" ]] || die "Не удалось определить IPv6 адрес сервера в ${server_conf}"

    client_ipv4="$(next_free_ipv4 "$server_conf" "$server_ipv4_cidr")" || die "Не удалось найти свободный IPv4 адрес"
    host_id="${client_ipv4##*.}"
    client_ipv6="$(client_ipv6_from_server_cidr "$server_ipv6_cidr" "$host_id")"

    client_mtu="${CLIENT_MTU:-${DEFAULT_CLIENT_MTU:-1280}}"
    client_mtu="$(prompt_until_valid "MTU клиента для ${client_name}" "$client_mtu" validate_mtu)"

    enable_ipv6="$CLIENT_ENABLE_IPV6"
    if [[ "$enable_ipv6" != "yes" && "$enable_ipv6" != "no" ]]; then
        enable_ipv6="no"
    fi
    if [[ -z "$CLIENT_ENABLE_IPV6_WAS_SET" && is_interactive ]]; then
        if confirm "Маршрутизировать IPv6 через VPN для этого клиента?" N; then
            enable_ipv6="yes"
        else
            enable_ipv6="no"
        fi
    fi

    if [[ "$enable_ipv6" == "yes" ]]; then
        server_allowed_ips="${client_ipv4}/32, ${client_ipv6}/128"
        client_allowed_ips="0.0.0.0/0, ::/0"
    else
        server_allowed_ips="${client_ipv4}/32"
        client_allowed_ips="0.0.0.0/0"
    fi

    ensure_dir "$clients_dir"
    ensure_dir "$keys_dir"
    umask 077
    client_privkey="$("$awg_bin" genkey | strip_cr)"
    client_pubkey="$(printf '%s' "$client_privkey" | "$awg_bin" pubkey | strip_cr)"
    client_psk="$("$awg_bin" genpsk | strip_cr)"

    server_pubkey_file="${keys_dir}/server_public.key"
    server_private_key_file="${keys_dir}/server_private.key"
    if [[ -s "$server_pubkey_file" ]]; then
        server_public_key="$(strip_cr < "$server_pubkey_file")"
    else
        [[ -s "$server_private_key_file" ]] || die "Не найден server_private.key / server_public.key"
        if [[ -e "$server_pubkey_file" ]]; then
            die "${server_pubkey_file} существует, но пустой/битый. Не перезаписываю его автоматически."
        fi
        server_public_key="$(calc_public_key "$awg_bin" "$server_private_key_file" | strip_cr)"
        printf '%s\n' "$server_public_key" | write_new_file_from_stdin "$server_pubkey_file" 644
    fi

    obfs_block="$(get_obfuscation_block "$server_conf")"
    endpoint="${endpoint_host}:${endpoint_port}"
    if [[ "$endpoint_host" == *:* && "$endpoint_host" != \[*\] ]]; then
        endpoint="[${endpoint_host}]:${endpoint_port}"
    fi

    generate_client_conf "$client_conf_file" "$client_privkey" "$client_ipv4" "$client_ipv6" "$dns_servers" "$client_mtu" "$obfs_block" "$server_public_key" "$client_psk" "$endpoint" "$client_allowed_ips" "$enable_ipv6"

    backup="$(backup_file "$server_conf" || true)"
    [[ -n "$backup" ]] && warn "Резервная копия server.conf: $backup"
    append_peer_to_server_conf "$server_conf" "$client_name" "$client_pubkey" "$client_psk" "$server_allowed_ips"

    restart_ok="yes"
    if ! systemctl restart "$service_name"; then
        restart_ok="no"
        warn "Не удалось перезапустить ${service_name}. Проверьте: journalctl -u ${service_name} -n 100 --no-pager"
        if [[ "$ROLLBACK_ON_RESTART_FAIL" == "yes" ]]; then
            warn "ROLLBACK_ON_RESTART_FAIL=yes проигнорирован: откат потребовал бы перезаписать ${server_conf}. Старое содержимое сохранено в backup, новый peer был только дописан."
        fi
    fi

    ok "Клиент добавлен: ${client_name}"
    ok "Интерфейс: ${vpn_if}"
    ok "Серверный конфиг дополнен: ${server_conf}"
    ok "Клиентский конфиг создан: ${client_conf_file}"
    ok "MTU клиента: ${client_mtu}"
    [[ "$restart_ok" == "yes" ]] && ok "Сервис перезапущен: ${service_name}"

    if [[ "$QR_OUTPUT" == "yes" ]] && command -v qrencode >/dev/null 2>&1; then
        printf '\nQR-код для быстрого импорта:\n'
        qrencode -t ansiutf8 < "$client_conf_file"
    fi

    printf '\nСодержимое клиентского конфига:\n\n'
    cat "$client_conf_file"
}

main "$@"
