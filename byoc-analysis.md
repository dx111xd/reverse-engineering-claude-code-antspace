# BYOC (Bring Your Own Cloud) — Deep Analysis

**Source**: Binary analysis of `environment-runner` v`staging-68f0dff496` (Go 1.25.7)
**Internal description**: "BYOC (Bring Your Own Cloud) environment with customer-managed infrastructure"
**Feature gate string**: `ccr-byoc-2025-07-29`

---

## Architecture

BYOC is one of two `EnvironmentType` implementations (the other being `anthropic` for Anthropic-hosted environments). Both implement the same interface:

### EnvironmentType Interface Methods (implemented by `byocEnvironmentType`)

| Method | Purpose |
|--------|---------|
| `Initialize` | Bootstrap the BYOC environment |
| `GetCWD` | Return working directory |
| `GetClaudeEnvironmentVariables` | Inject env vars into Claude Code process |
| `SetAuthContext` | Configure authentication (GitHub tokens, etc.) |
| `SetSessionMode` | Set session lifecycle mode |
| `SetStartupContext` | Accept startup context from API |
| `CreateLeaseManager` | K8s pod lease management |
| `bootstrapClaudeSettings` | Write Claude Code settings.json |
| `extractRepoBranchMapping` | Map repos to branches from outcomes |
| `handleBranchCheckout` | Git branch checkout logic |
| `runScript` | Execute setup/init scripts |
| `setupGitConfig` | Configure git credentials & remotes |

### containProvideAuthRoundTripper

A custom `http.RoundTripper` that injects authentication into outbound HTTP requests. This wraps the standard HTTP client to add container-level auth tokens when communicating with the Anthropic API from customer-managed infrastructure.

---

## Session Modes

BYOC defaults to `resume-cached` mode (as stated: "BYOC environment detected, defaulting to resume-cached mode").

| Mode | Description |
|------|-------------|
| `new` | Default for Cloud — full git clone + setup |
| `resume` | Skip git clone and setup scripts |
| `resume-cached` | Default for BYOC/self-hosted — fastest restart |
| `setup-only` | Exit after setup (uses `NoopBackend`) |

### Resume Logic

```
BYOC resume: checking if task branch exists on remote
BYOC resume: task branch exists on remote, fetching it
BYOC resume: task branch not found on remote, falling back to original ref
```

If `resume-cached` and repo already exists, it uses `Allow-prefetched mode with existing repo - using existing repository state`.

---

## Configuration

### Startup Context (JSON via stdin)

```json
{
  "sources": ["..."],
  "api_base_url": "...",
  "outcomes": ["..."],
  "custom_system_prompt": "...",
  "append_system_prompt": "...",
  "model": "...",
  "mcp_config": {},
  "allowed_tools": ["..."],
  "disallowed_tools": ["..."],
  "enabled_tools": ["..."],
  "claude_code_args": {},
  "mcp_config_file": {},
  "use_sandbox_gateway_config": false,
  "entrypoint": "...",
  "environment_variables": {},
  "environment_sub_type": "...",
  "use_code_sessions": false
}
```

### Environment Sub-Types

- `antspace` — Anthropic's internal hosting platform ("Deploying %d files to antspace...")
- `baku` — Anthropic's project builder environment (Vite-based, `/home/claude/project`, drafts at `/home/claude/project/.baku/drafts`)

### Key Environment Variables

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT_SERVICE_KEY` | Service key for API auth |
| `ANTHROPIC_BASE_URL` | API base URL override |
| `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` | FD for API key |
| `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` | FD for OAuth token |
| `CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR` | FD for WS auth |
| `CLAUDE_CODE_REMOTE` | Indicates remote environment |
| `CLAUDE_CODE_REMOTE_SESSION_ID` | Session ID |
| `CLAUDE_CODE_SESSION_ID` | Session ID |
| `CLAUDE_CODE_ENVIRONMENT_RUNNER_VERSION` | Runner version |
| `CLAUDE_CODE_ENVIRONMENT_KIND` | Environment type |
| `CLAUDE_CODE_BASE_REF` | Git base reference |
| `CLAUDE_CODE_DEBUG` | Debug mode |
| `CLAUDE_CODE_ENTRYPOINT` | Custom entrypoint |
| `CLAUDE_CODE_USE_CCR_V*` | CCR version flag |
| `CLAUDE_CODE_EXIT_AFTER_STOP_DELAY` | Delay before exit on stop |
| `CLAUDE_CODE_STUCK_THRESHOLD_SECONDS` | Stuck detection |
| `CLAUDE_CODE_WORKER_EPOCH` | Worker epoch |
| `CLAUDE_SESSION_INGRESS_TOKEN_FILE` | Session ingress token path |
| `CCR_PLUGINS_JSON` | Plugin marketplace config |
| `CCR_USE_V2_ENDPOINT` | Use v2 API endpoint |
| `CODESIGN_MCP_PORT` | Code signing MCP server port |
| `CODESIGN_MCP_TOKEN` | Code signing MCP server token |
| `ENVRUNNER_SKIP_ACK` | Skip work acknowledgement |

---

## API Endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /v1/environments/whoami` | Discover environment identity (org ID, env ID) |
| `POST /v1/environments/{id}/work/poll` | Poll for work items |
| `POST /v1/environments/{id}/work/{id}/ack` | Acknowledge work |
| `GET /v1/code/sessions/{id}` | Get session context |
| `POST /v1/code/sessions/{id}/sign` | Code signing |
| `WS /v1/code/sessions/{id}/worker/` | Worker WebSocket |
| `POST /v1/projects/{id}/database/query` | Supabase DB query proxy |

