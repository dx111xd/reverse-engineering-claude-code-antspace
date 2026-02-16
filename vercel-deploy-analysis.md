# Vercel Deployment Target — Deep Analysis

**Source**: Binary analysis of `environment-runner` v`staging-68f0dff496`
**Source files**: `internal/tunnel/actions/deploy/vercel.go`, `action.go`
**Triggered via**: Tunnel WebSocket control plane actions

---

## Overview

Vercel deployment is one of two deploy targets in the environment-runner, alongside Antspace. It is triggered through the **tunnel action system** — a WebSocket-based control plane that receives commands from the Anthropic API and executes them locally.

The deploy target is selected based on auth context:
```
unknown deploy target: %s (expected "vercel" or "antspace")
```

If neither is configured:
```
neither vercel_deploy token nor antspace_deploy credentials found in auth context
```

---

## Architecture

### Deploy Action (shared between targets)

```
deploy.DeployAction
  ├── Execute()          — main entry, routes to Vercel or Antspace
  ├── Name()             — returns action name
  ├── Timeout()          — returns action timeout
  └── executeAntspace()  — antspace-specific flow
```

### Shared Utilities

| Function | Purpose |
|----------|---------|
| `CollectFiles` | Walk project directory and collect files for deployment |
| `CreateTarball` | Create tar.gz archive of project (for Antspace) |
| `ValidateProjectDir` | Ensure `project_dir` is under allowed root |
| `ProjectName` | Derive project name from directory |
| `getCommitSHA` | Get current git commit SHA for deployment metadata |

### VercelClient

```
deploy.VercelClient
  ├── CreateDeployment()  — POST /v13/deployments
  ├── UploadFile()        — PUT /v2/files (content-addressable)
  └── WaitForReady()      — Poll deployment until readyState=READY
```

---

## Authentication

Vercel deploy tokens come from the session's **auth context**, configured via the `vercel_deploy` auth type in the startup JSON:

```
vercel_deploy auth configuration missing required 'token' field
```

### Auth Context Fields

| Field | Purpose |
|-------|---------|
| `vercelDeployToken` | Bearer token for Vercel API |
| `vercelTeamID` | Vercel team scope |
| `vercelToken` | Alternative/secondary token reference |

Retrieved via: `AuthContext.GetVercelDeployToken()`

---

## Vercel API Integration

### Base URL
```
https://api.vercel.com
```

### Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/v13/deployments` | Create a new deployment |
| GET | `/v13/deployments/{id}` | Check deployment status (`%s/v13/deployments/%s`) |
| PUT | `/v2/files` | Upload individual files (content-addressable) |

### Deploy Request (`deployRequest`)

JSON fields sent to `/v13/deployments`:

| Field | JSON Key | Description |
|-------|----------|-------------|
| Name | `"name"` | Project name (derived from directory) |
| Files | `"files"` | Array of file entries with SHA and size |
| ProjectSettings | `"projectSettings"` | Vercel project settings |
| Target | `"target,omitempty"` | Deploy target (e.g., production) |
| BuildCommand | `"buildCommand"` | Custom build command (within `projectSettings`) |
| OutputDirectory | `"outputDirectory"` | Custom output dir (within `projectSettings`) |
| Framework | `"framework"` | Framework detection hint |

### File Entry (`FileEntry`)

| Field | JSON Key |
|-------|----------|
| SHA | `"sha"` |
| Size | `"size"` |
| File | `"file"` |

### Deploy Response (`deployResponse`)

| Field | JSON Key | Description |
|-------|----------|-------------|
| ID | `"deploy_id"` | Deployment ID |
| URL | `"url"` | Deployment URL (`*.vercel.app`) |
| ReadyState | `"readyState"` | Current state: READY, BUILDING, ERROR, etc. |
| Status | `"status"` | HTTP-like status |
| Missing | `"missing"` | Array of file SHAs that need uploading |

### Error Response (`vercelErrorResponse`)

Parsed when Vercel API returns non-2xx status codes.

### File Upload

Files are uploaded via `PUT /v2/files` with content-addressable storage:
- Header: `x-vercel-digest` — SHA hash of file content
- Content type: raw file bytes
- Vercel deduplicates files by SHA — only missing files need uploading

