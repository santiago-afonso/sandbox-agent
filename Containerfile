#
# sandbox-agent Containerfile
#
# Goal: ship a Codex-ready container that is as self-sufficient as practical for
# common skills/tools (PDF triage, webpage→markdown, markdown querying, etc.)
# while keeping host exposure bounded via the wrapper mounts.
#

# ----------------------------
# Builder: mq (mqlang.org)
# ----------------------------
FROM docker.io/library/rust:1-bookworm AS mq_builder

# Optional: add a corporate/WBG root CA for TLS interception environments.
# Pass it as base64 bytes (either PEM or DER) via build arg EXTRA_CA_CERT_B64.
ARG EXTRA_CA_CERT_B64=""
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssl \
  && rm -rf /var/lib/apt/lists/* \
  && if [ -n "${EXTRA_CA_CERT_B64}" ]; then \
      tmp=/tmp/extra-ca-cert.bin; \
      echo "${EXTRA_CA_CERT_B64}" | base64 -d > "${tmp}"; \
      mkdir -p /usr/local/share/ca-certificates; \
      if openssl x509 -in "${tmp}" -noout >/dev/null 2>&1; then \
        cp "${tmp}" /usr/local/share/ca-certificates/extra-ca.crt; \
      elif openssl x509 -inform DER -in "${tmp}" -out /usr/local/share/ca-certificates/extra-ca.crt >/dev/null 2>&1; then \
        true; \
      else \
        echo "Failed to parse EXTRA_CA_CERT_B64 as PEM or DER x509 cert" >&2; \
        exit 2; \
      fi; \
      update-ca-certificates; \
    fi

ARG MQ_VERSION="0.5.9"
RUN git clone --depth 1 --branch "v${MQ_VERSION}" https://github.com/harehare/mq.git /src/mq
WORKDIR /src/mq
RUN cargo install --locked --path crates/mq-run --root /opt/mq
RUN strip /opt/mq/bin/mq >/dev/null 2>&1 || true

# ----------------------------
# Runtime
# ----------------------------
FROM docker.io/library/node:22-bookworm-slim

# Provide a predictable HOME early (and make it writable for arbitrary UIDs).
# We intentionally install uv-managed Python and uv tools under this HOME so
# the wrapper (which sets HOME=/home/codex) can reuse them across host UIDs.
ENV HOME=/home/codex
ENV PATH="/home/codex/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RUN mkdir -p "$HOME" && chmod 0777 "$HOME"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash zsh ca-certificates curl git less openssh-client openssl \
    ripgrep \
    jq \
    # Self-sufficient “skills/tooling” layer:
    # - image-crop: ImageMagick (convert/identify)
    # - read-pdf: Poppler tools (pdfinfo/pdftoppm) + ImageMagick is handy for follow-on crops
    # - read-webpage-content-as-markdown: curl + markitdown
    # - pandoc: document conversion
    imagemagick poppler-utils pandoc \
    # inspection / triage tools
    file binutils xxd \
    # Needed for typst download/extract
    xz-utils \
    # Fonts for Typst output (minimal, broadly available)
    fontconfig fonts-dejavu \
  && rm -rf /var/lib/apt/lists/*

# Optional: add a corporate/WBG root CA for TLS interception environments.
# Pass it as base64 bytes (either PEM or DER) via build arg EXTRA_CA_CERT_B64.
ARG EXTRA_CA_CERT_B64=""
RUN if [ -n "${EXTRA_CA_CERT_B64}" ]; then \
      tmp=/tmp/extra-ca-cert.bin; \
      echo "${EXTRA_CA_CERT_B64}" | base64 -d > "${tmp}"; \
      mkdir -p /usr/local/share/ca-certificates; \
      if openssl x509 -in "${tmp}" -noout >/dev/null 2>&1; then \
        cp "${tmp}" /usr/local/share/ca-certificates/extra-ca.crt; \
      elif openssl x509 -inform DER -in "${tmp}" -out /usr/local/share/ca-certificates/extra-ca.crt >/dev/null 2>&1; then \
        true; \
      else \
        echo "Failed to parse EXTRA_CA_CERT_B64 as PEM or DER x509 cert" >&2; \
        exit 2; \
      fi; \
      update-ca-certificates; \
    fi

# Make the system CA bundle the default for common toolchains/libraries.
# This is important in transparent TLS interception environments where the
# corporate root is installed into the OS certificate store.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt

# WBG TLS interception can present certificates without Authority Key Identifier,
# which breaks Python 3.14+ default HTTPS verification (OpenSSL strict mode).
# We keep verification ON, but disable X509 strict checks in default contexts.
ARG ENABLE_CORP_TLS_WORKAROUNDS="0"
ENV CODEX_PYTHON_SSL_DISABLE_X509_STRICT=${ENABLE_CORP_TLS_WORKAROUNDS}
ENV PYTHONPATH=/usr/local/share/codex-python
RUN mkdir -p /usr/local/share/codex-python \
  && cat > /usr/local/share/codex-python/sitecustomize.py <<'PY'
import os
import ssl

disable_strict = os.environ.get("CODEX_PYTHON_SSL_DISABLE_X509_STRICT", "0").strip().lower()

if disable_strict in {"1", "true", "yes", "on"}:
    original_create_default_context = ssl.create_default_context

    def create_default_context(*args, **kwargs):
        context = original_create_default_context(*args, **kwargs)
        try:
            context.verify_flags &= ~ssl.VERIFY_X509_STRICT
        except Exception:
            pass
        return context

    ssl.create_default_context = create_default_context

    original_create_default_https_context = getattr(ssl, "_create_default_https_context", None)
    if original_create_default_https_context is not None:

        def create_default_https_context(*args, **kwargs):
            context = original_create_default_https_context(*args, **kwargs)
            try:
                context.verify_flags &= ~ssl.VERIFY_X509_STRICT
            except Exception:
                pass
            return context

        ssl._create_default_https_context = create_default_https_context
        ssl._create_stdlib_context = create_default_https_context
PY

# Bring in mq from the builder stage.
COPY --from=mq_builder /opt/mq/bin/mq /usr/local/bin/mq

# Install uv as a standalone binary (not via system Python/pip), then install a
# uv-managed Python and set it as the default.
ARG UV_VERSION="0.9.21"
ARG UV_TARGET="x86_64-unknown-linux-gnu"
ARG UV_DEFAULT_PYTHON="3.14"
ENV UV_NATIVE_TLS=1
ENV UV_MANAGED_PYTHON=1
ENV UV_PYTHON="${UV_DEFAULT_PYTHON}"
RUN curl -fsSL \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TARGET}.tar.gz" \
      -o /tmp/uv.tar.gz \
  && tar -xzf /tmp/uv.tar.gz -C /tmp \
  && install -m 0755 "/tmp/uv-${UV_TARGET}/uv" /usr/local/bin/uv \
  && if [ -f "/tmp/uv-${UV_TARGET}/uvx" ]; then install -m 0755 "/tmp/uv-${UV_TARGET}/uvx" /usr/local/bin/uvx; fi \
  && rm -rf /tmp/uv.tar.gz "/tmp/uv-${UV_TARGET}"
RUN mkdir -p "$HOME/.local/bin" "$HOME/.local/share" && chmod -R 0777 "$HOME/.local"
RUN uv python install --preview-features python-install-default --install-dir "$HOME/.local/share/uv/python" --default --force "${UV_DEFAULT_PYTHON}" \
  && py="$(uv python find --no-project --managed-python "${UV_DEFAULT_PYTHON}")" \
  && ln -sfn "$py" /usr/local/bin/python \
  && ln -sfn "$py" /usr/local/bin/python3

# Install Typst (prebuilt binary).
# We default to musl for portability (no external libc deps).
ARG TYPST_VERSION="0.14.2"
ARG TYPST_TARGET="x86_64-unknown-linux-musl"
RUN curl -fsSL \
      "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${TYPST_TARGET}.tar.xz" \
      -o /tmp/typst.tar.xz \
  && tar -xJf /tmp/typst.tar.xz -C /tmp \
  && install -m 0755 "/tmp/typst-${TYPST_TARGET}/typst" /usr/local/bin/typst \
  && rm -rf "/tmp/typst-${TYPST_TARGET}" /tmp/typst.tar.xz

# Install yq (mikefarah) (prebuilt binary).
ARG YQ_VERSION="4.44.6"
RUN curl -fsSL \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
      -o /usr/local/bin/yq \
  && chmod 0755 /usr/local/bin/yq

# read-webpage-content-as-markdown + read-pdf both rely on `markitdown`.
# Install it as a uv tool (so it's self-contained and uses uv-managed Python).
RUN uv tool install --python "${UV_DEFAULT_PYTHON}" "markitdown[pdf]" \
  && ln -sfn "$HOME/.local/bin/markitdown" /usr/local/bin/markitdown

# Force Node to use the OS CA store (including any EXTRA_CA_CERT_B64 we installed).
ENV NODE_OPTIONS="--use-openssl-ca"
# Make globally-installed npm packages importable from plain `node` scripts.
# Without this, `npm install -g playwright` provides a `playwright` binary but
# `require("playwright")` fails (Node doesn't resolve global modules by default).
ENV NODE_PATH=/usr/local/lib/node_modules

# Install the Codex CLI.
# Allow overriding the npm registry (e.g., corporate mirror) and/or package spec.
ARG NPM_REGISTRY="https://registry.npmjs.org/"
ARG CODEX_NPM_PKG="@openai/codex@latest"
RUN npm config set registry "${NPM_REGISTRY}" \
  && npm config set cafile /etc/ssl/certs/ca-certificates.crt \
  && npm install -g "${CODEX_NPM_PKG}"

# Install GitHub Copilot CLI (prerelease).
ARG COPILOT_NPM_PKG="@github/copilot@prerelease"
RUN npm install -g "${COPILOT_NPM_PKG}"

# Playwright + headless Chromium (for JS/client-rendered pages).
#
# Notes:
# - We install a system chromium as a fallback.
# - We also install Playwright and (by default) its bundled Chromium browser so
#   "playwright chromium" works out-of-the-box.
ARG INSTALL_PLAYWRIGHT_BROWSERS="1"
ARG PLAYWRIGHT_NPM_PKG="playwright@latest"
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
  && rm -rf /var/lib/apt/lists/*
RUN npm install -g "${PLAYWRIGHT_NPM_PKG}" \
  && if [ "${INSTALL_PLAYWRIGHT_BROWSERS}" = "1" ]; then \
       playwright install chromium; \
     fi

# Install tk/ticket (minimal git-backed ticket tracker).
# We pin to an expected SHA256 so upstream changes fail loudly and require an
# intentional update here.
ARG TICKET_URL="https://raw.githubusercontent.com/wedow/ticket/refs/heads/master/ticket"
ARG TICKET_SHA256="a7ca164d8c511c2368c13e174f42c7c4af9008a5de9aa31c9550edd9b71d6f8f"
RUN curl -fsSL "${TICKET_URL}" -o /usr/local/bin/ticket \
  && if [ -n "${TICKET_SHA256}" ]; then echo "${TICKET_SHA256}  /usr/local/bin/ticket" | sha256sum -c -; fi \
  && chmod 0755 /usr/local/bin/ticket \
  && ln -sfn /usr/local/bin/ticket /usr/local/bin/tk \
  # Some tool runners sanitize PATH to /usr/bin:/bin. Ensure tk is still found.
  && ln -sfn /usr/local/bin/ticket /usr/bin/ticket \
  && ln -sfn /usr/local/bin/ticket /usr/bin/tk

# Keep the shared HOME writable for arbitrary UIDs.
RUN chmod 0777 "$HOME"
WORKDIR /home/codex
