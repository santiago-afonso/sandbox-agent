# SANDBOX_CONTAINER_DOCUMENTATION_AND_INSTRUCTIONS.md

This file is intentionally placed in the **workspace** (the repo root) so that an agent running inside `sandbox-agent` can read it from inside the container mount.

## What environment am I running in?

You are running inside a **Podman container** launched by the `sandbox-agent` wrapper script.

Key points:
- The wrapper runs agent CLIs with networking enabled (full egress).
- When running `codex`, the wrapper injects “full yolo” behavior (`--dangerously-bypass-approvals-and-sandbox` + `--sandbox danger-full-access`) unless explicitly disabled.
- Only a bounded set of host paths are mounted into the container (primarily the git workspace + optional RO helper mounts).
- The container working directory is set to the same path as your host `$PWD`, but under the container’s workspace mount.
- When present, host `~/.codex/scripts` is mounted read-only into container `$CODEX_HOME/scripts` (disable via `CODEX_CONTAINER_SANDBOX_DISABLE_SCRIPTS_MOUNT=1`).

## LLM credential passthrough

By default, `sandbox-agent` forwards a curated allowlist of common LLM provider
credential env vars from host to container (only when each variable exists on
the host shell environment):

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

Configure in `~/.config/sandbox-agent/config.sh`:

- Add extra pass-through vars:
  - `CODEX_CONTAINER_SANDBOX_ENV_PASSTHROUGH+=(MY_EXTRA_API_KEY)`
- Disable defaults and provide your own explicit allowlist:
  - `CODEX_CONTAINER_SANDBOX_DISABLE_DEFAULT_ENV_PASSTHROUGH=1`
  - `CODEX_CONTAINER_SANDBOX_ENV_PASSTHROUGH=(VAR_A VAR_B)`

For multiple accounts/projects, switch profiles on the host before launching
`sandbox-agent` so only the active profile vars are propagated.

## WSL / Podman prerequisites (host-side)

If you are running on **WSL2**, modern Podman works best with:

- **systemd enabled** in the distro
- **cgroups-v2 (unified cgroup hierarchy) enabled**

If you see warnings like “Using cgroups-v1 … deprecated”, or errors around missing runtimes, fix the host setup first.

Recommended Windows-side command (PowerShell, from the `os_scripts` repo):

- `windows\\wsl_setup_ubuntu_2404.ps1 -EnableSystemd -EnableCgroupV2 -ShutdownAfter`

Then rebuild the image if needed:

- `cd ~/machine-setup/tools/sandbox-agent && make install`

## Where should I write artifacts?

Write all temporary artifacts to:

- `{workspace}/tmp`

Concretely:
- Use `./tmp/...` relative to the repo root whenever possible.
- Do **not** write to OS temp directories like `/tmp` unless explicitly required; container `/tmp` is ephemeral and harder to discover from the repo.

### Default `tmp/` structure (use these folders)

The wrapper pre-creates these folders on the host (if missing) and attempts to keep them out of `git status`
by adding `tmp/` to `.git/info/exclude` (repo-local, uncommitted).

Use these folders and place files in the most specific bucket:

- `{workspace}/tmp/sandbox-agent/` — wrapper + agent preflight outputs / logs (JSONL streams, debug, repro scripts)
- `{workspace}/tmp/fetched/web/` — webpages and derived snapshots
  - `{workspace}/tmp/fetched/web/raw/` — raw HTML fetches (source-of-truth inputs)
  - `{workspace}/tmp/fetched/web/markdown/` — derived markdown, cleaned HTML, etc.
- `{workspace}/tmp/fetched/pdf/` — PDFs and PDF-derived artifacts
  - `{workspace}/tmp/fetched/pdf/raw/` — downloaded PDFs (source-of-truth inputs)
  - `{workspace}/tmp/fetched/pdf/pages/` — rendered page images (e.g., via `pdftoppm`)
  - `{workspace}/tmp/fetched/pdf/text/` — extracted text (e.g., via `pdftotext`)
