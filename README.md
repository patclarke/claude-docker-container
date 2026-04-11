# claude-docker-sandbox

`cc` — a small bash wrapper that runs [Claude Code](https://claude.com/claude-code)
inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) microVM, so
unsupervised agents have a bounded blast radius instead of an unbounded one.

> **Status:** Core implementation complete. Live sandbox testing verified. See
> [Roadmap](#roadmap) for remaining work.

## What this solves

Running `claude` on a trusted developer machine with unsupervised shell access
is a calculated but unbounded risk: a runaway agent can touch anything the user
can touch. Docker Sandboxes give each agent its own microVM with its own
filesystem, Docker daemon, and network, so a runaway agent is contained to what
you explicitly mount in.

`cc` is a thin shell wrapper around Docker's `sbx` CLI that:

- Mounts your current working directory **read-write** into the sandbox
- Mounts a configurable allow-list of host paths for context
  (e.g. `~/workspace` for cross-project references, `~/Desktop` / `~/Downloads`
  for ad-hoc file sharing)
- Shares `~/.claude/projects` **read-write** so sessions persist across runs
  and are visible from both host `claude` and sandboxed `cc`
- Shares `~/.claude/plugins`, `~/.claude/skills`, and `~/.claude/CLAUDE.md`
  **read-only** so your tools and config are available without letting a sandbox
  session tamper with them
- Shares `~/.aws`, `~/.config/gh`, and `~/.ssh` **read-only** so credentials
  work without letting the agent overwrite them
- Auto-injects your Claude Code credentials from the macOS Keychain on every
  invocation, so the sandbox is authenticated without any manual login step
- Forwards every non-`--cc-*` flag to `claude` inside the sandbox
- Runs preflight checks (sbx installed, Docker running, sbx authenticated,
  `~/.claude` writable) and auto-starts Docker Desktop if it isn't already up

## Prerequisites

- **Docker Desktop** (macOS / Windows / Linux)
- **sbx CLI**
  ```console
  # macOS
  brew install docker/tap/sbx

  # Windows
  winget install -h Docker.sbx

  # Linux (Ubuntu)
  curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
  sudo apt-get install docker-sbx
  sudo usermod -aG kvm $USER
  newgrp kvm
  ```
- One-time login:
  ```console
  sbx login
  ```
- **Claude Code** installed on the host (`cc` still needs a host binary for its
  escape hatch; see [Escape hatch](#escape-hatch))

## Install

> Not yet available. Install instructions will land here once the `cc` script
> ships. Planned form:
>
> ```console
> curl -fsSL https://raw.githubusercontent.com/patclarke/claude-docker-sandbox/main/bin/cc -o ~/bin/cc
> chmod +x ~/bin/cc
> # make sure ~/bin is on PATH
> cc --cc-doctor
> ```

## Usage

### Day-to-day

```bash
cd ~/workspace/my-project
caffeinate -dims cc --remote-control --chrome -c
```

`cc` treats anything that isn't a `--cc-*` flag as a pass-through argument
for `claude` inside the sandbox. Your existing Claude Code muscle memory works
unchanged.

### Common invocations

```bash
# Fresh session in this directory
cc

# Resume the most recent session in this directory
cc -c

# Forward arbitrary Claude Code flags
cc --remote-control --chrome -c

# Two parallel sandboxes in the same directory
cc --cc-name experiment-a -c
cc --cc-name experiment-b -c

# One-off: share a folder outside the default mount list
cc --cc-mount ~/Projects/weird-experiment:ro -c

# One-off: don't let the sandbox see ~/Downloads this session
cc --cc-no-mount ~/Downloads

# Escape hatch — run host claude directly, bypass sbx entirely
cc --cc-no-sandbox -c
# …or just run the real binary
claude -c
```

### Flags

`cc` reserves only flags with a `--cc-*` prefix. Everything else passes
through to `claude` untouched.

| Flag                      | Purpose                                                       |
|---------------------------|---------------------------------------------------------------|
| `--cc-name <label>`       | Named sandbox (for running parallel sessions in the same dir) |
| `--cc-mount <path>[:ro]`  | Add an extra mount for this invocation (repeatable)           |
| `--cc-no-mount <path>`    | Skip a config-file mount for this invocation (repeatable)    |
| `--cc-no-sandbox`         | Escape hatch — exec host `claude` directly                    |
| `--cc-rm [name]`          | Remove the sandbox for cwd (or the named one), with a prompt  |
| `--cc-ls`                 | List active sandboxes                                         |
| `--cc-dry-run`            | Print the resolved `sbx run` command for this cwd, don't exec |
| `--cc-doctor`             | Run preflight checks and show the resolved mount list         |
| `--cc-help`               | Usage                                                         |

## Mount policy

The mount plan is built on every invocation in this order:

1. **Primary mount: `$PWD`** — read-write, always. Remapped to
   `/home/agent/workspace` inside the sandbox (sbx does not preserve the
   absolute host path for the primary mount). This is the agent's starting
   directory.
2. **Additional mounts** — every other path in the mount list lands at its
   absolute host path inside the sandbox (e.g. `~/.aws` is visible at
   `/Users/you/.aws`).
3. **Config file** — `~/.config/cc/mounts.conf`, one mount per line.
4. **`--cc-mount` flags** — appended.
5. **`--cc-no-mount` flags** — removed.
6. **Ancestor stripping** — any mount whose path is a strict ancestor of `$PWD`
   is silently removed. This prevents nested-mount failures when cwd is inside
   `~/workspace`.

### Default `~/.config/cc/mounts.conf`

Written automatically the first time you run `cc`:

```
# Format:  <path>[:ro]
# No suffix = read-write. ":ro" = read-only.
# Non-existent paths are skipped silently at launch.

# Cross-project reference (read-only view of sibling repos).
# cc automatically strips any mount that's an ancestor of $PWD, so
# this is safe even when cwd is inside ~/workspace.
~/workspace:ro

# Ad-hoc file sharing from normal macOS locations
~/Desktop:ro
~/Downloads:ro

# Claude Code session sharing (RW — sessions from host visible in sandbox and vice versa)
~/.claude/projects

# Claude Code code/config (RO — prevents a runaway sandbox from tampering with host plugins/skills)
~/.claude/plugins:ro
~/.claude/skills:ro
~/.claude/CLAUDE.md:ro

# Credentials (RO — read by cc on the host, injected into the sandbox via sbx exec)
~/.aws:ro
~/.config/gh:ro
~/.ssh:ro
```

### What each mount is for

| Path                    | Mode | Why                                                            |
|-------------------------|------|----------------------------------------------------------------|
| `$PWD` (launch dir)     | RW   | The actual work happens here                                   |
| `~/workspace`           | RO   | Cross-project context; stripped if cwd is inside it           |
| `~/Desktop`             | RO   | Share a file with the agent without moving it                  |
| `~/Downloads`           | RO   | Same, for downloaded artifacts                                 |
| `~/.claude/projects`    | RW   | Session persistence; host ↔ sandbox visibility                 |
| `~/.claude/plugins`     | RO   | Host plugins available in sandbox; sandbox cannot modify them  |
| `~/.claude/skills`      | RO   | Host skills available in sandbox; sandbox cannot modify them   |
| `~/.claude/CLAUDE.md`   | RO   | Global Claude instructions; sandbox cannot modify them         |
| `~/.aws`                | RO   | Credentials available to code running in the sandbox           |
| `~/.config/gh`          | RO   | `gh` CLI auth                                                  |
| `~/.ssh`                | RO   | git over ssh                                                   |

### Customizing

Permanent changes: edit `~/.config/cc/mounts.conf`. One line per mount,
`#` for comments, `~` expansion supported, `:ro` suffix for read-only.
Non-existent paths are skipped silently.

```bash
# Add a permanent mount
echo '~/Notes:ro' >> ~/.config/cc/mounts.conf

# Remove a permanent mount — just delete or comment out the line
```

One-off changes: use `--cc-mount` or `--cc-no-mount` on a single invocation.

## Auth

`cc` auto-extracts your Claude Code credentials from the macOS Keychain on
every invocation and injects them into the sandbox before attaching. The token
lands at `/home/agent/.claude/.credentials.json` with `600` permissions.

This means:
- No manual `/login` step when starting a new sandbox
- Token is refreshed on every `cc` invocation, so Keychain rotations propagate
  automatically
- If the Keychain read fails (non-macOS, not logged into Claude Code, etc.),
  `cc` prints a warning and continues; you can run `/login` inside the sandbox
  once per sandbox to authenticate manually

## Plugins and skills

Plugins and skills from `~/.claude/plugins` and `~/.claude/skills` are mounted
**read-only** into the sandbox. This means:

- Your host plugins and skills work inside the sandbox exactly as on the host
- Installing a plugin from inside a sandbox session does **not** persist — the
  sandbox cannot write to those directories
- To install a new plugin, run `claude` on the host (plain, without `cc`) and
  install it there; it will be available in sandbox sessions automatically on
  the next `cc` invocation

This is intentional: a runaway or compromised sandbox cannot inject malicious
code into `~/.claude/plugins` that would then execute on the host the next time
host `claude` loads those plugins.

## Session persistence

`~/.claude/projects` is mounted **read-write**. Any session files written from
inside the sandbox land in your real `~/.claude/projects/…` directory on the
host.

Inside the sandbox, `cc` creates symlinks from `/home/agent/.claude/projects`
to the host path (preserved at its absolute location by sbx). This means:
- Conversations **survive** `sbx rm`, OS reboots, or swapping sandbox images
- A session started with host `claude` is resumable with `cc -c`, and vice versa

Note: the primary workspace is remapped to `/home/agent/workspace` inside the
sandbox (not the absolute host path), so session keys may differ between host
and sandbox sessions when both are run in the same directory. Use `-c` or
`--resume <session-id>` to be explicit about which session to resume.

## Security model

**What the sandbox can see:** only the paths explicitly mounted. Anything else
on your host filesystem is invisible.

**What the sandbox can modify:** only the `$PWD` you launched from and
`~/.claude/projects`. Everything else in the default mount list is read-only,
so a runaway agent cannot rewrite your credentials, overwrite sibling projects,
touch your Desktop files, or modify your plugins and skills.

**What isolates the sandbox from your host:** microVM (hypervisor-level)
isolation via Docker Sandboxes. Each sandbox has its own Linux kernel,
filesystem, Docker daemon, and network namespace. Outbound traffic routes
through an HTTP/HTTPS proxy on your host for credential injection and network
policy.

**sbx's claude image** runs in bypass-permissions mode by default — no extra
flags needed. The bounded blast radius comes from the mount list, not from
permission prompts.

## Preflight checks

`cc` runs the following on every invocation before planning or exec:

1. `sbx` is installed (`command -v sbx`)
2. Docker Desktop is running (`docker info`) — **auto-starts** with a 30 s
   timeout if not
3. `sbx` is authenticated (`sbx ls` probe)
4. `~/.claude` is writable
5. Optional mount paths exist (missing ones are WARN, not FAIL)
6. Host `claude` binary exists (only when `--cc-no-sandbox` is in effect)

Short-circuit: `--cc-no-sandbox` skips checks 1–5 entirely. The whole point of
the escape hatch is "sbx/docker are broken, I need to work anyway."

Run `cc --cc-doctor` anytime to see the full status without launching a
sandbox.

## Escape hatch

If sbx, Docker Desktop, or `cc` itself ever breaks, **`claude` is always still
on your PATH unmodified**. `cc` does not alias or shadow it. Two ways to bail:

```bash
# Run host claude through the cc wrapper (skips all sandbox logic)
cc --cc-no-sandbox -c

# Or just run the real binary directly
claude -c
```

## Roadmap

- [x] Design locked in
- [x] Repo bootstrapped with README + CLAUDE.md
- [x] `bin/cc` script — parse, plan, preflight, exec phases
- [x] Live sandbox testing: sbx arg syntax, mount model, and auth all resolved
  - sbx primary workspace remapped to `/home/agent/workspace` (not absolute path)
  - Nested mounts cause chown failures — fixed via ancestor stripping
  - Claude runs as `agent`; credentials injected from macOS Keychain via `sbx exec`
  - Session/plugin/skill sharing works via symlinks from `/home/agent/.claude/*`
- [x] `cc --cc-doctor` output formatting
- [ ] Manual validation matrix walked through end-to-end
- [ ] Install instructions + `brew` / `curl` one-liner

## License

[MIT](LICENSE) — Copyright (c) 2026 Pat Clarke
