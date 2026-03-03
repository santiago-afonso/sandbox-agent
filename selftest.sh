#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER="$ROOT/sandbox-agent"

IMAGE_DEFAULT="localhost/sandbox-agent:latest"
IMAGE="${CODEX_CONTAINER_SANDBOX_IMAGE:-$IMAGE_DEFAULT}"

# Selftests should not mutate the repo by auto-initializing Beads or creating
# sync branches/worktrees.
export CODEX_CONTAINER_SANDBOX_DISABLE_BD_AUTO_INIT=1

die() {
  echo "[selftest] ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

PODMAN_BIN="${CODEX_CONTAINER_SANDBOX_PODMAN:-podman}"
if [[ "$PODMAN_BIN" != */* ]] && ! command -v "$PODMAN_BIN" >/dev/null 2>&1; then
  if [[ -x "/home/linuxbrew/.linuxbrew/bin/podman" ]]; then
    PODMAN_BIN="/home/linuxbrew/.linuxbrew/bin/podman"
  fi
fi

# If we resolved to Homebrew podman, make sure Homebrew bin is on PATH so podman
# can find helper binaries like `conmon`.
if [[ "$PODMAN_BIN" == "/home/linuxbrew/.linuxbrew/bin/podman" ]]; then
  case ":${PATH:-}:" in
    *":/home/linuxbrew/.linuxbrew/bin:"*) ;;
    *) export PATH="/home/linuxbrew/.linuxbrew/bin:${PATH:-}" ;;
  esac
fi

export CODEX_CONTAINER_SANDBOX_PODMAN="$PODMAN_BIN"
if [[ "$PODMAN_BIN" == */* ]]; then
  [[ -x "$PODMAN_BIN" ]] || die "missing required command: $PODMAN_BIN"
else
  need_cmd "$PODMAN_BIN"
fi
need_cmd mktemp

[[ -x "$WRAPPER" ]] || die "wrapper not executable or missing: $WRAPPER"

cleanup() {
  if [[ -n "${TMP_HOST_DIR:-}" && -d "${TMP_HOST_DIR:-}" ]]; then
    rm -rf "$TMP_HOST_DIR"
  fi
}
trap cleanup EXIT

echo "[selftest] Using image: $IMAGE"
echo "[selftest] Using wrapper: $WRAPPER"

if ! "$PODMAN_BIN" image exists "$IMAGE" >/dev/null 2>&1; then
  cat >&2 <<EOF
[selftest] Image not found: $IMAGE

Build it with:
  "$PODMAN_BIN" build -t "$IMAGE_DEFAULT" -f "$ROOT/Containerfile" "$ROOT"

	Or override with:
	  CODEX_CONTAINER_SANDBOX_IMAGE=... $0
EOF
  exit 2
fi

TMP_HOST_DIR="$(mktemp -d)"
HOST_SENTINEL="$TMP_HOST_DIR/host_sentinel.txt"
HOST_SENTINEL_CONTENT="host_sentinel_$(date +%s)_$RANDOM"
printf '%s\n' "$HOST_SENTINEL_CONTENT" >"$HOST_SENTINEL"
INSTRUCTION_TEST_SCRIPT="$ROOT/scripts/test_instruction_flags.sh"
CANONICAL_GLOBAL_AGENTS="$ROOT/SANDBOXED-AGENT-AGENTS.md"
OPENCODE_AGENTS_HOST=""
if [[ -d "$HOME/.config/opencode/agents" ]]; then
  OPENCODE_AGENTS_HOST="$(readlink -f "$HOME/.config/opencode/agents" 2>/dev/null || echo "$HOME/.config/opencode/agents")"
elif [[ -d "$HOME/.agents/subagents/generated/opencode/agents" ]]; then
  OPENCODE_AGENTS_HOST="$(readlink -f "$HOME/.agents/subagents/generated/opencode/agents" 2>/dev/null || echo "$HOME/.agents/subagents/generated/opencode/agents")"
fi

pushd "$ROOT" >/dev/null

echo "[selftest] (1/7) Check container internet connectivity..."
"$WRAPPER" --image "$IMAGE" --shell <<'EOF'
set -euo pipefail
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[in-container] missing: $1" >&2; exit 1; }; }
need_cmd curl
curl -fsSI https://example.com >/dev/null
EOF
echo "[selftest] OK: internet connectivity"

echo "[selftest] (2/7) Check Playwright + Chromium are usable..."
"$WRAPPER" --image "$IMAGE" --shell <<'EOF'
set -euo pipefail
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[in-container] missing: $1" >&2; exit 1; }; }

need_cmd node
need_cmd playwright
need_cmd chromium

node -e 'require("playwright"); console.log("ok: require(playwright)");'
chromium --version >/dev/null
EOF
echo "[selftest] OK: playwright/chromium present"

echo "[selftest] (3/7) Check Codex + OpenCode CLIs are usable..."
"$WRAPPER" --image "$IMAGE" --shell <<'EOF'
set -euo pipefail
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[in-container] missing: $1" >&2; exit 1; }; }
need_cmd codex
need_cmd opencode
codex --version >/dev/null
opencode --version >/dev/null
EOF
echo "[selftest] OK: codex/opencode present"

echo "[selftest] (4/7) Check host filesystem isolation (no implicit access)..."
"$WRAPPER" --image "$IMAGE" --shell <<EOF
set -euo pipefail

		# Sanity: this repo's files should be visible from the container workdir.
	test -f README.md
	test -f Containerfile
	test -x ./sandbox-agent

# The host-created file is outside the workspace and NOT mounted, so it must not exist.
test ! -e "$HOST_SENTINEL"
EOF
echo "[selftest] OK: host-only path not visible without explicit mount"

echo "[selftest] (5/7) Check explicit allowlist mount (RW) works..."
"$WRAPPER" --image "$IMAGE" --rw "$TMP_HOST_DIR" --shell <<EOF
set -euo pipefail

test -f "$HOST_SENTINEL"
got="\$(cat "$HOST_SENTINEL")"
test "\$got" = "$HOST_SENTINEL_CONTENT"

echo "wrote_from_container" >"$TMP_HOST_DIR/wrote_from_container.txt"
EOF

test -f "$TMP_HOST_DIR/wrote_from_container.txt"
test "$(cat "$TMP_HOST_DIR/wrote_from_container.txt")" = "wrote_from_container"
echo "[selftest] OK: RW mount works as expected"

echo "[selftest] (6/7) Check OpenCode agents mount wiring (read-only)..."
if [[ -n "${OPENCODE_AGENTS_HOST:-}" ]]; then
  dry_run_output="$("$WRAPPER" --image "$IMAGE" --dry-run-instructions opencode agent list)"
  expected_mount_line="[sandbox-agent] opencode_agents_mount=${OPENCODE_AGENTS_HOST} -> /home/codex/.config/opencode/agents:ro"
  grep -Fq "$expected_mount_line" <<<"$dry_run_output" || die "dry-run missing expected OpenCode agents mount line"
  "$WRAPPER" --image "$IMAGE" --shell <<'EOF'
set -euo pipefail
test -d "$HOME/.config/opencode/agents"
probe="$HOME/.config/opencode/agents/.sandbox_agent_ro_probe_$$"
if echo "probe" >"$probe" 2>/dev/null; then
  rm -f "$probe" || true
  echo "[in-container] expected read-only OpenCode agents mount; write succeeded" >&2
  exit 1
fi
EOF
  echo "[selftest] OK: OpenCode agents mount wired read-only"
else
  echo "[selftest] SKIP: no host OpenCode agents dir found (~/.config/opencode/agents or ~/.agents/subagents/generated/opencode/agents)"
fi

if [[ -d "$HOME/.agents" ]]; then
  set +e
  rw_guard_output="$("$WRAPPER" --image "$IMAGE" --rw "$HOME/.agents" --shell <<'EOF' 2>&1
true
EOF
)"
  rw_guard_status=$?
  set -e
  if [[ "$rw_guard_status" -eq 0 ]]; then
    die "wrapper unexpectedly allowed --rw mount overlapping ~/.agents"
  fi
  grep -Fq "refusing RW mount overlapping ~/.agents" <<<"$rw_guard_output" \
    || die "missing expected ~/.agents RW-overlap guard message"
  echo "[selftest] OK: wrapper rejects RW mounts overlapping ~/.agents"
else
  echo "[selftest] SKIP: no host ~/.agents directory found for RW-overlap guard"
fi

echo "[selftest] (7/7) Check instruction wiring and AGENTS flag matrix..."
[[ -f "$CANONICAL_GLOBAL_AGENTS" ]] || die "missing canonical AGENTS file: $CANONICAL_GLOBAL_AGENTS"
[[ -x "$INSTRUCTION_TEST_SCRIPT" ]] || die "missing or non-executable instruction test script: $INSTRUCTION_TEST_SCRIPT"
"$INSTRUCTION_TEST_SCRIPT"
echo "[selftest] OK: instruction flag matrix"

popd >/dev/null

echo "[selftest] PASS"
