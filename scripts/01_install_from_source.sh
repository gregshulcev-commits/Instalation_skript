#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./00_common.sh
source "${SCRIPT_DIR}/00_common.sh"

KMOD_REPO_URL="${KMOD_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git}"
TOOLS_REPO_URL="${TOOLS_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-tools.git}"
KMOD_CACHE_DIR="${KMOD_CACHE_DIR:-${CACHE_DIR}/amneziawg-linux-kernel-module}"
TOOLS_CACHE_DIR="${TOOLS_CACHE_DIR:-${CACHE_DIR}/amneziawg-tools}"
FORCE_OFFLINE="${FORCE_OFFLINE:-no}"
SKIP_PACKAGE_INSTALL="${SKIP_PACKAGE_INSTALL:-no}"
SKIP_BUILD="${SKIP_BUILD:-no}"
SKIP_MODPROBE="${SKIP_MODPROBE:-no}"
INSTALL_QRENCODE="${INSTALL_QRENCODE:-no}"

usage() {
    cat <<'EOF_USAGE'
01_install_from_source.sh

Что делает:
  - определяет Ubuntu/Debian или Fedora
  - ставит зависимости для сборки
  - пытается скачать исходники AmneziaWG из интернета
  - если интернет недоступен, пытается взять архивы из ../sources/
  - собирает и ставит модуль ядра через DKMS
  - собирает и ставит awg / awg-quick
  - включает net.ipv4.ip_forward = 1 в /etc/sysctl.d/00-amnezia.conf
  - пишет install.env для следующих скриптов

Полезные переменные окружения:
  FORCE_OFFLINE=yes         - не ходить в интернет, брать только локальные архивы
  SKIP_PACKAGE_INSTALL=yes  - пропустить установку пакетов
  SKIP_BUILD=yes            - не собирать модуль и утилиты (для тестов)
  SKIP_MODPROBE=yes         - не вызывать modprobe amneziawg
EOF_USAGE
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

repo_is_reachable() {
    local repo_url="$1"
    [[ "$FORCE_OFFLINE" == "yes" ]] && return 1
    git ls-remote "$repo_url" HEAD >/dev/null 2>&1
}

install_packages_debian() {
    log "Устанавливаю зависимости для Debian/Ubuntu"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y \
        ca-certificates curl tar xz-utils git dkms make gcc g++ bc pkg-config \
        build-essential linux-headers-"$(uname -r)" libelf-dev iproute2 nftables
    if [[ "$INSTALL_QRENCODE" == "yes" ]]; then
        apt-get install -y qrencode || true
    fi
    if apt-cache show linux-headers-generic >/dev/null 2>&1; then
        apt-get install -y linux-headers-generic || true
    elif apt-cache show linux-headers-amd64 >/dev/null 2>&1; then
        apt-get install -y linux-headers-amd64 || true
    fi
}

install_packages_fedora() {
    log "Устанавливаю зависимости для Fedora"
    dnf -y groupinstall "Development Tools"
    dnf -y install \
        ca-certificates curl tar xz git dkms make gcc bc pkgconf-pkg-config \
        openssl-devel elfutils-libelf-devel kernel-devel kernel-headers \
        iproute nftables
    if dnf -q list kernel-devel-matched >/dev/null 2>&1; then
        dnf -y install kernel-devel-matched || true
    fi
    if [[ "$INSTALL_QRENCODE" == "yes" ]]; then
        dnf -y install qrencode || true
    fi
}

install_packages() {
    [[ "$SKIP_PACKAGE_INSTALL" == "yes" ]] && {
        warn "SKIP_PACKAGE_INSTALL=yes: установка пакетов пропущена"
        return 0
    }

    detect_os
    if is_debian_family; then
        install_packages_debian
    elif is_fedora_family; then
        install_packages_fedora
    else
        die "Неподдерживаемый дистрибутив: ID=${DISTRO_ID:-unknown}, ID_LIKE=${DISTRO_LIKE:-unknown}"
    fi
}

prepare_source_tree() {
    local base_name="$1"
    local repo_url="$2"
    local cache_dir="$3"
    local archive extracted

    ensure_dir "$(dirname "$cache_dir")"

    if repo_is_reachable "$repo_url"; then
        require_cmd git
        if [[ -d "$cache_dir/.git" ]]; then
            log "Обновляю исходники: $cache_dir" >&2
            git -C "$cache_dir" fetch --tags --prune origin
            git -C "$cache_dir" checkout master || true
            git -C "$cache_dir" pull --ff-only origin master || true
        else
            rm -rf "$cache_dir"
            log "Клонирую исходники: $repo_url" >&2
            git clone --depth 1 "$repo_url" "$cache_dir"
        fi
        printf '%s\n' "$cache_dir"
        return 0
    fi

    archive="$(find_source_archive "$base_name" || true)"
    [[ -n "$archive" ]] || die "Не удалось скачать ${base_name} из интернета и не найден локальный архив в ${SOURCES_DIR}"

    log "Интернет недоступен. Использую локальный архив: $archive" >&2
    extracted="$(extract_source_archive "$archive" "${cache_dir}.extract")"
    rm -rf "$cache_dir"
    mkdir -p "$(dirname "$cache_dir")"
    cp -a "$extracted" "$cache_dir"
    printf '%s\n' "$cache_dir"
}

compute_version() {
    local repo_dir="$1"
    local version
    if [[ -d "$repo_dir/.git" ]]; then
        version="$(git -C "$repo_dir" describe --tags --always 2>/dev/null || true)"
        version="${version#v}"
        version="${version//\//-}"
        version="${version// /-}"
        version="${version//[^A-Za-z0-9._-]/-}"
    fi
    if [[ -z "${version:-}" ]]; then
        version="1.0.$(date +%Y%m%d%H%M%S)"
    fi
    printf '%s\n' "$version"
}

prepare_kmod_source_for_dkms() {
    local repo_dir="$1"
    local version="$2"
    local src_dir="$repo_dir/src"
    local dkms_dir="/usr/src/amneziawg-${version}"

    [[ -d "$src_dir" ]] || die "Не найдена папка src в $repo_dir"

    if [[ -e "/lib/modules/$(uname -r)/build" ]]; then
        ln -sfn "/lib/modules/$(uname -r)/build" "$src_dir/kernel" || true
    fi

    if [[ -f "$src_dir/dkms.conf" ]] && grep -q '^PACKAGE_VERSION=' "$src_dir/dkms.conf"; then
        sed -i "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${version}\"/" "$src_dir/dkms.conf"
    fi
    if [[ -f "$src_dir/Makefile" ]] && grep -q '^WIREGUARD_VERSION = ' "$src_dir/Makefile"; then
        sed -i "s/^WIREGUARD_VERSION = .*/WIREGUARD_VERSION = ${version}/" "$src_dir/Makefile"
    fi

    rm -rf "$dkms_dir"
    mkdir -p "$dkms_dir"
    cp -a "$src_dir/." "$dkms_dir/"

    printf '%s\n' "$dkms_dir"
}

install_kmod_via_dkms() {
    local repo_dir="$1"
    local version="$2"
    local dkms_dir

    [[ "$SKIP_BUILD" == "yes" ]] && {
        warn "SKIP_BUILD=yes: установка модуля ядра пропущена"
        prepare_kmod_source_for_dkms "$repo_dir" "$version" >/dev/null
        return 0
    }

    require_cmd dkms
    dkms_dir="$(prepare_kmod_source_for_dkms "$repo_dir" "$version")"
    log "Собираю модуль ядра из $dkms_dir через DKMS"
    dkms remove -m amneziawg -v "$version" --all >/dev/null 2>&1 || true
    dkms add -m amneziawg -v "$version"
    dkms build -m amneziawg -v "$version"
    dkms install -m amneziawg -v "$version" --force

    if [[ "$SKIP_MODPROBE" != "yes" ]]; then
        if modprobe amneziawg; then
            ok "Модуль amneziawg загружен"
        else
            warn "modprobe amneziawg завершился ошибкой. Проверьте Secure Boot / dmesg"
        fi
    fi
}

install_tools_from_source() {
    local repo_dir="$1"
    local src_dir="$repo_dir/src"

    [[ -d "$src_dir" ]] || die "Не найдена папка src в $repo_dir"
    [[ "$SKIP_BUILD" == "yes" ]] && {
        warn "SKIP_BUILD=yes: сборка awg-tools пропущена"
        return 0
    }

    require_cmd make
    log "Собираю awg-tools"
    make -C "$src_dir" clean >/dev/null 2>&1 || true
    make -C "$src_dir"
    make -C "$src_dir" install PREFIX="$INSTALL_PREFIX" WITH_WGQUICK=yes WITH_SYSTEMDUNITS=yes
}

main() {
    local kmod_repo tools_repo version awg_bin awg_quick_bin

    require_root
    install_packages

    kmod_repo="$(prepare_source_tree "amneziawg-linux-kernel-module" "$KMOD_REPO_URL" "$KMOD_CACHE_DIR")"
    tools_repo="$(prepare_source_tree "amneziawg-tools" "$TOOLS_REPO_URL" "$TOOLS_CACHE_DIR")"

    version="$(compute_version "$kmod_repo")"
    log "Версия исходников модуля для DKMS: ${version}"
    install_kmod_via_dkms "$kmod_repo" "$version"
    install_tools_from_source "$tools_repo"

    awg_bin="$(first_cmd_path awg "${INSTALL_PREFIX}/bin/awg" /usr/local/bin/awg /usr/bin/awg)" || die "После установки не найден awg"
    awg_quick_bin="$(first_cmd_path awg-quick "${INSTALL_PREFIX}/bin/awg-quick" /usr/local/bin/awg-quick /usr/bin/awg-quick)" || die "После установки не найден awg-quick"

    ensure_dir "$STATE_DIR"
    ensure_sysctl_kv "$SYSCTL_FILE" "net.ipv4.ip_forward" "1"
    sysctl --system >/dev/null 2>&1 || warn "Не удалось применить sysctl автоматически. Выполните: sudo sysctl --system"

    write_install_state "$INSTALL_STATE_FILE" "$awg_bin" "$awg_quick_bin" "$kmod_repo" "$tools_repo"

    ok "Установка завершена"
    printf '\nПолезные файлы:\n'
    printf '  install.env: %s\n' "$INSTALL_STATE_FILE"
    printf '  sysctl:      %s\n' "$SYSCTL_FILE"
    printf '  awg:         %s\n' "$awg_bin"
    printf '  awg-quick:   %s\n' "$awg_quick_bin"
    printf '\nСледующий шаг: scripts/02_create_server_config.sh\n'
}

main "$@"
