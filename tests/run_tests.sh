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
	@echo fake-tools
install:
	@echo fake-tools-install
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
        FORCE_OFFLINE=yes \
        SKIP_PACKAGE_INSTALL=yes \
        SKIP_BUILD=yes \
        QR_OUTPUT=no \
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
STUB_BIN="${TMP_ROOT}/bin"
TEST_LOG_DIR="${TMP_ROOT}/logs"
prepare_fake_sources "$SOURCES_DIR"
prepare_stubs "$STUB_BIN" "$TEST_LOG_DIR"
pass "Подготовлены fake sources и заглушки"

step "bash -n для всех скриптов"
find "${BUNDLE_ROOT}/scripts" "${BUNDLE_ROOT}/sources" -maxdepth 1 -type f -name '*.sh' -print | while read -r file; do
    bash -n "$file" || fail "Синтаксическая ошибка: $file"
done
bash -n "${BUNDLE_ROOT}/install.sh" || fail "Синтаксическая ошибка: install.sh"
pass "Все bash-скрипты проходят bash -n"

step "Тест 01_install_from_source.sh"
run_in_env "${BUNDLE_ROOT}/scripts/01_install_from_source.sh"
[[ -f "$INSTALL_STATE_FILE" ]] || fail "install.env не создан"
[[ -f "$SYSCTL_FILE" ]] || fail "00-amnezia.conf не создан"
grep -q 'net.ipv4.ip_forward = 1' "$SYSCTL_FILE" || fail "В sysctl не записан net.ipv4.ip_forward = 1"
pass "01_install_from_source.sh создаёт install.env и sysctl файл"

step "Тест 02_create_server_config.sh для awg0"
printf '\n\n\n\n89.124.86.140\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | run_in_env "${BUNDLE_ROOT}/scripts/02_create_server_config.sh"
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

step "Тест 03_setup_nftables.sh"
printf '\n\nY\n' | run_in_env "${BUNDLE_ROOT}/scripts/03_setup_nftables.sh"
[[ -f "$NFTABLES_CONF" ]] || fail "nftables.conf не создан"
grep -q 'udp dport { 56789 }' "$NFTABLES_CONF" || fail "В nftables.conf нет правила VPN порта"
grep -q 'tcp dport 22' "$NFTABLES_CONF" || fail "В nftables.conf нет правила SSH"
grep -q 'masquerade' "$NFTABLES_CONF" || fail "В nftables.conf нет masquerade"
[[ -f "$FIREWALL_ENV_FILE" ]] || fail "firewall.env не создан"
pass "03_setup_nftables.sh создаёт и применяет nftables.conf"

step "Тест 04_add_client.sh IPv4-only по умолчанию"
run_in_env "${BUNDLE_ROOT}/scripts/04_add_client.sh" owner_phone awg0
CLIENT_CONF="${STATE_DIR}/clients/owner_phone.conf"
[[ -f "$CLIENT_CONF" ]] || fail "Клиентский конфиг не создан"
grep -q '^# Address = fd42:42:42::2/128$' "$CLIENT_CONF" || fail "В client.conf нет закомментированного IPv6 Address"
grep -q '^AllowedIPs = 0.0.0.0/0$' "$CLIENT_CONF" || fail "В client.conf должен быть IPv4-only AllowedIPs по умолчанию"
grep -q '^MTU = 1280$' "$CLIENT_CONF" || fail "В client.conf нет MTU клиента"
grep -q '^### Client owner_phone$' "$SERVER_CONF" || fail "В server.conf не добавлен peer клиента"
grep -q '^AllowedIPs = 10.8.1.2/32$' "$SERVER_CONF" || fail "В peer клиента нет IPv4-only AllowedIPs"
pass "04_add_client.sh дописывает peer и создаёт client.conf"

step "Тест создания второго интерфейса awg1"
printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | \
    VPN_IF_DEFAULT=awg1 LISTEN_PORT_DEFAULT=443 \
    SERVER_ADDR_V4_DEFAULT=10.8.2.1/24 \
    SERVER_ADDR_V6_DEFAULT=fd42:42:43::1/64 \
    ENDPOINT_HOST_DEFAULT=89.124.86.140 \
    SERVER_MTU_DEFAULT=1360 CLIENT_MTU_DEFAULT=1200 \
    run_in_env "${BUNDLE_ROOT}/scripts/02_create_server_config.sh"
SERVER_CONF_2="${STATE_DIR}/awg1.conf"
[[ -f "$SERVER_CONF_2" ]] || fail "awg1.conf не создан"
grep -q '^ListenPort = 443$' "$SERVER_CONF_2" || fail "awg1 ListenPort не сохранён"
grep -q '^MTU = 1360$' "$SERVER_CONF_2" || fail "awg1 server MTU не сохранён"
grep -q "DEFAULT_CLIENT_MTU='1200'" "${STATE_DIR}/manager-awg1.env" || fail "awg1 client MTU default не сохранён"
[[ -d "${STATE_DIR}/awg1/clients" ]] || fail "awg1 clients dir не создан"
pass "Второй интерфейс создаётся рядом с первым"

step "Тест nftables для двух интерфейсов"
printf '\n\nY\n' | run_in_env "${BUNDLE_ROOT}/scripts/03_setup_nftables.sh"
grep -q 'udp dport { 56789, 443 }' "$NFTABLES_CONF" || fail "nftables не содержит оба UDP порта"
grep -q 'iifname { "awg0", "awg1" } accept' "$NFTABLES_CONF" || fail "nftables не содержит оба интерфейса"
pass "03_setup_nftables.sh учитывает несколько интерфейсов"

step "Тест добавления клиента на awg1"
run_in_env "${BUNDLE_ROOT}/scripts/04_add_client.sh" phone2 awg1
CLIENT_CONF_2="${STATE_DIR}/awg1/clients/phone2.conf"
[[ -f "$CLIENT_CONF_2" ]] || fail "Клиент awg1 не создан"
grep -q '^Address = 10.8.2.2/32$' "$CLIENT_CONF_2" || fail "Клиент awg1 получил неправильный IPv4"
grep -q '^MTU = 1200$' "$CLIENT_CONF_2" || fail "Клиент awg1 не использует DEFAULT_CLIENT_MTU"
grep -q '^AllowedIPs = 10.8.2.2/32$' "$SERVER_CONF_2" || fail "Peer awg1 не добавлен в правильный server.conf"
pass "04_add_client.sh добавляет клиента в выбранный интерфейс"

step "Тест 05_update_amneziawg.sh"
run_in_env "${BUNDLE_ROOT}/scripts/05_update_amneziawg.sh"
pass "05_update_amneziawg.sh выполняется на заглушках"

step "Тест единого мастера --status"
run_in_env "${BUNDLE_ROOT}/scripts/00_manage.sh" --status > "${TMP_ROOT}/status.txt"
grep -q 'Интерфейсы: 2' "${TMP_ROOT}/status.txt" || fail "00_manage --status не видит два интерфейса"
grep -q 'awg0' "${TMP_ROOT}/status.txt" || fail "00_manage --status не показывает awg0"
grep -q 'awg1' "${TMP_ROOT}/status.txt" || fail "00_manage --status не показывает awg1"
pass "00_manage.sh сканирует существующую установку"

printf '\nИТОГ: все автоматические тесты завершились успешно.\n' | tee -a "$REPORT_FILE"
