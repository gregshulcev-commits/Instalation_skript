#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd -- "${TEST_DIR}/.." && pwd)"
REPORT_FILE="${TEST_DIR}/TEST_REPORT.txt"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { printf '[PASS] %s\n' "$1" | tee -a "$REPORT_FILE"; }
fail() { printf '[FAIL] %s\n' "$1" | tee -a "$REPORT_FILE"; exit 1; }
step() { printf '\n== %s ==\n' "$1" | tee -a "$REPORT_FILE"; }

prepare_fake_sources() {
    local dst="$1"
    mkdir -p "$dst/fake-kmod/amneziawg-linux-kernel-module-master/src"
    cat > "$dst/fake-kmod/amneziawg-linux-kernel-module-master/src/dkms.conf" <<'EOF_DKMS'
PACKAGE_NAME="amneziawg"
PACKAGE_VERSION="0"
EOF_DKMS
    cat > "$dst/fake-kmod/amneziawg-linux-kernel-module-master/src/Makefile" <<'EOF_MAKE'
WIREGUARD_VERSION = 0
all:
	@echo fake-kmod
EOF_MAKE
    tar -czf "$dst/amneziawg-linux-kernel-module-master.tar.gz" -C "$dst/fake-kmod" amneziawg-linux-kernel-module-master

    mkdir -p "$dst/fake-tools/amneziawg-tools-master/src"
    cat > "$dst/fake-tools/amneziawg-tools-master/src/Makefile" <<'EOF_TMAKE'
all:
	@echo fake-tools-build
clean:
	@echo fake-tools-clean
install:
	mkdir -p "$(PREFIX)/bin"
	printf '#!/usr/bin/env bash\necho FAKE-AWG\n' > "$(PREFIX)/bin/awg"
	printf '#!/usr/bin/env bash\necho FAKE-AWG-QUICK "$$@"\n' > "$(PREFIX)/bin/awg-quick"
	chmod +x "$(PREFIX)/bin/awg" "$(PREFIX)/bin/awg-quick"
EOF_TMAKE
    tar -czf "$dst/amneziawg-tools-master.tar.gz" -C "$dst/fake-tools" amneziawg-tools-master
}

prepare_stubs() {
    local bin_dir="$1"
    local log_dir="$2"
    mkdir -p "$bin_dir" "$log_dir"

    cat > "$bin_dir/awg" <<'EOF_AWG'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
    genkey)
        printf 'PRIV-%s\n' "$RANDOM$RANDOM"
        ;;
    genpsk)
        printf 'PSK-%s\n' "$RANDOM$RANDOM"
        ;;
    pubkey)
        input="$(cat)"
        printf 'PUB-%s\n' "$input"
        ;;
    *)
        echo "awg $*" >> "${TEST_LOG_DIR}/awg.log"
        ;;
esac
EOF_AWG

    cat > "$bin_dir/awg-quick" <<'EOF_AWGQ'
#!/usr/bin/env bash
set -euo pipefail
echo "awg-quick $*" >> "${TEST_LOG_DIR}/awg-quick.log"
EOF_AWGQ

    cat > "$bin_dir/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
echo "systemctl $*" >> "${TEST_LOG_DIR}/systemctl.log"
case "${1:-}" in
    is-active) echo inactive ; exit 3 ;;
    is-enabled) echo disabled ; exit 1 ;;
esac
exit 0
EOF_SYSTEMCTL

    cat > "$bin_dir/nft" <<'EOF_NFT'
#!/usr/bin/env bash
set -euo pipefail
echo "nft $*" >> "${TEST_LOG_DIR}/nft.log"
if [[ "${1:-}" == "-c" && "${2:-}" == "-f" ]]; then
    [[ -f "${3:-}" ]] || exit 1
    exit 0
fi
if [[ "${1:-}" == "-f" ]]; then
    cp "$2" "${TEST_LOG_DIR}/applied-nft.conf"
    exit 0
fi
if [[ "${1:-}" == "list" && "${2:-}" == "ruleset" ]]; then
    cat "${TEST_LOG_DIR}/applied-nft.conf" 2>/dev/null || true
    exit 0
fi
exit 0
EOF_NFT

    cat > "$bin_dir/ip" <<'EOF_IP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "route" && "${2:-}" == "get" ]]; then
    echo "1.1.1.1 via 192.0.2.1 dev ens3 src 192.0.2.10 uid 0"
    exit 0
fi
if [[ "${1:-}" == "-o" && "${2:-}" == "route" && "${3:-}" == "show" && "${4:-}" == "default" ]]; then
    echo "default via 192.0.2.1 dev ens3"
    exit 0
fi
exit 0
EOF_IP

    cat > "$bin_dir/sysctl" <<'EOF_SYSCTL'
#!/usr/bin/env bash
set -euo pipefail
echo "sysctl $*" >> "${TEST_LOG_DIR}/sysctl.log"
exit 0
EOF_SYSCTL

    cat > "$bin_dir/dkms" <<'EOF_DKMS_STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "dkms $*" >> "${TEST_LOG_DIR}/dkms.log"
