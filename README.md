# Claude Code Sandbox Reverse Engineering

Reverse engineering of Anthropic's Claude Code sandbox environment — Firecracker microVM internals, process supervisor, wire protocols, and deployment targets.

## Findings

- Full binary analysis of `/opt/env-runner/environment-manager`
- Extracted all BYOC details including embedded scripts, config structs, API endpoints
- Extracted embedded settings JSON and stop hook scripts from binary
- Deep analysis of Vercel deployment target — API endpoints, flow, auth, comparison with Antspace
- Deep analysis of Antspace — Anthropic's internal deploy platform, protocol, build flow
- Deep analysis of Baku — Anthropic's internal web app builder environment, full startup flow, Supabase MCP server, skills system, stop hook
- Recovered `process_api` binary from `/proc/1/exe` (PID 1 Firecracker init/supervisor, 3.1MB Rust/tokio)
- Full Ghidra decompilation of `process_api` — 3599 functions, 446K lines of C pseudocode
  - Source modules: firecracker_init, control_server, cgroup, oom_killer, proc_handle, state, adopter, pid_tree, io, platform/unix
  - Key features: WebSocket API on port 2024, process spawning/lifecycle, cgroup management, OOM killer, mount/pivot_root init, control HTTP server
- Reverse-engineered complete wire protocol for `process_api`
  - WebSocket protocol: JWT auth -> ProcessConnection JSON -> CreateProcess, stdin/stdout/stderr binary framing, SendSignal, Resize, Detach, KeepAlive
  - HTTP control API: /status, /fs_sync, /shutdown, /auth_public_key, /mount_root (snapstart), /container_name
  - Documented all struct fields, message types, and lifecycle flows
- Reverse-engineered Firecracker snapshot architecture from dmesg, process_api strings, and runtime forensics
  - Snapstart mode: minimal template VM (proc/sys/dev/net only), snapshotted, block devices hot-swapped at restore
  - dmesg proves 48.5h time gap between template boot (2026-03-16) and session restore (2026-03-18)
  - Post-restore: drop caches, remount devtmpfs, mount ext4+squashfs, pivot_root, clock_settime
  - Block devices: vda=ext4 rw rootfs, vdb=squashfs claude-code, vdc=squashfs env-runner

## Files

| File | Description |
|------|-------------|
| `byoc-analysis.md` | BYOC (Bring Your Own Cloud) deployment analysis |
| `vercel-deploy-analysis.md` | Vercel deployment target analysis |
| `antspace-analysis.md` | Antspace — Anthropic's internal deploy platform |
| `baku-analysis.md` | Baku — Anthropic's internal web app builder environment |
| `discovery-writeup.md` | RE methodology writeup for environment-manager binary |
| `process_api_wire_protocol.md` | Complete wire protocol spec for process_api |
| `snapshot_architecture.md` | Firecracker snapshot/restore architecture |
| `process_api_decompiled.c` | Full Ghidra decompilation (446K lines) |
| `process_api` | PID 1 Firecracker init/supervisor binary (Rust/tokio) |
| `environment-manager` | Environment manager binary from `/opt/env-runner/` |

## Notes

- Antspace has zero public documentation — fully internal Anthropic platform
- Baku has zero public documentation under that name — powers the claude.ai web app builder
- `process_api` built from repo path: `sandboxing/sandboxing/server/process_api/src/`
- Dependencies include: tokio, hyper, tungstenite, tokio-vsock, jsonwebtoken, ring, clap, nix, serde_json
- Template VM was built 2026-03-16 13:52 UTC
- ext4 rootfs mount count=11 — this image template has been used across 11 sessions
- Kernel: 6.18.5 built by argocd@coder-xiangbin-xb-home-2 on 2026-01-14
- Security: init_on_free=1, CAP_SYS_RESOURCE dropped, CRNG reseeded on fork, auth token scrubbing
