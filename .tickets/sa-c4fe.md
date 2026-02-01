---
id: sa-c4fe
status: closed
deps: []
links: []
created: 2026-02-01T17:09:33Z
type: task
priority: 2
assignee: Santiago Afonso
---
# Fix image build + pi agent support

Context: podman image build fails at ticket/tk install step due to sha256 mismatch; also need pi-mono coding-agent to work in sandbox-agent container.\n\nTest plan:\n- make image (or make install) succeeds\n- inside container: tk --version works\n- inside container: pi agent can read/write under ~/.pi (smoke run)\n- selftest.sh passes

## Acceptance Criteria

- Container image builds without checksum errors\n- ticket/tk installed in image and callable\n- sandbox-agent supports mounting ~/.pi (and any required config) so pi agent runs without auth/state issues\n- Documentation updated if mount behavior changes