exit 0
EOF_DKMS_STUB

    cat > "$bin_dir/modprobe" <<'EOF_MODPROBE'
#!/usr/bin/env bash
set -euo pipefail
echo "modprobe $*" >> "${TEST_LOG_DIR}/modprobe.log"
exit 0
EOF_MODPROBE

    chmod +x "$bin_dir"/*
}

run_in_env() {
    local script="$1"
    shift
    env \
        PATH="${STUB_BIN}:$PATH" \
        TEST_LOG_DIR="${TEST_LOG_DIR}" \
        AMNEZIA_BUNDLE_ROOT="${BUNDLE_ROOT}" \
        SOURCES_DIR="${SOURCES_DIR}" \
        STATE_DIR="${STATE_DIR}" \
        INSTALL_STATE_FILE="${INSTALL_STATE_FILE}" \
        MANAGER_ENV_FILE="${MANAGER_ENV_FILE}" \
        FIREWALL_ENV_FILE="${FIREWALL_ENV_FILE}" \
        SYSCTL_FILE="${SYSCTL_FILE}" \
        NFTABLES_CONF="${NFTABLES_CONF}" \
        SYSTEMD_DIR="${SYSTEMD_DIR}" \
        CACHE_DIR="${CACHE_DIR}" \
        INSTALL_PREFIX="${INSTALL_PREFIX}" \
        DKMS_ROOT="${DKMS_ROOT}" \
        FORCE_OFFLINE=yes \
        SKIP_PACKAGE_INSTALL=yes \
        SKIP_BUILD=yes \
        QR_OUTPUT=no \
        NFT_SAVE_CHANGES="${NFT_SAVE_CHANGES:-ask}" \
        NFT_APPLY_NOW="${NFT_APPLY_NOW:-ask}" \
        VPN_IF_DEFAULT="${VPN_IF_DEFAULT-}" \
        OVERWRITE_EXISTING_IFACE="${OVERWRITE_EXISTING_IFACE-}" \
        LISTEN_PORT_DEFAULT="${LISTEN_PORT_DEFAULT-}" \
        SERVER_ADDR_V4_DEFAULT="${SERVER_ADDR_V4_DEFAULT-}" \
        SERVER_ADDR_V6_DEFAULT="${SERVER_ADDR_V6_DEFAULT-}" \
        ENABLE_IPV6_DEFAULT="${ENABLE_IPV6_DEFAULT-}" \
        ENDPOINT_HOST_DEFAULT="${ENDPOINT_HOST_DEFAULT-}" \
        SERVER_MTU_DEFAULT="${SERVER_MTU_DEFAULT-}" \
        CLIENT_MTU_DEFAULT="${CLIENT_MTU_DEFAULT-}" \
        CLIENT_MTU="${CLIENT_MTU-}" \
        CLIENT_ENABLE_IPV6="${CLIENT_ENABLE_IPV6-}" \
        CONFIRM_REMOVE="${CONFIRM_REMOVE-}" \
        SKIP_FIREWALL_UPDATE="${SKIP_FIREWALL_UPDATE-}" \
        RESTORE_APPLY_NFT="${RESTORE_APPLY_NFT-}" \
        RESTORE_RESTART_SERVICES="${RESTORE_RESTART_SERVICES-}" \
        RESTORE_CONFIRM="${RESTORE_CONFIRM-}" \
        "$script" "$@"
}

: > "$REPORT_FILE"
printf 'AmneziaWG bundle test report\nGenerated: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$REPORT_FILE"

step "Подготовка окружения"
SOURCES_DIR="${TMP_ROOT}/sources"
STATE_DIR="${TMP_ROOT}/etc/amnezia/amneziawg"
INSTALL_STATE_FILE="${STATE_DIR}/install.env"
MANAGER_ENV_FILE="${STATE_DIR}/manager.env"
FIREWALL_ENV_FILE="${STATE_DIR}/firewall.env"
SYSCTL_FILE="${TMP_ROOT}/etc/sysctl.d/00-amnezia.conf"
NFTABLES_CONF="${TMP_ROOT}/etc/nftables.conf"
SYSTEMD_DIR="${TMP_ROOT}/etc/systemd/system"
CACHE_DIR="${TMP_ROOT}/cache"
INSTALL_PREFIX="${TMP_ROOT}/usr/local"
DKMS_ROOT="${TMP_ROOT}/usr/src"
STUB_BIN="${TMP_ROOT}/bin"
TEST_LOG_DIR="${TMP_ROOT}/logs"
prepare_fake_sources "$SOURCES_DIR"
prepare_stubs "$STUB_BIN" "$TEST_LOG_DIR"
pass "Подготовлены fake sources и заглушки"

step "bash -n для всех скриптов"
find "${BUNDLE_ROOT}/scripts" "${BUNDLE_ROOT}/sources" -maxdepth 1 -type f -name '*.sh' -print | while read -r file; do
    bash -n "$file" </dev/null || fail "Синтаксическая ошибка: $file"
done
bash -n "${BUNDLE_ROOT}/install.sh" </dev/null || fail "Синтаксическая ошибка: install.sh"
pass "Все bash-скрипты проходят bash -n"

step "Тест 01_install_from_source.sh append-only sysctl"
mkdir -p "$(dirname "$SYSCTL_FILE")"
printf '# old sysctl marker\nnet.ipv4.ip_forward = 0\n' > "$SYSCTL_FILE"
run_in_env "${BUNDLE_ROOT}/scripts/01_install_from_source.sh"
[[ -f "$INSTALL_STATE_FILE" ]] || fail "install.env не создан"
[[ -f "$SYSCTL_FILE" ]] || fail "00-amnezia.conf не создан"
grep -q '^# old sysctl marker$' "$SYSCTL_FILE" || fail "Старая sysctl строка-маркер потеряна"
grep -q '^net.ipv4.ip_forward = 0$' "$SYSCTL_FILE" || fail "Старое sysctl значение было изменено"
grep -q '^net.ipv4.ip_forward = 1$' "$SYSCTL_FILE" || fail "Новое sysctl значение не дописано"
pass "01_install_from_source.sh дописывает sysctl/install.env без изменения старых строк"

step "Тест safe-prefix установки awg-tools без перезаписи старых бинарников"
SAFE_ROOT="${TMP_ROOT}/safe-tools-install"
SAFE_SOURCES_DIR="${SAFE_ROOT}/sources"
SAFE_STATE_DIR="${SAFE_ROOT}/etc/amnezia/amneziawg"
SAFE_INSTALL_STATE_FILE="${SAFE_STATE_DIR}/install.env"
SAFE_SYSCTL_FILE="${SAFE_ROOT}/etc/sysctl.d/00-amnezia.conf"
SAFE_CACHE_DIR="${SAFE_ROOT}/cache"
SAFE_INSTALL_PREFIX="${SAFE_ROOT}/usr/local"
SAFE_DKMS_ROOT="${SAFE_ROOT}/usr/src"
SAFE_STUB_BIN="${SAFE_ROOT}/bin"
SAFE_LOG_DIR="${SAFE_ROOT}/logs"
prepare_fake_sources "$SAFE_SOURCES_DIR"
prepare_stubs "$SAFE_STUB_BIN" "$SAFE_LOG_DIR"
mkdir -p "${SAFE_INSTALL_PREFIX}/bin"
printf 'OLD-AWG\n' > "${SAFE_INSTALL_PREFIX}/bin/awg"
printf 'OLD-AWG-QUICK\n' > "${SAFE_INSTALL_PREFIX}/bin/awg-quick"
chmod +x "${SAFE_INSTALL_PREFIX}/bin/awg" "${SAFE_INSTALL_PREFIX}/bin/awg-quick"
env     PATH="${SAFE_STUB_BIN}:$PATH"     TEST_LOG_DIR="${SAFE_LOG_DIR}"     AMNEZIA_BUNDLE_ROOT="${BUNDLE_ROOT}"     SOURCES_DIR="${SAFE_SOURCES_DIR}"     STATE_DIR="${SAFE_STATE_DIR}"     INSTALL_STATE_FILE="${SAFE_INSTALL_STATE_FILE}"     SYSCTL_FILE="${SAFE_SYSCTL_FILE}"     CACHE_DIR="${SAFE_CACHE_DIR}"     INSTALL_PREFIX="${SAFE_INSTALL_PREFIX}"     DKMS_ROOT="${SAFE_DKMS_ROOT}"     FORCE_OFFLINE=yes     SKIP_PACKAGE_INSTALL=yes     SKIP_MODPROBE=yes     "${BUNDLE_ROOT}/scripts/01_install_from_source.sh"
grep -qx '^OLD-AWG$' "${SAFE_INSTALL_PREFIX}/bin/awg" || fail "Старый awg бинарник был изменён"
grep -qx '^OLD-AWG-QUICK$' "${SAFE_INSTALL_PREFIX}/bin/awg-quick" || fail "Старый awg-quick бинарник был изменён"
grep -q "AWG_BIN='${SAFE_INSTALL_PREFIX}/libexec/amneziawg-bundle-tools/bin/awg'" "$SAFE_INSTALL_STATE_FILE" || fail "install.env не указывает на новый safe-prefix awg"
grep -q "AWG_QUICK_BIN='${SAFE_INSTALL_PREFIX}/libexec/amneziawg-bundle-tools/bin/awg-quick'" "$SAFE_INSTALL_STATE_FILE" || fail "install.env не указывает на новый safe-prefix awg-quick"
"${SAFE_INSTALL_PREFIX}/libexec/amneziawg-bundle-tools/bin/awg" | grep -q FAKE-AWG || fail "Новый awg не установлен в safe-prefix"
pass "01_install_from_source.sh ставит awg-tools в новый каталог и не меняет старые бинарники"

step "Тест 02_create_server_config.sh для awg0"
printf '%s\n' '' '' '' yes '' '' '' '' '' '' '' '' '' '' '' '' '' '' n | run_in_env "${BUNDLE_ROOT}/scripts/02_create_server_config.sh"
SERVER_CONF="${STATE_DIR}/awg0.conf"
[[ -f "$SERVER_CONF" ]] || fail "server.conf не создан"
grep -q '^Address = 10.8.1.1/24$' "$SERVER_CONF" || fail "В server.conf нет IPv4 Address"
grep -q '^Address = fd42:42:42::1/64$' "$SERVER_CONF" || fail "В server.conf нет IPv6 Address"
grep -q '^ListenPort = 56789$' "$SERVER_CONF" || fail "В server.conf нет ListenPort"
grep -q '^MTU = 1280$' "$SERVER_CONF" || fail "В server.conf нет MTU"
[[ -f "$MANAGER_ENV_FILE" ]] || fail "manager.env не создан"
[[ -f "${STATE_DIR}/manager-awg0.env" ]] || fail "manager-awg0.env не создан"
grep -q "DEFAULT_CLIENT_MTU='1280'" "${STATE_DIR}/manager-awg0.env" || fail "DEFAULT_CLIENT_MTU не сохранён"
pass "02_create_server_config.sh создаёт awg0.conf и manager env"

step "Тест 03_setup_nftables.sh создаёт пустой firewall по безопасному template"
printf '\n\n' | NFT_SAVE_CHANGES=yes NFT_APPLY_NOW=yes run_in_env "${BUNDLE_ROOT}/scripts/03_setup_nftables.sh"
[[ -f "$NFTABLES_CONF" ]] || fail "nftables.conf не создан"
grep -q '^table inet filter' "$NFTABLES_CONF" || fail "В nftables.conf нет table inet filter"
grep -q 'policy drop' "$NFTABLES_CONF" || fail "input policy должна быть drop"
grep -q 'tcp dport 22 accept' "$NFTABLES_CONF" || fail "В nftables.conf нет правила SSH"
grep -q 'iifname "ens3" udp dport { 56789 } accept' "$NFTABLES_CONF" || fail "В nftables.conf нет VPN порта awg0"
grep -q 'iifname { "awg0" } oifname "ens3" masquerade' "$NFTABLES_CONF" || fail "В nftables.conf нет masquerade для awg0"
[[ -f "$FIREWALL_ENV_FILE" ]] || fail "firewall.env не создан"
pass "03_setup_nftables.sh создаёт template с policy drop, SSH allow и NAT"

step "Тест 04_add_client.sh IPv4-only по умолчанию"
run_in_env "${BUNDLE_ROOT}/scripts/04_add_client.sh" owner_phone awg0
CLIENT_CONF="${STATE_DIR}/clients/owner_phone.conf"
[[ -f "$CLIENT_CONF" ]] || fail "Клиентский конфиг не создан"
grep -q '^# Address = fd42:42:42::2/128$' "$CLIENT_CONF" || fail "В client.conf нет закомментированного IPv6 Address"
grep -q '^AllowedIPs = 0.0.0.0/0$' "$CLIENT_CONF" || fail "В client.conf должен быть IPv4-only AllowedIPs по умолчанию"
grep -q '^MTU = 1280$' "$CLIENT_CONF" || fail "В client.conf нет MTU клиента"
grep -q '^# friendly_name=owner_phone$' "$SERVER_CONF" || fail "В server.conf нет friendly_name для клиента"
grep -q '^AllowedIPs = 10.8.1.2/32$' "$SERVER_CONF" || fail "В peer клиента должен быть IPv4-only AllowedIPs по умолчанию"
! grep -q '^AllowedIPs = 10.8.1.2/32, fd42:42:42::2/128$' "$SERVER_CONF" || fail "IPv6 /128 не должен добавляться в server.conf по умолчанию"
find "${STATE_DIR}/backups" -type f -name 'awg0.conf' | grep -q . || fail "Не создан timestamp backup server.conf"
pass "04_add_client.sh дописывает Grafana-friendly peer, резервирует IPv6 комментарием и создаёт IPv4-only client.conf"

step "Тест запрета перезаписи существующего интерфейса"
SERVER_BEFORE="${TMP_ROOT}/awg0.before"
cp "$SERVER_CONF" "$SERVER_BEFORE"
if printf '\n\n\n\n89.124.86.140\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | \
    VPN_IF_DEFAULT=awg0 OVERWRITE_EXISTING_IFACE=yes \
    run_in_env "${BUNDLE_ROOT}/scripts/02_create_server_config.sh" >/tmp/overwrite-attempt.log 2>&1; then
    fail "02_create_server_config.sh разрешил перезапись существующего awg0"
fi
cmp -s "$SERVER_CONF" "$SERVER_BEFORE" || fail "server.conf awg0 изменился после отказанной перезаписи"
pass "02_create_server_config.sh не перезаписывает существующий интерфейс даже при OVERWRITE_EXISTING_IFACE=yes"

step "Тест создания второго интерфейса awg1"
printf '%s\n' '' '' '' yes '' '' '' '' '' '' '' '' '' '' '' '' '' '' n | \
    VPN_IF_DEFAULT=awg1 LISTEN_PORT_DEFAULT=520 \
    SERVER_ADDR_V4_DEFAULT=10.8.2.1/24 \
    SERVER_ADDR_V6_DEFAULT=fd42:42:43::1/64 \
    ENDPOINT_HOST_DEFAULT=89.124.86.140 \
    SERVER_MTU_DEFAULT=1360 CLIENT_MTU_DEFAULT=1200 \
    run_in_env "${BUNDLE_ROOT}/scripts/02_create_server_config.sh"
SERVER_CONF_2="${STATE_DIR}/awg1.conf"
[[ -f "$SERVER_CONF_2" ]] || fail "awg1.conf не создан"
grep -q '^ListenPort = 520$' "$SERVER_CONF_2" || fail "awg1 ListenPort не сохранён"
grep -q '^MTU = 1360$' "$SERVER_CONF_2" || fail "awg1 server MTU не сохранён"
grep -q "DEFAULT_CLIENT_MTU='1200'" "${STATE_DIR}/manager-awg1.env" || fail "awg1 client MTU default не сохранён"
[[ -d "${STATE_DIR}/awg1/clients" ]] || fail "awg1 clients dir не создан"
pass "Второй интерфейс создаётся рядом с первым"

step "Тест nftables для двух интерфейсов: аккуратное обновление существующего native firewall"
cat > "$NFTABLES_CONF" <<'EOF_NFT_EXISTING'
table inet filter {
        chain input {
                type filter hook input priority filter; policy drop;
                iif "lo" accept
                ct state established,related accept
                tcp dport 22 accept
                ip protocol icmp icmp type { echo-reply, destination-unreachable, echo-request, time-exceeded } accept
                iifname "ens3" udp dport 56789 accept
                iifname "ens3" udp dport { 53, 443 } accept
                iifname "awg0" tcp dport 3000 accept
        }

        chain forward {
                type filter hook forward priority filter; policy accept;
        }

        chain output {
                type filter hook output priority filter; policy accept;
        }
}
table inet nat {
        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
                iifname "awg0" oifname "ens3" masquerade
        }

        chain prerouting {
                type nat hook prerouting priority dstnat; policy accept;
                udp dport { 53, 443 } redirect to :56789
        }
}

table ip amneziawg_bundle {
        chain input {
                type filter hook input priority 0; policy accept;
                iifname "ens3" udp dport { 56789, 520 } accept
        }
}
EOF_NFT_EXISTING
printf '\n\n' | NFT_SAVE_CHANGES=yes NFT_APPLY_NOW=no run_in_env "${BUNDLE_ROOT}/scripts/03_setup_nftables.sh"
grep -q 'iifname "ens3" udp dport { 56789, 520 } accept' "$NFTABLES_CONF" || fail "nftables не объединил UDP порты awg0/awg1"
! grep -q 'iifname "ens3" udp dport 56789 accept' "$NFTABLES_CONF" || fail "Старое одиночное правило UDP 56789 не было убрано из candidate"
grep -q 'iifname "ens3" udp dport { 53, 443 } accept' "$NFTABLES_CONF" || fail "Существующее правило 53/443 потеряно"
grep -q 'udp dport { 53, 443 } redirect to :56789' "$NFTABLES_CONF" || fail "redirect 53/443 потерян"
grep -q 'iifname { "awg0", "awg1" } oifname "ens3" masquerade' "$NFTABLES_CONF" || fail "nftables не объединил masquerade awg0/awg1"
! grep -q '^table ip amneziawg_bundle' "$NFTABLES_CONF" || fail "Старый bundle table не был удалён из candidate"
[[ "$(grep -c 'chain input' "$NFTABLES_CONF")" -eq 1 ]] || fail "Появилась лишняя input chain"
find "${STATE_DIR}/backups" -type f -name 'nftables.conf' | grep -q . || fail "Не создан timestamp backup nftables.conf"
pass "03_setup_nftables.sh обновляет существующий firewall без дублей и сохраняет redirect"

step "Тест добавления клиента на awg1"
run_in_env "${BUNDLE_ROOT}/scripts/04_add_client.sh" phone2 awg1
CLIENT_CONF_2="${STATE_DIR}/awg1/clients/phone2.conf"
[[ -f "$CLIENT_CONF_2" ]] || fail "Клиент awg1 не создан"
grep -q '^Address = 10.8.2.2/32$' "$CLIENT_CONF_2" || fail "Клиент awg1 получил неправильный IPv4"
grep -q '^MTU = 1200$' "$CLIENT_CONF_2" || fail "Клиент awg1 не использует DEFAULT_CLIENT_MTU"
grep -q '^# friendly_name=phone2$' "$SERVER_CONF_2" || fail "Peer awg1 не получил friendly_name"
grep -q '^AllowedIPs = 10.8.2.2/32$' "$SERVER_CONF_2" || fail "Peer awg1 не добавлен с IPv4-only AllowedIPs по умолчанию"
pass "04_add_client.sh добавляет клиента в выбранный интерфейс"

step "Тест 05_update_amneziawg.sh атомарно перезаписывает install.env с backup"
printf '# install env sentinel before update\n' >> "$INSTALL_STATE_FILE"
run_in_env "${BUNDLE_ROOT}/scripts/05_update_amneziawg.sh"
! grep -q '^# install env sentinel before update$' "$INSTALL_STATE_FILE" || fail "install.env должен перезаписываться, а не дописываться"
find "${STATE_DIR}/backups" -type f -name 'install.env' -exec grep -q '^# install env sentinel before update$' {} \; -print | grep -q . || fail "старый install.env не найден в backup"
pass "05_update_amneziawg.sh выполняется на заглушках, перезаписывает install.env и сохраняет backup"

step "Тест единого мастера --status и startup full backup"
run_in_env "${BUNDLE_ROOT}/scripts/00_manage.sh" --status > "${TMP_ROOT}/status.txt"
grep -q 'Интерфейсы: 2' "${TMP_ROOT}/status.txt" || fail "00_manage --status не видит два интерфейса"
grep -q 'awg0' "${TMP_ROOT}/status.txt" || fail "00_manage --status не показывает awg0"
grep -q 'awg1' "${TMP_ROOT}/status.txt" || fail "00_manage --status не показывает awg1"
find "${STATE_DIR}/backups" -maxdepth 1 -type d -name '*script-start-management*' | grep -q . || fail "00_manage не создал full backup при запуске"
pass "00_manage.sh сканирует существующую установку и делает full backup при запуске"

step "Тест удаления клиента по номеру без manager-<iface>.env"
run_in_env "${BUNDLE_ROOT}/scripts/04_add_client.sh" numbered awg1
NUMBERED_CONF="${STATE_DIR}/awg1/clients/numbered.conf"
[[ -f "$NUMBERED_CONF" ]] || fail "Клиент numbered не создан"
mv "${STATE_DIR}/manager-awg1.env" "${TMP_ROOT}/manager-awg1.env.saved"
printf '2
' | CONFIRM_REMOVE=yes run_in_env "${BUNDLE_ROOT}/scripts/08_remove_client.sh" --interactive awg1 > "${TMP_ROOT}/remove-numbered.txt"
[[ ! -f "$NUMBERED_CONF" ]] || fail "client.conf numbered не удалён интерактивным выбором"
! grep -q '^# friendly_name=numbered$' "$SERVER_CONF_2" || fail "Peer numbered не удалён по номеру"
grep -q 'Выбран клиент #2: numbered' "${TMP_ROOT}/remove-numbered.txt" || fail "Интерактивное удаление не выбрало клиента numbered"
rm -rf "${STATE_DIR}/manager-awg1.env"
mv "${TMP_ROOT}/manager-awg1.env.saved" "${STATE_DIR}/manager-awg1.env"
pass "08_remove_client.sh удаляет выбранного по номеру клиента и работает без manager-<iface>.env"

step "Тест явного IPv6 клиента на awg0"
CLIENT_ENABLE_IPV6=yes CLIENT_MTU=1280 run_in_env "${BUNDLE_ROOT}/scripts/04_add_client.sh" ipv6_phone awg0
IPV6_CLIENT_CONF="${STATE_DIR}/clients/ipv6_phone.conf"
[[ -f "$IPV6_CLIENT_CONF" ]] || fail "IPv6-клиент не создан"
grep -q '^Address = fd42:42:42::3/128$' "$IPV6_CLIENT_CONF" || fail "В IPv6 client.conf нет активного IPv6 Address"
grep -q '^AllowedIPs = 0.0.0.0/0, ::/0$' "$IPV6_CLIENT_CONF" || fail "В IPv6 client.conf нет ::/0"
grep -q '^AllowedIPs = 10.8.1.3/32, fd42:42:42::3/128$' "$SERVER_CONF" || fail "IPv6 /128 не добавлен в server.conf при CLIENT_ENABLE_IPV6=yes"
pass "04_add_client.sh добавляет IPv6 /128 только при явном CLIENT_ENABLE_IPV6=yes"

step "Тест удаления клиента и restore remove-client backup"
CONFIRM_REMOVE=yes run_in_env "${BUNDLE_ROOT}/scripts/08_remove_client.sh" phone2 awg1
[[ ! -f "$CLIENT_CONF_2" ]] || fail "client.conf phone2 не удалён"
! grep -q '^# friendly_name=phone2$' "$SERVER_CONF_2" || fail "Peer phone2 не удалён из awg1.conf"
REMOVE_CLIENT_BACKUP="$(find "${STATE_DIR}/backups" -maxdepth 1 -type d -name '*remove-client-awg1-phone2*' | sort | tail -n1)"
[[ -n "$REMOVE_CLIENT_BACKUP" ]] || fail "Backup удаления клиента не найден"
RESTORE_CONFIRM=yes RESTORE_APPLY_NFT=no RESTORE_RESTART_SERVICES=no run_in_env "${BUNDLE_ROOT}/scripts/10_restore_backup.sh" "$REMOVE_CLIENT_BACKUP"
[[ -f "$CLIENT_CONF_2" ]] || fail "restore не вернул client.conf phone2"
grep -q '^# friendly_name=phone2$' "$SERVER_CONF_2" || fail "restore не вернул peer phone2"
pass "08_remove_client.sh удаляет клиента, а 10_restore_backup.sh возвращает его из backup"

step "Тест удаления интерфейса awg1 с очисткой nftables и restore backup"
CONFIRM_REMOVE=yes NFT_SAVE_CHANGES=yes NFT_APPLY_NOW=no run_in_env "${BUNDLE_ROOT}/scripts/09_remove_interface.sh" awg1
[[ ! -f "$SERVER_CONF_2" ]] || fail "awg1.conf не удалён"
[[ ! -d "${STATE_DIR}/awg1/clients" ]] || fail "clients dir awg1 не удалён"
! grep -q 'awg1' "$NFTABLES_CONF" || fail "nftables всё ещё содержит awg1 после удаления интерфейса"
! grep -q '520' "$NFTABLES_CONF" || fail "nftables всё ещё содержит порт 520 после удаления интерфейса"
grep -q "VPN_IF='awg0'" "$MANAGER_ENV_FILE" || fail "manager.env не переключён на awg0"
REMOVE_IFACE_BACKUP="$(find "${STATE_DIR}/backups" -maxdepth 1 -type d -name '*remove-interface-awg1*' | sort | tail -n1)"
[[ -n "$REMOVE_IFACE_BACKUP" ]] || fail "Backup удаления интерфейса не найден"
RESTORE_CONFIRM=yes RESTORE_APPLY_NFT=no RESTORE_RESTART_SERVICES=no run_in_env "${BUNDLE_ROOT}/scripts/10_restore_backup.sh" "$REMOVE_IFACE_BACKUP"
[[ -f "$SERVER_CONF_2" ]] || fail "restore не вернул awg1.conf"
[[ -f "$CLIENT_CONF_2" ]] || fail "restore не вернул клиента awg1"
grep -q 'iifname { "awg0", "awg1" } oifname "ens3" masquerade' "$NFTABLES_CONF" || fail "restore не вернул NAT для awg1"
pass "09_remove_interface.sh удаляет интерфейс и чистит firewall, а restore возвращает состояние"

step "Тест monitoring add-on: синтаксис и static-safety"
bash -n "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" </dev/null || fail "11_setup_monitoring.sh не проходит bash -n"
bash -n "${BUNDLE_ROOT}/monitoring/src/check_awg_monitoring.sh" </dev/null || fail "check_awg_monitoring.sh не проходит bash -n"
/usr/bin/python3 -m py_compile \
    "${BUNDLE_ROOT}/monitoring/src/awg_exporter_sync_peers.py" \
    "${BUNDLE_ROOT}/monitoring/src/awg_persistent_traffic_exporter.py" || fail "Python monitoring helpers не проходят py_compile"
/usr/bin/python3 - <<PY_DASH
import json
from pathlib import Path
path = Path('${BUNDLE_ROOT}') / 'monitoring/grafana/awg-traffic-by-client-dashboard.json'
data = json.loads(path.read_text(encoding='utf-8'))
assert data['uid'] == 'awg-traffic-by-client'
assert data['title'] == 'AWG traffic by client'
panels = data.get('panels') or []
assert len(panels) == 1
panel = panels[0]
assert panel.get('type') == 'bargauge'
assert panel.get('datasource', {}).get('uid') == 'awg-prometheus'
expr = panel['targets'][0]['expr']
assert 'sum by (friendly_name)' in expr
assert 'awg_persistent_received_bytes_total' in expr
assert 'awg_persistent_sent_bytes_total' in expr
PY_DASH
grep -q '/usr/local/bin/wg' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "monitoring installer должен использовать /usr/local/bin/wg wrapper"
grep -q 'show all dump' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "monitoring installer должен поддерживать wg show all dump для multi-interface"
grep -q 'EXPORTER_INTERFACE_MODE="${EXPORTER_INTERFACE_MODE:-all}"' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "По умолчанию exporter должен использовать all-mode"
! grep -q 'cat >.*/usr/bin/wg' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "monitoring installer не должен перезаписывать /usr/bin/wg"
grep -q 'isDefault: false' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "Grafana datasource не должен становиться default"
grep -q 'disableDeletion: true' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "Grafana provider должен включать disableDeletion"
grep -q 'allowUiUpdates: true' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "Grafana provider должен включать allowUiUpdates"
grep -q 'MANAGE_EXISTING_GRAFANA_INI' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "Нет флага безопасного управления существующим grafana.ini"
grep -q 'python3-yaml' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "Нет зависимости python3-yaml для аккуратного patch Prometheus YAML"
grep -q 'promtool check config' "${BUNDLE_ROOT}/scripts/11_setup_monitoring.sh" || fail "Prometheus config должен проверяться promtool при наличии"
pass "monitoring add-on проходит syntax/static safety checks"

