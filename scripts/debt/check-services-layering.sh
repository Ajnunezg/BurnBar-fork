#!/usr/bin/env bash
# Services layering + acyclicity fitness gate (docs/SERVICES_DECOMPOSITION_PROGRAM.md).
#
# Thin wrapper over scripts/debt/services_layering.py (manifest:
# config/services-layers.json, baseline: budgets/services-layering-baseline.json).
# Shrink-only: a new upward/cyclic reference key or a grown reference count
# fails; retired debt ratchets down with --update.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "${repo_root}/scripts/debt/services_layering.py" "$@"
