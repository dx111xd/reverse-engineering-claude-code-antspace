# Baku — Deep Analysis

**Source**: Binary analysis of `environment-runner` v`staging-68f0dff496`
**Source files**: `internal/envtype/anthropic/*.go`, `internal/envtype/shared/*.go`, `internal/mcp/servers/supabase/*.go`
**Public documentation**: **None under the name "Baku".** Zero public references exist. However, the functionality it powers is publicly visible as **Claude Code on the web's project builder / app creation feature** — the one that lets you "build and deploy web apps" from claude.ai.

---

## What is Baku?

Baku is **Anthropic's internal codename for the web app project builder environment** used in Claude Code on the web. When a user asks Claude to "build me a web app" or "create a React project" on claude.ai, the session spins up a **Baku environment** — a specialized MicroVM preconfigured with:

- A **Vite + React** project template
- A running **Vite dev server** (managed by supervisord)
- **Supabase** database integration (auto-provisioned)
- **Antspace** deployment (Anthropic's internal hosting platform)
- Skills (SKILL.md files) for guiding Claude's behavior

The name "Baku" is purely internal. Users see it as "Projects" or the app builder in Claude's web interface.

### Key differentiator from standard BYOC/CCR

| Aspect | Standard CCR (Claude Code Remote) | Baku |
|--------|----------------------------------|------|
| Project source | User's GitHub repo | Template from `/opt/baku-templates/vite-template` |
| Git remote | User's GitHub remote | No remote (local git only) |
| Dev server | None (user manages) | Auto-started Vite via supervisord |
| Database | None | Auto-provisioned Supabase |
| Deploy target | Vercel (if configured) | Antspace (Anthropic's internal hosting) |
| Stop hook | Checks git push + uncommitted changes | Checks Vite errors + TS types + uncommitted changes |
| Skills | From repo `.claude/skills/` | Pre-installed from `/mnt/skills` zips |
| Working directory | Cloned repo | `/home/claude/project` (template-seeded) |

---

## Architecture

### Environment Detection

```
anthropic.Config {
    isBakuEnvironment bool    // Set during startup context parsing
    ...
}
```

The `isBakuEnvironment` flag is set during `SetStartupContext` based on the `environment_type` field in the V1 work data. When set to `"baku"`, the environment switches to Baku mode.

### Key Functions

| Function | Purpose |
|----------|---------|
| `isBakuEnvironment` | Checks if current session is Baku |
| `initializeBakuProject` | Creates project from template |
| `findExistingBakuProject` | Finds existing project on session resume |
| `bootstrapBakuSettings` | Writes Baku-specific Claude settings |
| `bootstrapClaudeSkills` | Installs SKILL.md files |
| `startDevServer` | Launches Vite dev server via supervisord |
| `writeSupabaseEnvFiles` | Writes `.env.local` with Supabase credentials |
| `installLanguages` | Installs configured languages (node, etc.) |

---

## Startup Flow

```
1. Parse V1 startup context
   ├── Detect environment_type = "baku"
   ├── Set isBakuEnvironment = true
   └── Log: "Baku environment detected"

2. Set working directory
   ├── Working dir: /home/claude/project
   └── Log: "Setting working directory"

3. Install languages
   ├── Language struct: { Name, Version }
   ├── Generate install script: install-{name}-{version}-*.sh
   ├── Execute installation
   ├── Log: "Installing language" → "Successfully installed language"
   └── On failure: "Unsupported language, skipping installation"
   └── On failure: "failed to install %s %s: %s (exit code: %d)"

4. Initialize Baku project (first run)
   ├── Log: "Initializing Baku project"
   ├── Copy template from /opt/baku-templates/vite-template
   ├── Create .baku/drafts/ directory
   ├── Create .baku/explorations/ directory
   ├── Initialize git repo (local only, no remote)
   ├── Set git config: user.email = claude@anthropic.com
   ├── Log: "Baku project initialized"
   └── On failure: "failed to copy Baku template", "failed to initialize git repo"

   OR (session resume):
   ├── findExistingBakuProject at /home/claude/project
   ├── Log: "Baku project found on resume"
   └── Or: "No existing Baku project found on resume"

5. Write Supabase env files
   ├── Write .env.local with:
   │   ├── SUPABASE_URL=https://{project_ref}.supabase.co
   │   ├── SUPABASE_ANON_KEY={anon_key}
   │   ├── VITE_SUPABASE_URL=https://{project_ref}.supabase.co
   │   └── VITE_SUPABASE_ANON_KEY={anon_key}
   ├── Log: "supabase_env_files_written"
   └── On failure: "failed to write Supabase env files"

6. Bootstrap Claude settings
   ├── Write BakuSettingsJSON to settings file
   ├── Log: "Successfully created settings file"
   └── On failure: "Failed to bootstrap Baku settings" (non-fatal)

7. Bootstrap Claude skills
   ├── Extract skill zips from /mnt/skills
   ├── Install SKILL.md files under /home/claude/.claude/skills/
   ├── Create session-start-hook skill
   ├── Log: "Successfully created session start hook skill"
   └── On failure: "bootstrap_claude_skills_failed_nonfatal"

8. Start dev server
   ├── Check: isSupervisordRunning?
   ├── If not: start supervisord with /etc/supervisord.conf
   ├── Vite dev server logs to /tmp/vite-dev.log
   ├── Log: "supervisord started for dev server"
   ├── Or: "supervisord already running, skipping start"
   └── On failure: "Failed to start dev server (non-fatal)"

9. Run task setup script (if configured)
   └── Log: "Running task setup script"
```

---

## Project Structure

```
/home/claude/project/                    # Main project directory
├── .baku/
│   ├── drafts/                          # Draft versions of the app
│   └── explorations/                    # Exploration branches/experiments
├── .env.local                           # Supabase credentials (auto-generated)
├── package.json                         # Node.js project config
├── tsconfig.json                        # TypeScript config (triggers TS type checking in stop hook)
├── [vite project files...]              # From /opt/baku-templates/vite-template
└── supabase/                            # Supabase Edge Functions (if created)
    └── functions/
        ├── {slug}/
        │   └── index.ts
        └── _shared/                     # Shared code between functions
```

---

## Baku Settings JSON

The following Claude Code settings are automatically written for Baku environments:

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

---

## Stop Hook (Quality Gate)

The Baku stop hook (`stop-hook-baku.sh`) runs before Claude stops and performs three checks:

### Check 1: Vite Dev Server Errors
Scans `/tmp/vite-dev.log` (last 100 lines) for error patterns:

| Category | Patterns |
|----------|----------|
| **Vite/Dev Server** | `Internal server error`, `Pre-transform error`, `server restart failed`, `Cannot optimize dependency` |
| **Build Tools** | `Transform failed`, `Build failed`, `Rollup failed to resolve`, `PLUGIN_ERROR`, `UNRESOLVED_IMPORT` |
| **TypeScript** | `error TS[0-9]+:`, `Cannot find module`, `Cannot find name`, `is not assignable to`, `does not exist on type`, `has no exported member`, `Module not found`, `Could not resolve` |
| **React/JSX** | `Unterminated JSX`, `Adjacent JSX elements`, `Invalid hook call` |
| **CSS** | `CssSyntaxError`, `Unknown at rule @` |
| **Node.js** | `SyntaxError:`, `TypeError:`, `ReferenceError:`, `EADDRINUSE` |

### Check 2: Uncommitted Git Changes
- Checks for uncommitted changes (`git diff --quiet`)
- Checks for untracked files (`git ls-files --others`)
- **No push check** (unlike CCR — Baku has no remote)
- Message: "commit before stopping so your work is preserved across sessions"

### Check 3: TypeScript Type Errors
- Runs `npx tsc --noEmit` if `tsconfig.json` exists
- Vite uses esbuild which strips types without checking them
- This catches type errors that Vite silently ignores

### Recursion Guard
- On first failure: exits with code 2 (advisory)
- On second attempt (`stop_hook_active=true`): allows stop
- Claude can always stop on the second attempt after reviewing issues

---

## Dev Server (supervisord)

Baku uses **supervisord** to manage the Vite development server:

- Config: `/etc/supervisord.conf`
- Logs: `/tmp/vite-dev.log`
- Check: `isSupervisordRunning()` prevents double-starting
- The dev server runs on `localhost:{port}` (dynamic port)
- Start is **non-fatal** — if it fails, the session continues

---

## Supabase Integration

Baku environments come with deep Supabase integration via a built-in **MCP server** (`internal/mcp/servers/supabase`).

### Auth Context

| Method | Purpose |
|--------|---------|
| `HasSupabase()` | Check if Supabase is configured |
| `GetSupabaseProjectRef()` | Get the Supabase project reference ID |
| `GetSupabaseAnonKey()` | Get the anonymous API key |
| `GetSupabaseDBPass()` | Get the database password |
| `GetSupabasePAT()` | Get the Personal Access Token |

### Supabase MCP Server

The `SupabaseMCPServer` provides 6 tools to Claude:

#### 1. `provision_database`
Provisions a new Supabase database for the project. Triggers the provisioning flow via `triggerProvision()` and writes credentials to `.env.local`.

#### 2. `execute_query` (or `run_query`)
Execute a SQL query against the Supabase database.
> *"Use for inspecting schema, checking data, seeding test data, or debugging. For schema changes, prefer the migrate tool instead."*

API: `POST https://api.supabase.com/v1/projects/{project_ref}/database/query`

#### 3. `apply_migration`
Apply a SQL migration to the Supabase database.
> *"Creates a versioned migration file and automatically regenerates TypeScript types. Use this for all schema changes: CREATE TABLE, ALTER TABLE, RLS policies, functions, triggers."*

API: `POST https://api.supabase.com/v1/projects/{project_ref}/database/migrations`

#### 4. `list_migrations`
> *"List all migrations that have been applied to the database."*

#### 5. `generate_types`
> *"Regenerate TypeScript types from the current database schema. Usually called automatically after migrate, but can be called manually if needed."*

#### 6. `deploy_function`
Deploy a Supabase Edge Function.
> *"The function source must already be written to `supabase/functions/{slug}/index.ts`. Shared code goes in `supabase/functions/_shared/`. After deployment, invoke from React with `supabase.functions.invoke('{slug}', { body: {...} })`."*

API: `POST https://api.supabase.com/v1/projects/{project_ref}/functions/deploy?slug={slug}`

### Supabase MCP Server Lifecycle

```
1. shouldRegister() — check if Supabase auth is available
2. configureServer() — register all 6 tools
3. Start() — begin MCP server
   ├── "Supabase MCP server started (credentials pending)"
   ├── fetchCredentials() — get creds from control plane
   ├── ensureConfigured() — verify project is provisioned
   │   └── triggerProvision() if needed
   └── "Supabase MCP server configured"
4. writeEnvFiles() — write .env.local
5. Stop() — shutdown
```

### Lazy Provisioning

The flag `_BAKU_SUPABASE_LAZY` controls lazy Supabase provisioning — credentials are fetched on first use rather than at startup.

---

## Skills System

Baku environments have a skill system based on **SKILL.md** files:

### Skill Sources
1. **Pre-packaged skills**: Extracted from zip files at `/mnt/skills` or `/workspace/skills`
2. **Session start hook skill**: Auto-created, named `session-start-hook`

### Skill Bootstrap Flow
```
bootstrapClaudeSkills()
├── bootstrapClaudeSkillsUnderDir(/home/claude)
│   ├── Create skill directory: /home/claude/.claude/skills/
│   ├── Write SKILL.md files
│   ├── Extract skill zips (extractSkillZips)
│   └── Create session-start-hook skill
└── On failure: "bootstrap_claude_skills_failed_nonfatal"
```

Skills are scoped with `--global` flag and can reference `--scope` for configuration.

---

## Deploy Flow (via Antspace)

When a Baku app is deployed, the flow is:

```
1. npm run build (local Vite build)
2. Collect build output from dist/
3. Create dist.tar.gz tarball
4. Upload to Antspace via control plane
5. Stream deployment status: packaging → uploading → building → deploying → deployed
6. Return deployment URL
```

Key attributes tracked:
- `default_deploy_target` — set to `"antspace"` for Baku
- `control_plane_enabled` — whether Antspace is available
- `drafts_count` — number of draft versions
- `commit_count` — number of git commits
- `app_modified` — whether the app has been modified

---

## Metrics & Telemetry

| Metric | When |
|--------|------|
| `bootstrap_baku_settings_failed_nonfatal` | Settings bootstrap failed |
| `bootstrap_claude_skills_failed_nonfatal` | Skills bootstrap failed |
| `supabase_env_files_written` | Supabase env files created |
| `skill_extraction_failed` | Failed to extract skill zips |
| `default_deploy_target` | Attribute: deploy target name |
| `control_plane_enabled` | Attribute: whether control plane is available |
| `drafts_count` | Count of project drafts |
| `commit_count` | Count of git commits |
| `app_modified` | Whether project was modified |

---

## Drafts & Explorations

Baku has a concept of **drafts** and **explorations**:

- **Drafts** (`/home/claude/project/.baku/drafts/`): Saved versions of the app at various stages
- **Explorations** (`/home/claude/project/.baku/explorations/`): Experimental branches/variations

These are tracked via:
- `Drafts` field (json:"drafts") in the session context
- `Explorations` field (json:"explorations") in the session context
- `drafts_count` metric attribute
- `explorationsPath` for path resolution

---

## Template

The Vite template lives at `/opt/baku-templates/vite-template` in the VM image. It's a standard Vite + React + TypeScript project that includes:

- `package.json` / `package-lock.json`
- `tsconfig.json`
- Standard Vite project structure

The template is copied (not cloned) to `/home/claude/project` during initialization. Git is then initialized locally with `claude@anthropic.com` as the committer email.

---

## Error Catalog

| Error | Cause |
|-------|-------|
| `failed to copy Baku template` | Template copy failed |
| `failed to initialize git repo` | Git init in project dir failed |
| `failed to initialize Baku project` | General initialization failure |
| `No existing Baku project found on resume` | Project dir missing on resume |
| `Failed to start dev server (non-fatal)` | supervisord/Vite failed to start |
| `Failed to bootstrap Baku settings` | Settings file write failed |
| `failed to write Supabase env files` | .env.local write failed |
| `Unsupported language, skipping installation` | Unknown language requested |
| `failed to install %s %s` | Language install script failed |
| `bootstrap_claude_skills_failed_nonfatal` | Skill installation failed |
| `skill_extraction_failed` | Zip extraction failed |
| `build failed` | `npm run build` failed |
| `no files found in %s` | Build produced no output |
| `project exceeds %dMB limit` | Build output too large |
| `antspace deploy not configured` | No deploy credentials |

---

## Relationship to Public Features

While "Baku" is never mentioned publicly, the features it powers are visible:

1. **Claude.ai Projects**: The web UI for creating and building web apps
2. **App deployment**: When Claude says "I've deployed your app to [URL]" — that's Antspace
3. **Database integration**: When Claude offers to "set up a database" — that's Supabase auto-provisioning
4. **Live preview**: The Vite dev server provides real-time preview in the browser
5. **Drafts/versions**: The ability to save and restore different versions of your app

The public-facing feature is described in [Claude Code on the web](https://www.anthropic.com/news/claude-code-on-the-web) documentation, but the internal "Baku" codename and architecture details are not publicly documented anywhere.
