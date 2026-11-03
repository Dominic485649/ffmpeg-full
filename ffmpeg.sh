#!/usr/bin/env bash
# Standalone full build entry point; the full implementation lives in scripts/.
set -Eeuo pipefail
BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ROOT="${ROOT:-$BUNDLE_ROOT}"
exec "$BUNDLE_ROOT/scripts/build/full.sh" "$@"