---

## Deployment Flow

```
1. CollectFiles(project_dir)
   ├── Walk directory tree
   ├── Compute SHA for each file
   └── Return []FileEntry

2. CreateDeployment(files, settings)
   ├── POST /v13/deployments with file manifest
   ├── Parse response → get deployment ID + missing files
   └── If "vercel returned no deployment and no missing files" → error

3. Upload Missing Files
   ├── For each SHA in response.Missing:
   │   └── UploadFile(sha, content) → PUT /v2/files
   ├── "Uploading %d new files..."
   └── If still missing after upload: "deployment still has %d missing files after upload"

4. WaitForReady(deployment_id)
   ├── Poll GET /v13/deployments/{id}
   ├── Check readyState == "READY"
   ├── "Waiting for deployment to be ready..."
   └── Timeout: "context cancelled while waiting for deployment"

5. Return deploy URL (*.vercel.app)
```

---

## Metrics & Telemetry

| Metric | When |
|--------|------|
| `deploy_start` | Deployment initiated |
| `deploy_available` | Deploy target available in auth context |
| `deploy_uploading` | File upload phase |
| `deploy_completed` | Deployment finished successfully |
| `deploy_build_completed` | Vercel build step done |
| `deploy_create_failed` | CreateDeployment API call failed |
| `deploy_upload_failed` | File upload failed |
| `deploy_token_missing` | No vercel_deploy token in auth |
| `deploy_wait_failed` | WaitForReady timed out or failed |
| `deploy_progress_send_error` | Failed to report progress via tunnel |

Additional fields tracked:
- `files_cached` — files Vercel already had (SHA match)
- `files_uploaded` — new files uploaded
- `project_name` — derived project name
- `deploy_url` — final deployment URL

---

## Deploy Request Trigger

Deployments are triggered via the **tunnel control plane** — a WebSocket channel between the environment-runner and the Anthropic API:

```
internal/tunnel/actions/deploy/action.go  — DeployAction registered as tunnel action
internal/tunnel/handler.go               — Routes incoming tunnel messages to actions
internal/tunnel/ws_handler.go            — WebSocket message handling
```

The deploy action is registered in the **action registry** (`internal/tunnel/actions/registry.go`) and invoked when the API sends a deploy control message through the tunnel.

### Deploy Request JSON (from tunnel)

| Field | JSON Key |
|-------|----------|
| DeployTarget | `"deploy_target"` |
| ProjectDir | `"project_dir"` |
| DeployURL | `"deploy_url"` |

The `deploy_target` must be either `"vercel"` or `"antspace"`.

---

## Comparison: Vercel vs Antspace

| Aspect | Vercel | Antspace |
|--------|--------|----------|
| **API** | `api.vercel.com` (REST) | Internal control plane URL (streaming) |
| **Auth** | `vercel_deploy` token | `antspace_deploy` credentials + auth token |
| **Upload** | Content-addressable files (`/v2/files`) | Tar.gz archive streamed to server |
| **File handling** | Individual SHA-based dedup | Bulk tarball (`dist.tar.gz`) |
| **Build** | Vercel builds remotely | Server-side build |
| **Output** | `*.vercel.app` URL | Antspace URL |
| **Status check** | Poll `readyState` | Read streaming response (NDJSON) |
| **Progress** | "Deploying %d files to Vercel..." | "Deploying %d files to antspace..." |
| **Limit** | — | "build output exceeds %dMB limit" |
| **Auth retrieval** | `GetVercelDeployToken()` | `GetAntspaceAuthToken()` + `GetAntspaceControlPlaneURL()` |
| **Config field** | `default_deploy_target` | `control_plane_enabled`, `control_plane_deploy_unavailable` |

---

## Constraints & Error Handling

- `project_dir must be under %s, got: %s` — project directory validation prevents path traversal
- `vercel deploy token not configured — deploy is not available` — graceful degradation when no token
- `deploy request failed (status %d): %s` — HTTP error handling with status code
- `file upload failed (sha=%s): %w` — per-file upload error tracking
- `context cancelled while waiting for deployment: %w` — timeout handling
- `deployment still has %d missing files after upload` — retry/verification after upload phase
