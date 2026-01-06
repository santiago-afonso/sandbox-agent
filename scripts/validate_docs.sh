#!/usr/bin/env bash
set -euo pipefail

echo "[validate-docs] Validating README for standalone repo paths..."

bad=0

# These are common mistakes when the repo is vendored under ./sandbox-agent/.
if rg -n -S 'sandbox-agent/Containerfile' README.md >/dev/null; then
  echo "[validate-docs] README.md references sandbox-agent/Containerfile; use Containerfile at repo root." >&2
  bad=1
fi

if rg -n -S 'sandbox-agent/sandbox-agent' README.md >/dev/null; then
  echo "[validate-docs] README.md references sandbox-agent/sandbox-agent; use ./sandbox-agent." >&2
  bad=1
fi

if [[ "$bad" -ne 0 ]]; then
  exit 1
fi

echo "[validate-docs] PASS"
