.PHONY: help image install install-wrapper selftest pii-scan validate-docs

PODMAN ?= podman
PODMAN_RUNTIME ?=

IMAGE ?= localhost/sandbox-agent:latest
# NOTE: Some corporate networks MITM/TLS-intercept npmjs.org in ways that
# manifest as ECONNRESET. The npmjs.com alias often behaves better.
NPM_REGISTRY ?= https://registry.npmjs.com/
CODEX_NPM_PKG ?= @openai/codex@latest
EXTRA_CA_CERT_PATH ?=
MQ_VERSION ?= 0.5.9
TYPST_VERSION ?= 0.14.2
TYPST_TARGET ?= x86_64-unknown-linux-musl
UV_VERSION ?= 0.9.22
UV_TARGET ?= x86_64-unknown-linux-gnu
UV_DEFAULT_PYTHON ?= 3.14
YQ_VERSION ?= 4.50.1
INSTALL_PLAYWRIGHT_BROWSERS ?= 1
PLAYWRIGHT_NPM_PKG ?= playwright@latest
# NOTE: We intentionally pin ticket/tk to a tag/commit + SHA256 so builds fail
# loudly if upstream changes (rather than silently pulling a different script).
TICKET_URL ?= https://raw.githubusercontent.com/wedow/ticket/v0.3.1/ticket
TICKET_SHA256 ?= ebe5b4af28525fd336b818b2ef0c681396af2023a24b6850c60df3be1764d7ab

# Pi (pi-mono coding-agent)
PI_NPM_PKG ?= @mariozechner/pi-coding-agent@latest
INSTALL_PI_PACKAGES ?= 1

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

help:
	@echo "sandbox-agent"
	@echo
	@echo "Targets:"
	@echo "  image          Build the container image (IMAGE=$(IMAGE))"
	@echo "  install        Build image + symlink wrapper into ~/.local/bin"
	@echo "  install-wrapper  Symlink wrapper into ~/.local/bin (no image build)"
	@echo "  selftest       Run network + mount isolation self-test"
	@echo "  pii-scan       Scan repo for common secret/PII patterns"
	@echo "  validate-docs  Validate README paths for standalone repo use"