step "Тест awg-exporter-sync-peers: sanitized metadata без секретов"
SYNC_TMP="${TMP_ROOT}/sync-peers"
mkdir -p "$SYNC_TMP"
cat >"${SYNC_TMP}/sample_awg0.conf" <<'EOF_SYNC_CONF'
[Interface]
PrivateKey = SERVER_SECRET
Address = 10.8.1.1/24

# friendly_name = owner_phone
[Peer]
PublicKey = PUB_OWNER
PresharedKey = PSK_SECRET
AllowedIPs = 10.8.1.2/32

[Peer]
# friendly_name = tablet
PublicKey = PUB_TABLET
AllowedIPs = 10.8.1.3/32
EOF_SYNC_CONF
/usr/bin/python3 "${BUNDLE_ROOT}/monitoring/src/awg_exporter_sync_peers.py" \
    --output "${SYNC_TMP}/peers.conf" \
    --owner "$(id -u):$(id -g)" \
    --mode 0640 \
    --configs "${SYNC_TMP}/sample_awg0.conf" >/dev/null
grep -q '# friendly_name = owner_phone' "${SYNC_TMP}/peers.conf" || fail "friendly_name перед [Peer] не сохранён"
grep -q '# friendly_name = tablet' "${SYNC_TMP}/peers.conf" || fail "friendly_name внутри [Peer] не сохранён"
grep -q '^PublicKey = PUB_OWNER$' "${SYNC_TMP}/peers.conf" || fail "PublicKey не попал в sanitized peers.conf"
grep -q '^AllowedIPs = 10.8.1.2/32$' "${SYNC_TMP}/peers.conf" || fail "AllowedIPs не попал в sanitized peers.conf"
! grep -q 'PrivateKey' "${SYNC_TMP}/peers.conf" || fail "PrivateKey попал в sanitized peers.conf"
! grep -q 'PresharedKey' "${SYNC_TMP}/peers.conf" || fail "PresharedKey попал в sanitized peers.conf"
pass "awg-exporter-sync-peers создаёт файл метаданных без PrivateKey/PresharedKey"

