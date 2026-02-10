# sandbox-agent

A Podman wrapper that runs agent CLIs (primarily `codex`, but also `copilot`, `opencode`, and `pi`) inside a container.

For `codex`, it always uses:

- `--search` (web search tool availability)
- `--config web_search=live|cached|disabled` (defaults to `cached`, or uses host `~/.codex/config.toml` if set)

Networking is enabled (full egress).

## Quick start

### 1) Build an image

You need an image that includes `codex`, `git`, `bash`, and `uv` (plus a Python runtime; this image uses **uv-managed Python** by default, and exposes it as `python3` in the container).
Use `Containerfile`:

```bash
podman build -t localhost/sandbox-agent:latest -f Containerfile .
```

Or use the Makefile (also installs the wrapper):

```bash
make install
```

If you're on a corporate network with an npm mirror, override the registry:

```bash
make install NPM_REGISTRY=https://your-registry.example.com/
```

If TLS is intercepted (transparent proxy / self-signed in chain), pass a corporate root CA cert:

```bash
make install EXTRA_CA_CERT_PATH=$HOME/wbg_root_ca_g2.cer
```

If `EXTRA_CA_CERT_PATH` is not set, the Makefile auto-detects the WBG root cert
only on the WBG laptop hostname (`PCACL-G7MKN94`) by checking:

- `~/wbg_root_ca_g2.cer` (local machine file), or
- `../../wbg_root_ca_g2.cer` (when vendored inside a parent repo, e.g. `machine-setup`)

This cert is **not** stored in the repo; it’s a local machine file and should not be committed.

You can also override bundled tool versions:

```bash
make install MQ_VERSION=0.5.9 TYPST_VERSION=0.14.2 TYPST_TARGET=x86_64-unknown-linux-musl
```

Override the default uv-managed Python version:

```bash
make install UV_DEFAULT_PYTHON=3.14
```

You can also override the bundled uv binary version (rarely needed):

```bash
make install UV_VERSION=0.9.21
```

If you want a smaller build (skip Playwright’s bundled browser download), set:

```bash
make install INSTALL_PLAYWRIGHT_BROWSERS=0
```

### 2) Install the wrapper

```bash
install -m 0755 ./sandbox-agent ~/.local/bin/sandbox-agent
install -m 0755 ./sandbox-agent-codex ~/.local/bin/sandbox-agent-codex
install -m 0755 ./sandbox-agent-copilot ~/.local/bin/sandbox-agent-copilot
install -m 0755 ./sandbox-agent-opencode ~/.local/bin/sandbox-agent-opencode
install -m 0755 ./sandbox-agent-pi ~/.local/bin/sandbox-agent-pi
```

### 3) (Optional) Configure mounts

Create `~/.config/sandbox-agent/config.sh`:

```bash
CODEX_CONTAINER_SANDBOX_IMAGE="localhost/sandbox-agent:latest"

# Optional: force an OCI runtime (useful on some WSL/work setups).
# CODEX_CONTAINER_SANDBOX_PODMAN_RUNTIME="runc"

# Optional: override DNS servers used inside the container (default is pinned).
# Disable the override to inherit host/Podman DNS behavior:
# CODEX_CONTAINER_SANDBOX_DISABLE_DNS_OVERRIDE=1
# Or override the server list (in order):
# CODEX_CONTAINER_SANDBOX_DNS_SERVERS=(45.90.28.212 45.90.30.212 1.1.1.1 8.8.8.8)
#
# Note: When DNS override is enabled, the wrapper bind-mounts a generated
# /etc/resolv.conf into the container to bypass Podman DNS forwarders (often a
# 169.254.x.x hop).

# Mount helper tools read-only (mapped under /home/codex/...)
CODEX_CONTAINER_SANDBOX_RO_MOUNTS=(
  "$HOME/.local/bin"
  "$HOME/bin"
)

# Persist caches if needed
CODEX_CONTAINER_SANDBOX_RW_MOUNTS=(
  "$HOME/.cache/uv"
  "$HOME/tmp"
)

# Optional: add host env vars to pass through into the container.
# Defaults already include common LLM providers + AWS Bedrock credentials.
# CODEX_CONTAINER_SANDBOX_ENV_PASSTHROUGH+=(MY_EXTRA_API_KEY)
#
# Optional: disable default passthrough list, then define an explicit allowlist.
# CODEX_CONTAINER_SANDBOX_DISABLE_DEFAULT_ENV_PASSTHROUGH=1
# CODEX_CONTAINER_SANDBOX_ENV_PASSTHROUGH=(
#   GEMINI_API_KEY
#   GOOGLE_API_KEY
# )
```