image:
	@podman_bin="$(PODMAN)"; \
	brew_bin="/home/linuxbrew/.linuxbrew/bin"; \
	if [ -d "$$brew_bin" ]; then \
		case ":$$PATH:" in *":$$brew_bin:"*) ;; *) export PATH="$$brew_bin:$$PATH";; esac; \
	fi; \
	if [ -x "$$podman_bin" ]; then \
		:; \
	elif command -v "$$podman_bin" >/dev/null 2>&1; then \
		podman_bin="$$(command -v "$$podman_bin")"; \
	elif [ -x "/home/linuxbrew/.linuxbrew/bin/podman" ]; then \
		podman_bin="/home/linuxbrew/.linuxbrew/bin/podman"; \
	fi; \
	if [ ! -x "$$podman_bin" ]; then \
		echo "$(PODMAN) not found on PATH (and no Homebrew fallback at /home/linuxbrew/.linuxbrew/bin/podman)" >&2; \
		exit 1; \
	fi; \
	extra_ca_arg=""; \
	extra_ca_path="$(EXTRA_CA_CERT_PATH)"; \
	runtime_arg=""; \
	if [ -n "$(PODMAN_RUNTIME)" ]; then \
		runtime_arg="--runtime $(PODMAN_RUNTIME)"; \
	else \
		# On WSL2, some environments ship a too-old/broken `crun` as the Podman default, \
		# which can fail with `crun: unknown version specified`. Prefer `runc` when present. \
		if grep -qi microsoft /proc/version 2>/dev/null; then \
			if command -v runc >/dev/null 2>&1; then runtime_arg="--runtime runc"; fi; \
		fi; \
	fi; \
	# Only auto-detect the WBG root cert on the IT-managed WBG laptop. \
	# On other machines (e.g., home), do not attempt corporate CA injection unless explicitly configured. \
	if [ -z "$$extra_ca_path" ] && [ "$$(hostname 2>/dev/null || true)" = "PCACL-G7MKN94" ]; then \
		if [ -r "$$HOME/wbg_root_ca_g2.cer" ]; then \
			extra_ca_path="$$HOME/wbg_root_ca_g2.cer"; \
			echo "Auto-detected EXTRA_CA_CERT_PATH=$$extra_ca_path" >&2; \
		elif [ -r "$(CURDIR)/../../wbg_root_ca_g2.cer" ]; then \
			# When sandbox-agent is vendored inside machine-setup, the cert may live at repo root. \
			extra_ca_path="$(CURDIR)/../../wbg_root_ca_g2.cer"; \
			echo "Auto-detected EXTRA_CA_CERT_PATH=$$extra_ca_path" >&2; \
		fi; \
	fi; \
	if [ -n "$$extra_ca_path" ]; then \
		if [ ! -r "$$extra_ca_path" ]; then \
			echo "EXTRA_CA_CERT_PATH is set but not readable: $$extra_ca_path" >&2; \
			exit 2; \
		fi; \
		extra_ca_b64="$$(base64 -w 0 "$$extra_ca_path" 2>/dev/null || base64 "$$extra_ca_path" | tr -d '\n')"; \
		extra_ca_arg="--build-arg EXTRA_CA_CERT_B64=$$extra_ca_b64"; \
	fi; \
	# Enable Python/OpenSSL strict-mode workaround only when we are injecting a corporate CA. \
	tls_workaround_arg="--build-arg ENABLE_CORP_TLS_WORKAROUNDS=0"; \
	if [ -n "$$extra_ca_path" ]; then \
		tls_workaround_arg="--build-arg ENABLE_CORP_TLS_WORKAROUNDS=1"; \
	fi; \
	"$$podman_bin" build $$runtime_arg \
		$$extra_ca_arg \
		$$tls_workaround_arg \
		--build-arg MQ_VERSION="$(MQ_VERSION)" \
		--build-arg TYPST_VERSION="$(TYPST_VERSION)" \
		--build-arg TYPST_TARGET="$(TYPST_TARGET)" \
		--build-arg UV_VERSION="$(UV_VERSION)" \
		--build-arg UV_TARGET="$(UV_TARGET)" \
		--build-arg UV_DEFAULT_PYTHON="$(UV_DEFAULT_PYTHON)" \
		--build-arg YQ_VERSION="$(YQ_VERSION)" \
		--build-arg INSTALL_PLAYWRIGHT_BROWSERS="$(INSTALL_PLAYWRIGHT_BROWSERS)" \
			--build-arg PLAYWRIGHT_NPM_PKG="$(PLAYWRIGHT_NPM_PKG)" \
			--build-arg TICKET_URL="$(TICKET_URL)" \
			--build-arg TICKET_SHA256="$(TICKET_SHA256)" \
			--build-arg PI_NPM_PKG="$(PI_NPM_PKG)" \
			--build-arg INSTALL_PI_PACKAGES="$(INSTALL_PI_PACKAGES)" \
			--build-arg NPM_REGISTRY="$(NPM_REGISTRY)" \
			--build-arg CODEX_NPM_PKG="$(CODEX_NPM_PKG)" \
			-t "$(IMAGE)" -f Containerfile .

install: image install-wrapper

install-wrapper:
	@mkdir -p "$(BINDIR)"
	@ln -sfn "$(CURDIR)/sandbox-agent" "$(BINDIR)/sandbox-agent"
	@ln -sfn "$(CURDIR)/sandbox-agent-codex" "$(BINDIR)/sandbox-agent-codex"
	@ln -sfn "$(CURDIR)/sandbox-agent-copilot" "$(BINDIR)/sandbox-agent-copilot"
	@ln -sfn "$(CURDIR)/sandbox-agent-opencode" "$(BINDIR)/sandbox-agent-opencode"
	@ln -sfn "$(CURDIR)/sandbox-agent-pi" "$(BINDIR)/sandbox-agent-pi"
	@echo "Installed: $(BINDIR)/sandbox-agent -> $(CURDIR)/sandbox-agent"

selftest:
	./selftest.sh

pii-scan:
	./scripts/pii_scan.sh

validate-docs:
	./scripts/validate_docs.sh
