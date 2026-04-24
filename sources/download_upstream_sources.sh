#!/usr/bin/env bash
set -euo pipefail

# Helper script to pre-download upstream source archives into this directory.
# Run it on a machine with internet access. After that the main bundle scripts
# can use these archives as an offline fallback.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KMOD_URL="${KMOD_URL:-https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/refs/heads/master.tar.gz}"
TOOLS_URL="${TOOLS_URL:-https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/heads/master.tar.gz}"

command -v curl >/dev/null 2>&1 || { echo "curl не найден" >&2; exit 1; }

curl -L --fail --retry 3 -o "${SCRIPT_DIR}/amneziawg-linux-kernel-module-master.tar.gz" "$KMOD_URL"
curl -L --fail --retry 3 -o "${SCRIPT_DIR}/amneziawg-tools-master.tar.gz" "$TOOLS_URL"

echo "Готово. Архивы сохранены в ${SCRIPT_DIR}"
