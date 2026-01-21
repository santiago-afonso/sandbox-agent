---
id: sa-9ad8
status: closed
deps: []
links: []
created: 2026-01-21T18:51:43Z
type: task
priority: 2
assignee: Santiago Afonso
---
# Refresh ticket checksum for sandbox-agent build

Context: image build failed at ticket install due to upstream SHA change. Test plan: make install.

## Acceptance Criteria

TICKET_SHA256 updated in Containerfile and Makefile; make install succeeds.

