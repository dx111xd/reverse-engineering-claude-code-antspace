# Reverse-Engineering a Go Init System from Inside a Firecracker MicroVM

## Starting point

The only given: a shell inside an unknown VM, running as root. No documentation, no source code, no architecture diagrams. Goal: understand the runtime environment and the software managing it.

## Step 1 — Identify the hypervisor

```
dmesg | grep -i FIRECK
```

ACPI tables (RSDP, XSDT, FACP, DSDT, APIC, MCFG) all carry OEM ID `FIRECK`, immediately identifying the hypervisor as **Firecracker**. This tells us we're in a lightweight microVM with a minimal device model — no GPU, no PCI passthrough, no nested virt (`/dev/kvm` absent, no `vmx`/`svm` CPU flags).

## Step 2 — Identify PID 1 and the environment manager

```
cat /proc/1/cmdline
# /process_api --firecracker-init --addr 0.0.0.0:2024 --max-ws-buffer-size 32768 --block-local-connections
```

PID 1 is not systemd or init — it's **`/process_api`**, a custom Firecracker init process that listens on port 2024 with WebSocket support. The binary is embedded in the initramfs (the exe symlink resolves to `/process_api` but the file is not visible on the root filesystem after pivot). This is the process supervisor layer — it spawns and monitors everything else.

The more interesting target is the process it manages:

```
file /opt/env-runner/environment-manager
```

This is the **environment-manager**, a separate Go binary responsible for session orchestration, Claude Code lifecycle, deployment, and MCP servers. `file` reports it as a **not-stripped, dynamically linked ELF x86-64 with debug_info**. The presence of debug symbols is a significant advantage for static analysis.

## Step 3 — Extract Go build metadata

```
go version -m /opt/env-runner/environment-manager
```

Go embeds module information directly into binaries. This revealed:

- **Go version**: go1.25.7
- **Module path**: `command-line-arguments` (built outside a module, or with a custom build)
- **Key dependency**: `github.com/anthropics/anthropic/api-go` at `(devel)` — meaning this was built from a local/development copy of the monorepo, not a tagged release
- **Notable deps**: DataDog client, OpenTelemetry SDK, Connect RPC, gorilla/websocket, protobuf/gRPC ecosystem

The `(devel)` marker on the Anthropic dependency is the single most informative line — it confirms this binary is built from the monorepo and links the package structure to `api-go/environment-manager/internal/...`.

## Step 4 — Recover package structure from symbols

```
objdump -t binary | awk '{print $NF}' | grep -oP 'environment-manager/internal/\K[^.]+' | sort -u
```

Because the binary is not stripped, the symbol table contains fully qualified Go function names. Extracting the unique package paths and rendering them as a tree produces the internal architecture:

```
internal/
├── api/            # External API client
├── auth/           # Credential management
├── claude/         # Claude Code process management
├── config/         # Configuration parsing
├── envtype/        # Environment type implementations
│   ├── anthropic/  # Anthropic-hosted environments
│   └── byoc/       # Bring-your-own-compute
├── gitproxy/       # Git protocol proxy
├── input/          # Input parsing (V0/V1 formats)
├── logger/         # Structured logging
├── manager/        # Lifecycle management
├── mcp/            # Model Context Protocol
│   └── servers/
│       ├── codesign/  # Code signing MCP server
│       └── supabase/  # Database MCP server
├── o11y/           # Observability (OTEL, DataDog)
├── orchestrator/   # Session orchestration
├── podmonitor/     # Container/pod monitoring
├── process/        # Process supervision
├── sandbox/        # Sandbox setup
├── session/        # Session state
├── sources/        # Source code fetching
├── tunnel/         # WebSocket tunnel
│   └── actions/
│       ├── deploy/    # Deployment actions
│       ├── snapshot/  # State snapshots
│       └── status/    # Status reporting
└── util/           # Shared utilities
```

## Step 5 — Targeted string extraction

Naive `strings | grep` on Go binaries is noisy because the Go linker concatenates all string literals into a single blob. Two approaches work better:

**Approach A — Known-pattern search**: Search for specific byte sequences known to exist in protocol implementations:

```python
for s in [b'dist.tar.gz', b'application/x-ndjson', b'deploy request failed']:
    if data.find(s) >= 0: print(s.decode())
```

**Approach B — Struct tag extraction**: Go embeds struct field tags as string literals. Searching for JSON tags reveals wire protocol formats:

```
strings binary | grep 'struct { Status string'
```

This produced the NDJSON response struct for the deploy protocol:

```go
struct {
    Status   string `json:"status"`
    URL      string `json:"url"`
    App      string `json:"app"`
    Files    int    `json:"files"`
    Deployer string `json:"deployer"`
    Error    string `json:"error"`
}
```

## Step 6 — Symbol-table-driven feature mapping

Filtering symbols by subsystem produces a complete method inventory for each component. Example for the deploy subsystem:

```
objdump -t binary | grep 'deploy\.' | awk '{print $NF}'
```

Yields both Vercel and Antspace deploy clients with full method signatures:
- `(*VercelClient).CreateDeployment`, `UploadFile`, `WaitForReady`
- `(*AntspaceClient).Deploy`, `readDeployResponse`
- `(*DeployAction).executeAntspace`

For the Supabase MCP server, the same technique reveals the complete tool surface:
- `handleProvisionDatabase`, `handleQuery`, `handleMigrate`
- `handleListMigrations`, `handleGenerateTypes`, `handleDeployFunction`

## Step 7 — Runtime observation with strace

```
strace -p 1 -e trace=epoll_pwait,read,write -f
```

Attaching to PID 1 (`/process_api`) confirmed it runs as a lightweight supervisor: an epoll-based event loop with multiple goroutine threads, periodically reading `/proc/*/status` to monitor child processes (including `environment-manager`), and communicating over file descriptors for its WebSocket control plane on port 2024.

## Key techniques summarized

| Technique | What it reveals |
|---|---|
| `dmesg` ACPI OEM ID | Hypervisor identity |
| `go version -m` | Toolchain, dependencies, monorepo structure |
| Symbol table (`objdump -t`) | Package layout, type names, method signatures |
| Struct tag strings | Wire protocol / JSON formats |
| Targeted byte search | Error messages, status strings, flow logic |
| `strace` on PID 1 | Runtime behavior, IPC patterns |

## What made this possible

1. **The binary was not stripped.** This is the single biggest factor. A stripped binary would have required decompilation (Ghidra/IDA) rather than simple symbol table reads.
2. **Go's build metadata embedding.** The `go version -m` output provides a dependency manifest for free.
3. **Go's string concatenation model.** While it makes naive `strings` noisy, struct tags and error format strings remain extractable with targeted searches.
4. **Root access inside the VM.** Being able to `strace` PID 1 and read `/proc` freely allowed runtime correlation with static findings.