## Usage

### Default: zsh shell in container

```bash
sandbox-agent
```

### Codex (full network)

```bash
sandbox-agent codex exec "Summarize the repo"
```

### Pi (pi-mono coding agent)

```bash
sandbox-agent pi
```

`pi` is available in the image, but sandbox-agent does not auto-install pi
plugins/packages. Install only what you need in your `~/.pi/` state.

### Makefile helpers

From the repo root:

```bash
make image
make selftest
make pii-scan
make validate-docs
```

### Self-test (network + mount isolation)

Runs three checks:

1. Container has internet connectivity.
2. Host files outside the workspace are not visible by default.
3. An explicitly mounted host directory is readable and writable (RW mount).

```bash
./selftest.sh
```

### Shell inside container

```bash
sandbox-agent --shell
```

### Debug the podman command

```bash
CODEX_CONTAINER_SANDBOX_DEBUG=1 sandbox-agent codex exec "hello"
```

### Hide the printed `codex ...` command

By default the wrapper prints the computed `codex ...` command (to stderr) before starting.
Disable with:

```bash
sandbox-agent --no-print-codex-cmd codex exec "hello"
```

### Git commit identity

To avoid `git commit` failing with “Author identity unknown”, the wrapper will (by default)
copy `user.name` / `user.email` from the host git config into a persistent container-global
gitconfig under `CODEX_HOME`, and set `GIT_CONFIG_GLOBAL` accordingly.

Override (or set explicitly if host identity is not set):

```bash
CODEX_CONTAINER_SANDBOX_GIT_NAME="Your Name" \
CODEX_CONTAINER_SANDBOX_GIT_EMAIL="you@domain" \
  sandbox-agent ...
```

Disable:

```bash
CODEX_CONTAINER_SANDBOX_DISABLE_GIT_IDENTITY_SYNC=1 sandbox-agent ...
```

## Mount behavior

- If you run inside a git repo, the **repo root** is mounted read-write.
- The container working directory is set to your original `$PWD` inside that mount.
- Extra mounts under `$HOME` are mapped to the same relative path under `/home/codex`.
- `XDG_CACHE_HOME` is set to `$CODEX_HOME/cache` so tools like `uv` have a writable cache by default.
- Pi state in the container lives under `~/.pi/`, backed by a wrapper-managed host directory: `~/.local/state/sandbox-agent/pi` (disable with `CODEX_CONTAINER_SANDBOX_DISABLE_PI_MOUNT=1`).
- If host `~/.pi/agent` exists, it is mounted read-only into the container at `~/.pi-host/agent` so you can reuse host extensions/prompts without allowing in-container mutation (disable with `CODEX_CONTAINER_SANDBOX_DISABLE_PI_HOST_AGENT_MOUNT=1`).
- sandbox-agent does not seed pi harness plugins into `~/.pi/agent/settings.json`.

## Auth

Codex credentials live in `CODEX_HOME` (`~/.local/state/sandbox-agent` by default).
Login once inside the container:

```bash
sandbox-agent --shell
codex login
```

### Reuse host auth.json (optional)

If you already have a working host login (for example `~/.codex/auth.json`), you can mount it
into the container so `codex` doesn't prompt for login again:

- Auto-detects and mounts `~/.codex/auth.json` if it exists.
- Override the path with `CODEX_CONTAINER_SANDBOX_AUTH_FILE=/path/to/auth.json`.
- Disable mounting entirely with `CODEX_CONTAINER_SANDBOX_DISABLE_AUTH_MOUNT=1`.
- Control mount mode (default `ro`) with `CODEX_CONTAINER_SANDBOX_AUTH_MOUNT_MODE=ro|rw`.

### Reuse host prompts and skills (optional)

