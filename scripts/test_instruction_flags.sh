#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WRAPPER="$ROOT/sandbox-agent"
WORKDIR="${1:-$PWD}"

PASS=0
FAIL=0

log() {
  echo "[instruction-test] $*"
}

pass() {
  PASS=$((PASS + 1))
  echo "[instruction-test] PASS: $*"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "[instruction-test] FAIL: $*" >&2
}

run_expect_success() {
  local name="$1"
  shift
  local out rc
  set +e
  out="$($@ 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    fail "$name (rc=$rc)"
    echo "$out" >&2
    return
  fi
  pass "$name"
  printf '%s' "$out"
}

run_expect_fail() {
  local name="$1"
  shift
  local out rc
  set +e
  out="$($@ 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    fail "$name (expected non-zero rc)"
    echo "$out" >&2
    return
  fi
  pass "$name"
  printf '%s' "$out"
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq "$needle" <<<"$haystack"; then
    pass "$name"
  else
    fail "$name (missing '$needle')"
    echo "$haystack" >&2
  fi
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq "$needle" <<<"$haystack"; then
    fail "$name (unexpected '$needle')"
    echo "$haystack" >&2
  else
    pass "$name"
  fi
}

[[ -x "$WRAPPER" ]] || { echo "wrapper missing: $WRAPPER" >&2; exit 2; }
[[ -f "$ROOT/SANDBOXED-AGENT-AGENTS.md" ]] || { echo "missing canonical file" >&2; exit 2; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
CUSTOM_AGENTS="$TMPD/custom.md"
printf '# custom instruction file\n' > "$CUSTOM_AGENTS"
BAD_FILE="$TMPD/nope.md"

test_cmd() {
  "$WRAPPER" --dry-run-instructions "$@"
}

log "Running matrix in workdir: $WORKDIR"
pushd "$WORKDIR" >/dev/null

# 1) Defaults
out="$(run_expect_success "default dry-run codex exec" test_cmd codex exec "noop")"
assert_contains "default mode suppress" "$out" "project_agents_mode=suppress"
assert_contains "default global source" "$out" "global_agents_source="
assert_contains "default no project mount" "$out" "project_agents_mount=(none)"

# 2) Explicit modes
out="$(run_expect_success "mode repo" test_cmd --project-agents-mode repo codex exec "noop")"
assert_contains "repo mode line" "$out" "project_agents_mode=repo"
assert_contains "repo mount exists" "$out" "project_agents_mount="

out="$(run_expect_success "mode replace" test_cmd --project-agents-mode replace --project-agents-file "$CUSTOM_AGENTS" codex exec "noop")"
assert_contains "replace mode line" "$out" "project_agents_mode=replace"
assert_contains "replace file line" "$out" "project_agents_file=$CUSTOM_AGENTS"

out="$(run_expect_success "mode concat" test_cmd --project-agents-mode concat --project-agents-file "$CUSTOM_AGENTS" codex exec "noop")"
assert_contains "concat mode line" "$out" "project_agents_mode=concat"
assert_contains "concat file line" "$out" "project_agents_file=$CUSTOM_AGENTS"
assert_contains "concat mount file" "$out" "project_agents_concat_"

out="$(run_expect_success "mode suppress explicit" test_cmd --project-agents-mode suppress codex exec "noop")"
assert_contains "suppress mode line" "$out" "project_agents_mode=suppress"
assert_contains "suppress no mount" "$out" "project_agents_mount=(none)"

# 3) Global file override
out="$(run_expect_success "global agents override" test_cmd --global-agents-file "$ROOT/SANDBOXED-AGENT-AGENTS.md" codex exec "noop")"
assert_contains "global override line" "$out" "global_agents_source=$ROOT/SANDBOXED-AGENT-AGENTS.md"

# 4) Instruction profile default mapping
out="$(run_expect_success "instruction profile host-plus-sandbox" test_cmd --instruction-profile host-plus-sandbox codex exec "noop")"
assert_contains "profile line" "$out" "instruction_profile=host-plus-sandbox"
assert_contains "profile mapped concat" "$out" "project_agents_mode=concat"

# 5) Precedence: explicit mode/file should win over profile defaults
out="$(run_expect_success "profile with explicit mode repo" test_cmd --instruction-profile host-plus-sandbox --project-agents-mode repo codex exec "noop")"
assert_contains "explicit mode preserved" "$out" "project_agents_mode=repo"
assert_not_contains "no implicit concat override" "$out" "project_agents_mode=concat"

out="$(run_expect_success "profile with explicit replace file" test_cmd --instruction-profile host-plus-sandbox --project-agents-mode replace --project-agents-file "$CUSTOM_AGENTS" codex exec "noop")"
assert_contains "explicit replace wins" "$out" "project_agents_mode=replace"
assert_contains "explicit replace file wins" "$out" "project_agents_file=$CUSTOM_AGENTS"

# 6) Non-exec codex behavior boundary
out="$(run_expect_success "non-exec codex remains boundary" test_cmd codex --version)"
assert_contains "non-exec marker" "$out" "codex_is_exec=0"
assert_contains "non-exec global unchanged" "$out" "global_agents_source=(unchanged for non-codex-exec)"

# 7) Invalid combinations
out="$(run_expect_fail "replace missing file" test_cmd --project-agents-mode replace codex exec "noop")"
assert_contains "replace missing file msg" "$out" "requires --project-agents-file"

out="$(run_expect_fail "concat missing file" test_cmd --project-agents-mode concat codex exec "noop")"
assert_contains "concat missing file msg" "$out" "requires --project-agents-file"

out="$(run_expect_fail "replace unreadable file" test_cmd --project-agents-mode replace --project-agents-file "$BAD_FILE" codex exec "noop")"
assert_contains "replace unreadable msg" "$out" "project AGENTS file not readable"

out="$(run_expect_fail "invalid mode" test_cmd --project-agents-mode banana codex exec "noop")"
assert_contains "invalid mode msg" "$out" "invalid project AGENTS mode"

out="$(run_expect_fail "invalid profile" test_cmd --instruction-profile banana codex exec "noop")"
assert_contains "invalid profile msg" "$out" "invalid --instruction-profile"

out="$(run_expect_fail "invalid global file" test_cmd --global-agents-file "$BAD_FILE" codex exec "noop")"
assert_contains "invalid global msg" "$out" "global AGENTS file not readable"

# 8) All modes with global override and custom file where required
for mode in suppress repo replace concat; do
  if [[ "$mode" == "replace" || "$mode" == "concat" ]]; then
    out="$(run_expect_success "mode+$mode with global+project file" test_cmd --global-agents-file "$ROOT/SANDBOXED-AGENT-AGENTS.md" --project-agents-mode "$mode" --project-agents-file "$CUSTOM_AGENTS" codex exec "noop")"
  else
    out="$(run_expect_success "mode+$mode with global override" test_cmd --global-agents-file "$ROOT/SANDBOXED-AGENT-AGENTS.md" --project-agents-mode "$mode" codex exec "noop")"
  fi
  assert_contains "mode loop line $mode" "$out" "project_agents_mode=$mode"
done

popd >/dev/null

log "Assertions complete: pass=$PASS fail=$FAIL"
if [[ $FAIL -ne 0 ]]; then
  log "FAILED"
  exit 1
fi
log "PASS"
