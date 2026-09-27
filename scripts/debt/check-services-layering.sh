#!/usr/bin/env bash
# Services layering + acyclicity fitness gate (docs/SERVICES_DECOMPOSITION_PROGRAM.md).
#
# Thin wrapper over scripts/debt/services_layering.py (manifest:
# config/services-layers.json, baseline: budgets/services-layering-baseline.json).
# Shrink-only: a new upward/cyclic reference key or a grown reference count
# fails; retired debt ratchets down with --update.
#
# With no arguments it runs --check and holds the committed baseline to the one
# at SERVICES_LAYERING_BASE (set by CI), or locally to the merge-base with
# origin/main, so a baseline can only shrink relative to where the branch began.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -eq 0 ]]; then
  base="${SERVICES_LAYERING_BASE:-}"
  if [[ -z "${base}" && -z "${CI:-}" ]]; then
    base="$(git -C "${repo_root}" merge-base HEAD origin/main 2>/dev/null || true)"
  fi
  set -- --check ${base:+--base "${base}"}
fi
exec python3 "${repo_root}/scripts/debt/services_layering.py" "$@"
