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

pushd "$ROOT" >/dev/null

echo "[selftest] (1/3) Check container internet connectivity..."
"$WRAPPER" --image "$IMAGE" --shell <<'EOF'
set -euo pipefail
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[in-container] missing: $1" >&2; exit 1; }; }
need_cmd curl
curl -fsSI https://example.com >/dev/null
EOF
echo "[selftest] OK: internet connectivity"

echo "[selftest] (2/3) Check host filesystem isolation (no implicit access)..."
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

echo "[selftest] (3/3) Check explicit allowlist mount (RW) works..."
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

popd >/dev/null

echo "[selftest] PASS"
