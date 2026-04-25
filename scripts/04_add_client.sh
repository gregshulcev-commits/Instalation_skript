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
ROLLBACK_ON_RESTART_FAIL="${ROLLBACK_ON_RESTART_FAIL:-yes}"
CLIENT_APPLY_MODE="${CLIENT_APPLY_MODE:-live}"

usage() {
    cat <<'EOF_USAGE'
04_add_client.sh <client_name> [interface]

Добавляет клиента в выбранный интерфейс AmneziaWG.
Если interface не указан и интерфейсов несколько, скрипт предложит выбрать нужный.

Что исправлено в этой версии:
  - по умолчанию клиент и server peer получают только IPv4 AllowedIPs;
  - IPv6 /128 добавляется в server.conf только при CLIENT_ENABLE_IPV6=yes;
  - это убирает типичный сбой awg-quick на строке `ip -6 route add ... dev awgN` для IPv4-only клиентов;
  - если IPv6 включается для клиента, MTU должен быть не ниже 1280;
  - перед изменением server.conf создаётся timestamp-backup с MANIFEST.tsv;
  - при Ctrl+C/ошибке или неудачном restart по умолчанию выполняется автоматический rollback.

Переменные:
  CLIENT_MTU=1280                  - MTU в client.conf без вопроса
  CLIENT_ENABLE_IPV6=yes|no        - добавить IPv6 Address и ::/0. По умолчанию no.
  ENDPOINT_HOST_OVERRIDE=example   - endpoint host для client.conf
  ENDPOINT_PORT_OVERRIDE=443       - endpoint port для client.conf
  DNS_SERVERS_OVERRIDE='1.1.1.1'   - DNS для client.conf
  CLIENT_APPLY_MODE=live|restart|none - как применять peer. По умолчанию live: awg set без полного restart интерфейса.
  ROLLBACK_ON_RESTART_FAIL=yes|no  - откат server.conf и client.conf, если применение/restart не удалось. По умолчанию yes.
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

[Peer]
# friendly_name=${client_name}
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
    local server_ipv6_available="${13}"

    {
        cat <<EOF_CLIENT
[Interface]
PrivateKey = ${client_privkey}
Address = ${client_ipv4}/32
EOF_CLIENT
        if [[ "$enable_ipv6" == "yes" ]]; then
            printf 'Address = %s/128\n' "$client_ipv6"
        elif [[ "$server_ipv6_available" == "yes" ]]; then
            printf '# Address = %s/128\n' "$client_ipv6"
            printf '# IPv6 is reserved for preview only. It is NOT added to server AllowedIPs unless CLIENT_ENABLE_IPV6=yes.\n'
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
    local dns_servers server_ipv4_cidr server_ipv6_cidr server_ipv6_available client_ipv4 client_ipv6 obfs_block
    local client_privkey client_pubkey client_psk server_pubkey_file server_public_key server_private_key_file backup_dir
    local client_conf_file host_id client_mtu enable_ipv6_raw enable_ipv6 server_allowed_ips client_allowed_ips apply_ok apply_mode server_mtu

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

    server_mtu="$(get_server_mtu "$server_conf" || true)"
    server_ipv6_available="no"
    if [[ -n "$server_ipv6_cidr" && "${SERVER_ENABLE_IPV6:-yes}" == "yes" ]]; then
        if [[ -z "$server_mtu" || ! "$server_mtu" =~ ^[0-9]+$ || "$server_mtu" -ge 1280 ]]; then
            server_ipv6_available="yes"
        else
            warn "В ${server_conf} есть IPv6, но MTU=${server_mtu} ниже 1280. IPv6 для новых клиентов отключён, чтобы не ловить сбой awg-quick на ip -6 route add."
        fi
    fi

    client_ipv4="$(next_free_ipv4 "$server_conf" "$server_ipv4_cidr")" || die "Не удалось найти свободный IPv4 адрес"
    host_id="${client_ipv4##*.}"
    if [[ "$server_ipv6_available" == "yes" ]]; then
        client_ipv6="$(client_ipv6_from_server_cidr "$server_ipv6_cidr" "$host_id")"
    else
        client_ipv6=""
    fi

    while true; do
        client_mtu="${CLIENT_MTU:-${DEFAULT_CLIENT_MTU:-1280}}"
        client_mtu="$(prompt_until_valid "MTU клиента для ${client_name}" "$client_mtu" validate_mtu)"
        break
    done

    enable_ipv6_raw="$CLIENT_ENABLE_IPV6"
    if ! enable_ipv6="$(normalise_yes_no "$enable_ipv6_raw" 2>/dev/null)"; then
        enable_ipv6="no"
    fi
    if [[ -z "$CLIENT_ENABLE_IPV6_WAS_SET" && is_interactive && "$server_ipv6_available" == "yes" ]]; then
        if confirm "Маршрутизировать IPv6 через VPN для этого клиента? Это добавит IPv6 /128 в server.conf и ::/0 в client.conf" N; then
            enable_ipv6="yes"
        else
            enable_ipv6="no"
        fi
    fi
    if [[ "$enable_ipv6" == "yes" ]]; then
        [[ "$server_ipv6_available" == "yes" ]] || die "CLIENT_ENABLE_IPV6=yes запрошен, но серверный IPv6 недоступен/небезопасен для текущего MTU"
        if (( client_mtu < 1280 )); then
            die "CLIENT_ENABLE_IPV6=yes требует MTU клиента не ниже 1280"
        fi
    fi

    server_allowed_ips="${client_ipv4}/32"
    client_allowed_ips="0.0.0.0/0"
    if [[ "$enable_ipv6" == "yes" ]]; then
        server_allowed_ips="${server_allowed_ips}, ${client_ipv6}/128"
        client_allowed_ips="${client_allowed_ips}, ::/0"
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

    begin_safe_operation "add-client-${vpn_if}-${client_name}" >/dev/null
    backup_dir="$AWG_ACTIVE_BACKUP_DIR"
    warn "Backup/rollback папка операции: $backup_dir"
    operation_backup_path "$server_conf" >/dev/null
    track_created_path "$client_conf_file"

    generate_client_conf "$client_conf_file" "$client_privkey" "$client_ipv4" "$client_ipv6" "$dns_servers" "$client_mtu" "$obfs_block" "$server_public_key" "$client_psk" "$endpoint" "$client_allowed_ips" "$enable_ipv6" "$server_ipv6_available"
    append_peer_to_server_conf "$server_conf" "$client_name" "$client_pubkey" "$client_psk" "$server_allowed_ips"

    apply_ok="yes"
    apply_mode="${CLIENT_APPLY_MODE:-live}"
    case "$apply_mode" in
        live)
            if ! awg_set_peer_add_live "$awg_bin" "$vpn_if" "$client_pubkey" "$client_psk" "$server_allowed_ips"; then
                apply_ok="no"
                warn "Не удалось применить peer live через awg set для ${vpn_if}. Полный restart интерфейса не выполняю автоматически."
                if [[ "$(normalise_yes_no "$ROLLBACK_ON_RESTART_FAIL" 2>/dev/null || printf yes)" == "yes" ]]; then
                    rollback_safe_operation 1
                    AWG_OPERATION_COMMITTED="yes"
                    trap - EXIT INT TERM
                    die "Изменения клиента ${client_name} откачены из backup: $backup_dir"
                fi
            fi
            ;;
        restart)
            if ! systemctl restart "$service_name"; then
                apply_ok="no"
                warn "Не удалось перезапустить ${service_name}. Проверьте: journalctl -u ${service_name} -n 100 --no-pager -l"
                if [[ "$(normalise_yes_no "$ROLLBACK_ON_RESTART_FAIL" 2>/dev/null || printf yes)" == "yes" ]]; then
                    rollback_safe_operation 1
                    AWG_OPERATION_COMMITTED="yes"
                    trap - EXIT INT TERM
                    systemctl restart "$service_name" >/dev/null 2>&1 || true
                    die "Изменения клиента ${client_name} откачены из backup: $backup_dir"
                fi
            fi
            ;;
        none)
            warn "CLIENT_APPLY_MODE=none: изменения сохранены только в файлах, live-интерфейс не менялся"
            ;;
        *)
            rollback_safe_operation 1
            AWG_OPERATION_COMMITTED="yes"
            trap - EXIT INT TERM
            die "Неизвестный CLIENT_APPLY_MODE=${apply_mode}; допустимо: live, restart, none"
            ;;
    esac

    commit_safe_operation
    restart_monitoring_after_peer_change || true
    ok "Клиент добавлен: ${client_name}"
    ok "Интерфейс: ${vpn_if}"
    ok "Серверный конфиг дополнен: ${server_conf}"
    ok "Клиентский конфиг создан: ${client_conf_file}"
    ok "MTU клиента: ${client_mtu}"
    ok "AllowedIPs на сервере: ${server_allowed_ips}"
    [[ "$apply_ok" == "yes" ]] && ok "Изменение применено, режим: ${apply_mode}"
    ok "Backup папка операции: $backup_dir"

    if [[ "$QR_OUTPUT" == "yes" ]] && command -v qrencode >/dev/null 2>&1; then
        printf '\nQR-код для быстрого импорта:\n'
        qrencode -t ansiutf8 < "$client_conf_file"
    fi

    printf '\nСодержимое клиентского конфига:\n\n'
    cat "$client_conf_file"
}

main "$@"