To keep prompts and skills consistent with your host setup, the wrapper can also mount:

- `~/.codex/prompts` -> `$CODEX_HOME/prompts` (read-only)
- `~/.codex/skills` -> `$CODEX_HOME/skills` (read-only)

Controls:

- Override paths:
  - `CODEX_CONTAINER_SANDBOX_PROMPTS_DIR=/path/to/prompts`
  - `CODEX_CONTAINER_SANDBOX_SKILLS_DIR=/path/to/skills`
- Disable:
  - `CODEX_CONTAINER_SANDBOX_DISABLE_PROMPTS_MOUNT=1`
  - `CODEX_CONTAINER_SANDBOX_DISABLE_SKILLS_MOUNT=1`

## LLM env passthrough

The wrapper forwards a default allowlist of provider credential environment
variables from host to container (only when each variable is present on host):

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`
- `GOOGLE_API_KEY`
- `GOOGLE_GENAI_API_KEY`
- `AZURE_OPENAI_API_KEY`
- `AZURE_OPENAI_ENDPOINT`
- `ELEVENLABS_API_KEY`
- `MISTRAL_API_KEY`
- `COHERE_API_KEY`
- `GROQ_API_KEY`
- `PERPLEXITY_API_KEY`
- `TOGETHER_API_KEY`
- `FIREWORKS_API_KEY`
- `OPENROUTER_API_KEY`
- `XAI_API_KEY`
- `DEEPSEEK_API_KEY`
- `CEREBRAS_API_KEY`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`
- `AWS_REGION`
- `AWS_DEFAULT_REGION`
- `AWS_PROFILE`

Customization:

- Add extra vars in `~/.config/sandbox-agent/config.sh`:
  - `CODEX_CONTAINER_SANDBOX_ENV_PASSTHROUGH+=(MY_EXTRA_API_KEY)`
- Replace defaults with your own explicit list:
  - `CODEX_CONTAINER_SANDBOX_DISABLE_DEFAULT_ENV_PASSTHROUGH=1`
  - `CODEX_CONTAINER_SANDBOX_ENV_PASSTHROUGH=(VAR_A VAR_B)`

### Reuse host helper CLIs (read-pdf)

If you have `read-pdf` installed on the host at `~/.local/bin/read-pdf`, the wrapper will
mount that executable (and its helper scripts like `read_pdf_page_candidates.py`) read-only
into the container (without mounting the entire `~/.local/bin` directory) so it is available
on the container `$PATH`.

Disable with:

```bash
CODEX_CONTAINER_SANDBOX_DISABLE_LOCAL_BIN_MOUNT=1 sandbox-agent ...
```

### Built-in tools (image is self-sufficient)

The image ships with a few common “skills dependencies” so you don’t need host mounts:

- `imagemagick` (`convert`, `identify`) for `image-crop`
- `poppler-utils` (`pdfinfo`, `pdftoppm`) for `read-pdf --as-images`
- `markitdown` for `read-webpage-content-as-markdown` and `read-pdf --as-text-fast`
- `pandoc`
- `mq`
- `typst`
- `chromium` + `playwright` (JS/client-rendered pages)

### Reuse host CLIs (optional; for extra tools/versions)

If you install CLIs on the host via:

- `uv tool install ...` (often creates symlinks under `~/.local/bin` pointing at `~/.local/share/uv/tools/...`)

the wrapper can mount the needed host directories read-only so those tools work inside the container.

Defaults (best-effort, only when detected):

- Mount `~/.local/share/uv/tools` read-only when `ttok` is detected as a uv tool install.
- Also mount `~/.local/share/uv/python` read-only (needed for uv tool shebang interpreters) when present.

Disable:

```bash
CODEX_CONTAINER_SANDBOX_DISABLE_UV_TOOLS_MOUNT=1 sandbox-agent ...
CODEX_CONTAINER_SANDBOX_DISABLE_UV_PYTHON_MOUNT=1 sandbox-agent ...
```

## Security note

This wrapper is about **filesystem isolation** (mount boundaries), not egress safety.
Because this runs full yolo with full networking, the agent can exfiltrate anything it can
read inside the container (including anything you mount, and `CODEX_HOME/auth.json`).
