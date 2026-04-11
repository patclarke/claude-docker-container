# claude-docker-sandbox

A small wrapper (`cc`) that runs Claude Code inside a Docker Sandbox
(`sbx`) microVM, so `--dangerously-skip-permissions` becomes a bounded risk
instead of an unbounded one.

## Status

Design phase. See [`docs/specs/`](docs/specs/) for the design spec.
The implementation script has not been written yet.

## Overview

`cc` is a thin bash wrapper around [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
that:

- Mounts the launch directory read-write into a microVM
- Mounts a configurable allow-list of host paths read-only for context
  (e.g. `~/workspace`, `~/Desktop`, `~/Downloads`)
- Shares `~/.claude` read-write so sessions persist across host ↔ sandbox
- Forwards all non-`--cc-*` flags to `claude` inside the sandbox
- Runs preflight checks (sbx installed, Docker running, sbx authenticated,
  `~/.claude` writable)
- Auto-starts Docker Desktop if it isn't running

More details will land here as the implementation comes together.

## License

MIT — see [`LICENSE`](LICENSE).