- `{workspace}/tmp/fetched/images/` — images and image-derived artifacts
  - `{workspace}/tmp/fetched/images/raw/` — downloaded images (PNG/JPG/SVG, etc.)
  - `{workspace}/tmp/fetched/images/derived/` — crops, conversions, OCR outputs, etc.
- `{workspace}/tmp/fetched/other/` — any other fetched/binary inputs (ZIPs, data dumps, etc.)
  - `{workspace}/tmp/fetched/other/raw/` — original downloads
  - `{workspace}/tmp/fetched/other/derived/` — unpacked or processed outputs

Notes:
- Prefer deterministic, descriptive filenames (include domain/date/slug when practical).
- Keep any “processed” artifacts next to the input folder when it’s clearly tied to a specific fetch (e.g. rendered PDF pages under `tmp/fetched/pdf/<doc-stem>/pages/`).

This includes:
- rendered PDF page images
- extracted markdown
- intermediate JSON/JSONL
- debug dumps and repro scripts

## Tooling available in the container (common)

The container image aims to be largely self-sufficient for common skills:
- PDF triage: `pdfinfo`, `pdftoppm`
- Image manipulation: `convert`, `identify`
- Webpage → markdown: `curl`, `markitdown`
- Document conversions: `pandoc`
- Markdown AST query: `mq`
- Typesetting: `typst`
- Browser automation: `playwright`, `chromium` (headless)
- Local task tracking: `tk` (also available as `ticket`)
- Pi coding agent: `pi` (pi-mono `@mariozechner/pi-coding-agent`)
- Python is **uv-managed** and exposed as `python3` (default target: Python 3.14.x)

## Pi (`pi`) state + mounts

Pi stores its state under:
- `~/.pi/` (auth, sessions, settings)

When running via the `sandbox-agent` wrapper:
- The wrapper mounts a **wrapper-managed** host directory into container `~/.pi/` (RW) so pi sessions and auth persist:
  - Host: `~/.local/state/sandbox-agent/pi`
  - Container: `~/.pi`
- If host `~/.pi/agent` exists, it is mounted **read-only** into the container at `~/.pi-host/agent` so host extensions/prompts are available but cannot be modified by in-container agents.
- Disable pi mounts entirely with: `CODEX_CONTAINER_SANDBOX_DISABLE_PI_MOUNT=1`
- Disable only the host pi agent mount with: `CODEX_CONTAINER_SANDBOX_DISABLE_PI_HOST_AGENT_MOUNT=1`

Run pi in the container:
- `sandbox-agent pi`
- `sandbox-agent pi --help`
- `sandbox-agent-pi` is a convenience wrapper for `sandbox-agent pi ...`

## Certificates / corporate TLS interception

On some corporate networks, TLS is transparently intercepted (MITM) and requires a corporate root CA to be trusted.

This container supports injecting a corporate CA **at image build time** (e.g., via `make install EXTRA_CA_CERT_PATH=...`).

The image also sets common environment variables so tools prefer the system CA bundle:
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`
- `REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`
- `GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt`
- `CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`

## DNS reliability (WSL / short-lived execs)

On some setups (notably WSL2 + rootless Podman), short-lived non-interactive runs can see intermittent DNS failures (e.g. `curl: (6) Could not resolve host`) even when interactive shells appear fine.

The `sandbox-agent` wrapper pins DNS servers by default to improve reliability. If you need to inherit host DNS behavior (or use different resolvers), configure it via `~/.config/sandbox-agent/config.sh` (see `README.md`).

Implementation detail: when DNS override is enabled, the wrapper bind-mounts a generated `/etc/resolv.conf` into the container to bypass Podman DNS forwarders.

## Safety / scope reminders

- Treat the workspace as sensitive (it may include credentials and private content).
- Prefer read-only mounts for host configuration (auth, prompts, skills) unless you explicitly need to write.
- If you need a clean working tree for a commit, do **not** revert user edits; stash/unstash as needed and keep commits narrowly scoped.
