#!/usr/bin/env bash
# Refresh the English string table from the code, and list what each translation lacks.
#
#   scripts/l10n.sh           build with the compiler's string extraction, then
#                             scripts/l10n.py sync (adds new keys, drops unused ones)
#   scripts/l10n.sh --check   the same build, then fail on any missing key or translation
#
# The build uses its own scratch directory (app/.build-l10n), so it does not invalidate
# the test or release builds. docs/LOCALIZATION.md explains the workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env-compat.sh
SCRATCH="$PWD/app/.build-l10n"
OUT="$SCRATCH/l10n"

scripts/ffi.sh >/dev/null
mkdir -p "$OUT"
swift build --package-path app --scratch-path "$SCRATCH" --quiet \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
case "${1:-}" in
  --check) exec python3 scripts/l10n.py check "$OUT" ;;
  "") exec python3 scripts/l10n.py sync "$OUT" ;;
  *) echo "usage: scripts/l10n.sh [--check]" >&2; exit 2 ;;
esac
