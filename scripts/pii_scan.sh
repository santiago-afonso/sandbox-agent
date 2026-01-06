#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[pii-scan] missing required command: $1" >&2
    exit 2
  }
}

need_cmd rg

RG_EXCLUDE_SELF=( --glob '!scripts/pii_scan.sh' )

echo "[pii-scan] Scanning for likely secrets..."
secret_matches="$(rg -n -S "${RG_EXCLUDE_SELF[@]}" 'ghp_|github_pat_|gho_|sk-[A-Za-z0-9]{20,}|BEGIN (RSA|OPENSSH|PGP)' . || true)"
if [[ -n "$secret_matches" ]]; then
  echo "$secret_matches"
  echo "[pii-scan] FAIL: found likely secret material" >&2
  exit 1
fi

echo "[pii-scan] Scanning for hardcoded home-directory paths..."
bad=0

# Allow the container's internal home path (/home/codex). Flag anything else.
matches="$(rg -n -S "${RG_EXCLUDE_SELF[@]}" '/home/' . || true)"
if [[ -n "$matches" ]]; then
  filtered="$(printf '%s\n' "$matches" | rg -v '/home/codex' || true)"
  if [[ -n "$filtered" ]]; then
    echo "$filtered"
    bad=1
  fi
fi

# macOS user paths should not appear in a general-purpose public repo.
rg -n -S "${RG_EXCLUDE_SELF[@]}" '/Users/' . && bad=1 || true

# Windows user paths (fixed-string to avoid regex backslash issues).
rg -n -F "${RG_EXCLUDE_SELF[@]}" 'C:\\Users\\' . && bad=1 || true

if [[ "$bad" -ne 0 ]]; then
  echo "[pii-scan] FAIL: found hardcoded user home paths" >&2
  exit 1
fi

echo "[pii-scan] PASS"
