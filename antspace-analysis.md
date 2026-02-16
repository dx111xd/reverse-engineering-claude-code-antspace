# Antspace — Deep Analysis

**Source**: Binary analysis of `environment-runner` v`staging-68f0dff496`
**Source file**: `internal/tunnel/actions/deploy/antspace.go`
**Public documentation**: **None.** No public references exist anywhere — not on Anthropic's website, GitHub, blog, or any third-party source. This is a purely internal Anthropic platform.

---

## What is Antspace?

Antspace is **Anthropic's internal application hosting/deployment platform**. The name is likely a play on "Ants" — the internal nickname for Anthropic employees (referenced on their careers page: "Ants" = Anthropic team members) — making it "Ant Space" = workspace for Ants.

It serves as the deployment target for web applications built within Claude Code sessions, particularly for the **Baku** environment sub-type (Anthropic's Vite-based project builder). When a user's project needs to be deployed/published, the environment-runner packages it and ships it to Antspace.

### Key characteristics:
- Internal Anthropic infrastructure — no public API
- Receives **tar.gz archives** of project build output via streaming upload
- Returns deployment URLs and streaming build progress
- Serves deployed apps on its own domain
- Alternative to Vercel as a deploy target
- Described in code as: `"antspace"` deploy target

---

## Architecture

### AntspaceClient

```
deploy.AntspaceClient
  ├── Deploy(ctx, controlPlaneURL, tarball, progressReporter) → AntspaceDeployResult
  └── readDeployResponse(response) → parsed streaming result
```

### AntspaceDeployResult

Contains the final deployment outcome (fields extracted from type descriptors).

### Auth Context

| Field | Source Method | Purpose |
|-------|-------------|---------|
| `antspaceAuthToken` | `AuthContext.GetAntspaceAuthToken()` | Bearer token for API auth |
| `antspaceControlPlaneURL` | `AuthContext.GetAntspaceControlPlaneURL()` | Base URL of the Antspace control plane |

Auth is provided via the `antspace_deploy` auth type in the session startup JSON:
```
antspace_deploy auth configuration missing required 'token' field
```

---

## Deployment Protocol

### Overview

Antspace uses a **3-phase HTTP protocol** with streaming NDJSON responses:

```
Phase 1: Deploy Request  → Create deployment, get deployment ID
Phase 2: Upload Request  → Upload tar.gz via multipart/form-data
Phase 3: Status Request  → Poll/stream deployment status until ready
```

### Phase 1: Create Deployment

- **Method**: POST
- **Auth**: `Authorization: Bearer {antspaceAuthToken}`
- **Content-Type**: `application/json`
- **Request fields**: `app` (project name), plus metadata
- **Error**: `"failed to create deploy request"`, `"deployment request failed"`

### Phase 2: Upload Build Artifact

- **Method**: POST (multipart)
- **Content-Type**: `multipart/form-data`
- **Payload**: `dist.tar.gz` — gzipped tarball of build output
- **Form field**: tarball attached via `form-data; name="..."`
- **Flow**:
  1. `CreateTarball(projectDir)` — walks directory, creates tar.gz archive
  2. Writes tarball to multipart form body
  3. Streams the upload to the control plane
- **Errors**: `"failed to create upload request"`, `"failed to write tarball to form"`, `"failed to create form file"`, `"failed to close multipart writer"`

### Phase 3: Status Polling / Streaming

- **Content-Type**: `application/x-ndjson` (Newline-Delimited JSON)
- **Streaming response** with status updates
- **Error**: `"failed to create status request"`, `"failed to read status response"`, `"failed to parse status response"`

### Streaming Response Format

Each line is a JSON object with these fields:

```json
{
  "status": "building|deploying|uploading|packaging|deployed",
  "url": "https://...",
  "app": "project-name",
  "files": 42,
  "deployer": "...",
  "error": ""
}
```

#### Status Values (deployment lifecycle)

| Status | Meaning |
|--------|---------|
| `packaging` | Creating deployment package |
| `uploading` | Uploading files to hosting |
| `building` | Build step in progress |
| `deploying` | Deploying to edge/servers |
| `deployed` | Successfully deployed |

### Deploy Response Parsing (`readDeployResponse`)

The `readDeployResponse` method:
1. Reads the streaming NDJSON body line by line
2. Parses each JSON line into the response struct
3. Reports progress via `ProgressReporter` (sent back through tunnel)
4. On `"deployed"` status → extracts final URL
5. On error → returns `"antspace deploy error: %s"`

---

## Full Deployment Flow

```
1. executeAntspace() called via tunnel control plane action
   ├── Validate: "antspace deploy not configured — no credentials available"
   ├── Get antspaceAuthToken and antspaceControlPlaneURL from AuthContext
   └── Proceed to build + deploy

2. Build Phase (runs locally in the environment)
   ├── "Running npm run build..."
   ├── Executes `npm run build` in the project directory
   └── On failure: "build failed: %w"

3. Collect Build Output
   ├── "Collecting build output..."
   ├── CollectFiles(outputDir) — walk the build output directory
   ├── Validate: "no files found in %s" if empty
   ├── Validate: "project exceeds %dMB limit" if too large
   └── Count files for progress reporting

4. Create Tarball
   ├── "Creating deployment package..."
   ├── CreateTarball(outputDir) → dist.tar.gz in memory
   ├── Walk all files, write tar entries
   └── Gzip compress the tar archive

5. Deploy to Antspace
   ├── "Deploying %d files to antspace..."
   ├── AntspaceClient.Deploy(ctx, controlPlaneURL, tarball, progress)
   │   ├── Create deploy request (POST, JSON with app name)
   │   ├── Upload tarball (POST, multipart/form-data)
   │   └── Read streaming NDJSON response
   │       ├── Status updates: packaging → uploading → building → deploying → deployed
   │       ├── Progress reported back through tunnel WebSocket
   │       └── Final response contains deployment URL
   ├── On success: "Deployed to {URL}"
   ├── On failure: "antspace deployment failed: %w"
   └── Validate: "antspace deploy succeeded but returned no URL"

6. Report Result
   ├── deploy_antspace_success metric
   ├── Return DeployURL to tunnel caller
   └── Tunnel sends result back to Anthropic API
```

---

## Metrics & Telemetry

| Metric | When |
|--------|------|
| `deploy_antspace_start` | Deploy initiated |
| `deploy_antspace_success` | Deploy completed successfully |
| `deploy_build_completed` | Local build step finished |
| `deploy_build_failed` | Local build step failed |
| `deploy_collect_files_empty` | No files found in build output |
| `deploy_collect_files_failed` | Failed to collect build output |
| `deploy_create_failed` | Failed to create deployment on Antspace |
| `deploy_upload_failed` | Failed to upload tarball |
| `deploy_progress_send_error` | Failed to send progress via tunnel |
| `deploy_retry_failed` | Retry attempt failed |
| `antspace_progress_send_error` | Failed to send streaming progress |
| `deploy_started` | Deployment process started |
| `deploy_success` | Deployment succeeded |
| `deploy_completed` | Full deploy cycle completed |

### Additional tracked fields:
- `files_cached` — files count
- `total_bytes` / `total_body_bytes` — upload size
- `project_name` — derived from project directory
- `deploy_url` — final deployed URL

---

## Comparison with Vercel

| Aspect | Antspace | Vercel |
|--------|----------|--------|
| **Ownership** | Anthropic internal | Third-party (Vercel Inc.) |
| **Public docs** | None | Yes (api.vercel.com) |
| **Build step** | Local (`npm run build`) then upload output | Remote (Vercel builds from source) |
| **Upload format** | Single tar.gz via multipart | Individual files via SHA-based dedup |
| **API style** | Streaming NDJSON responses | REST with polling |
| **Upload endpoint** | Control plane URL (dynamic) | `api.vercel.com/v2/files` (fixed) |
| **Deploy endpoint** | Control plane URL (dynamic) | `api.vercel.com/v13/deployments` (fixed) |
| **Status tracking** | Streaming (real-time updates) | Polling (`readyState` field) |
| **Auth** | `antspaceAuthToken` + `antspaceControlPlaneURL` | `vercelDeployToken` + `vercelTeamID` |
| **Size limit** | `"project exceeds %dMB limit"` | No explicit limit found |
| **File dedup** | None (full tarball each time) | SHA-based (only upload missing files) |
| **Domain** | Unknown (internal) | `*.vercel.app` |
| **Fallback** | `"control_plane_deploy_unavailable"` | `"vercel deploy token not configured"` |

---

## Integration with Baku

Antspace is the **default deploy target** for Baku environments (Anthropic's Vite-based project builder):

- `default_deploy_target` config field controls which target is used
- `control_plane_enabled` flag indicates Antspace availability
- `control_plane_deploy_unavailable` metric when Antspace is down
- Baku projects live at `/home/claude/project` with drafts at `/home/claude/project/.baku/drafts`
- The build command is `npm run build` (standard Vite build)
- Build output is collected from the Vite output directory

The `isBaku` / `isBakuEnvironment` flag in the config distinguishes Baku environments, which use the Baku-specific stop hook (with Vite error checking and TypeScript type validation) instead of the standard git-check stop hook.

---

## Error Handling

| Error | Cause |
|-------|-------|
| `antspace deploy not configured — no credentials available` | No `antspace_deploy` auth in session |
| `antspace_deploy auth configuration missing required 'token' field` | Token missing from auth config |
| `failed to parse antspace deploy credentials` | Malformed auth JSON |
| `antspace deployment failed` | General deployment failure |
| `deployment failed (status %d): %s` | HTTP error from Antspace API |
| `antspace deploy error: %s` | Error in streaming response |
| `antspace deploy succeeded but returned no URL` | Deploy reported success but no URL in response |
| `build failed: %w` | `npm run build` failed |
| `no files found in %s` | Build produced no output |
| `project exceeds %dMB limit` | Build output too large |
| `failed to create tarball from %s` | Tar creation failed |
| `deployment not ready after %v` | Timeout waiting for deployment |
| `context cancelled during poll` | Context cancelled while waiting |
| `Streaming unsupported` | Server doesn't support streaming responses |
| `deploy request failed (status %d): %s` | HTTP error on deploy creation |
| `file upload failed (status %d): %s` | HTTP error on tarball upload |