step "Тест persistent traffic exporter: reset counters + fallback friendly_name"
/usr/bin/python3 - <<PY_PERSIST
import importlib.util
from pathlib import Path
module_path = Path('${BUNDLE_ROOT}') / 'monitoring/src/awg_persistent_traffic_exporter.py'
spec = importlib.util.spec_from_file_location('persist', module_path)
mod = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
state = mod.empty_state()
text1 = '''wireguard_received_bytes_total{interface="awg0",public_key="KEY1",allowed_ips="10.8.1.2/32",friendly_name="phone"} 100\nwireguard_sent_bytes_total{interface="awg0",public_key="KEY1",allowed_ips="10.8.1.2/32",friendly_name="phone"} 50\n'''
mod.update_state_with_samples(state, mod.parse_wireguard_samples(text1), now=1)
assert state['totals']['rx|awg0|KEY1'] == 100
assert state['totals']['tx|awg0|KEY1'] == 50
text2 = '''wireguard_received_bytes_total{interface="awg0",public_key="KEY1",allowed_ips="10.8.1.2/32",friendly_name="phone"} 150\nwireguard_sent_bytes_total{interface="awg0",public_key="KEY1",allowed_ips="10.8.1.2/32",friendly_name="phone"} 70\n'''
mod.update_state_with_samples(state, mod.parse_wireguard_samples(text2), now=2)
assert state['totals']['rx|awg0|KEY1'] == 150
assert state['totals']['tx|awg0|KEY1'] == 70
text3 = '''wireguard_received_bytes_total{interface="awg0",public_key="KEY1",allowed_ips="10.8.1.2/32",friendly_name="phone"} 10\nwireguard_sent_bytes_total{interface="awg0",public_key="KEY1",allowed_ips="10.8.1.2/32",friendly_name="phone"} 5\n'''
mod.update_state_with_samples(state, mod.parse_wireguard_samples(text3), now=3)
assert state['totals']['rx|awg0|KEY1'] == 160
assert state['totals']['tx|awg0|KEY1'] == 75
text4 = 'wireguard_received_bytes_total{interface="awg1",public_key="KEY2",allowed_ips="10.8.2.2/32"} 12\n'
mod.update_state_with_samples(state, mod.parse_wireguard_samples(text4), now=4)
assert state['labels']['rx|awg1|KEY2']['friendly_name'] == '10.8.2.2/32'
rendered = mod.render_metrics(state, scrape_success=True)
assert 'awg_persistent_received_bytes_total' in rendered
assert 'friendly_name="phone"' in rendered
assert '160' in rendered and '75' in rendered
PY_PERSIST
pass "persistent traffic exporter корректно переживает reset raw counter и добавляет fallback friendly_name"

step "Тест единого install.sh: monitoring options доступны"
bash -n "${BUNDLE_ROOT}/install.sh" </dev/null || fail "install.sh не проходит bash -n"
"${BUNDLE_ROOT}/install.sh" --help | grep -q -- '--monitoring' || fail "install.sh --help не показывает --monitoring"
"${BUNDLE_ROOT}/install.sh" --help | grep -q -- '--monitoring-status' || fail "install.sh --help не показывает --monitoring-status"
pass "install.sh/00_manage.sh содержит единый вход для мониторинга"

printf '\nИТОГ: все автоматические тесты завершились успешно.\n' | tee -a "$REPORT_FILE"
