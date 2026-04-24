#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cat >&2 <<'EOF_NOTICE'
[!] 06_run_all.sh оставлен для совместимости.
    Новый рекомендуемый входной скрипт: scripts/00_manage.sh или ./install.sh из корня архива.
EOF_NOTICE

exec "${SCRIPT_DIR}/00_manage.sh" "$@"