### Session Ingress

Uses gRPC/ConnectRPC for session ingress (CCR = Claude Code Router):
- `session_ingress_backend.go` — gRPC backend
- `session_ingress_client.go` — Client implementation
- WebSocket tunnel at `{scheme}://{host}/{path}/session_ingress/ws/{id}`
- Token written to `/home/claude/.claude/remote/.session_ingress_token`

---

## Embedded Resources

### 1. Default Settings JSON (shared — used by both BYOC and anthropic)

**CCR variant** (`shared.gobytes.1`):
```json
{
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "hooks": {
        "Stop": [
            {
                "matcher": "",
                "hooks": [
                    {
                        "type": "command",
                        "command": "~/.claude/stop-hook-git-check.sh"
                    }
                ]
            }
        ]
    },
    "permissions": {
        "allow": ["Skill"]
    }
}
```

**Baku variant** (`shared.gobytes.3`):
```json
{
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "hooks": {
        "Stop": [
            {
                "matcher": "",
                "hooks": [
                    {
                        "type": "command",
                        "command": "~/.claude/stop-hook-baku.sh"
                    }
                ]
            }
        ]
    },
    "permissions": {
        "allow": ["Skill"]
    }
}
```

### 2. Stop Hook — Git Check (`shared.gobytes.2`)

Ensures all changes are committed and pushed before session stops:
- Checks for uncommitted changes (staged + unstaged)
- Checks for untracked files
- Checks for unpushed commits (compares against `origin/{branch}` or `origin/HEAD`)
- Exits with code 2 to block stop if issues found
- Recursion guard via `stop_hook_active` JSON field

### 3. Stop Hook — Baku (`shared.gobytes.4`)

More comprehensive stop hook for the Baku environment:
- **Vite dev server error checking**: Scans `/tmp/vite-dev.log` for errors (TypeScript, build, CSS, React, Node.js runtime errors)
- **Git uncommitted changes**: Checks `/home/claude/project` for dirty state
- **TypeScript type checking**: Runs `npx tsc --noEmit` if `tsconfig.json` exists
- Does NOT check for unpushed commits (no remote in Baku)
- Advisory only — Claude can proceed on second attempt

### 4. Startup Hook Skill (`anthropic.gobytes.1`)

A full skill definition for creating SessionStart hooks. Documents:
- Hook input JSON format
- Async mode support
- Environment variables (`CLAUDE_PROJECT_DIR`, `CLAUDE_ENV_FILE`, `CLAUDE_CODE_REMOTE`)
- Complete workflow for analyzing deps, creating hook, testing

---

## Git Proxy

Built-in git credential proxy (`internal/gitproxy/`):
- HTTP server that proxies git operations with injected auth
- Supports GitHub App tokens (`github_source_provider.go`)
- Validates proxy after setup with retry logic
- Updates remote URLs for authenticated access in resume mode

---

## Observability

- **DataDog**: `datadog-go` v5 for metrics (`core/dogmetrics/`)
- **OpenTelemetry**: Full OTLP/HTTP export for traces, metrics, and logs
- **Metrics tracked**: `env_init_started`, `env_init_completed`, `claude_init_success`, `mcp_server_count`, `total_elapsed_ms`, etc.
- **Lease management**: K8s-style lease for pod health monitoring

---

## Lifecycle Flow (BYOC)

1. **Orchestrator** receives work via poll (`/v1/environments/{id}/work/poll`)
2. Acknowledges work (`/v1/environments/{id}/work/{id}/ack`)
3. Invokes `task-run` (with or without sandbox)
4. `task-run` parses stdin JSON (v1 format with packed secret)
5. Creates BYOC environment type → detects `resume-cached` mode
6. Sets up git config + credential proxy
7. Handles branch checkout (fetch or create from current HEAD)
8. Bootstraps Claude settings (stop hooks, permissions)
9. Installs/upgrades Claude Code if needed
10. Runs Claude Code with session parameters
11. Connects tunnel WebSocket for real-time communication
12. On stop: stop hook validates git state, blocks if dirty
13. Reports outcomes and session activity
