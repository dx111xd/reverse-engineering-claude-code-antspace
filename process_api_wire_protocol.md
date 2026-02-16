# process_api Wire Protocol

The `process_api` binary (PID 1) exposes two network interfaces:
1. **WebSocket API** (port 2024) — process lifecycle management
2. **HTTP Control API** (port 2025, also vsock) — container management

---

## 1. WebSocket Process API (port 2024)

### Connection Handshake

The WebSocket connection follows a multi-step handshake:

1. **Client connects** via WebSocket to `ws://<addr>:2024`
2. **First text message**: Either a JWT token string, or a `ProcessConnection` JSON
3. **JWT verification** (if JWT sent first):
   - If no auth public key is loaded, JWT is accepted without verification
   - JWT `TokenClaims` struct (3 fields): `sub`, `iat`, `exp`
   - `ClaimsForValidation` (5 fields) — used for JWT validation
   - After JWT accepted, client sends a second text message with `ProcessConnection` JSON
4. **ProcessConnection JSON** (3 fields):
   ```json
   {
     "process_id": "<string>",
     "create_req": { ... },           // CreateProcess struct (optional, for new processes)
     "expected_container_name": "..."  // optional container name validation
   }
   ```

### ProcessConnection Variants

The protocol supports two versions:
- **V1**: Original protocol
- **V2**: Updated protocol

If `create_req` is present, a new process is spawned. If absent, it attempts to **reattach** to an existing detached process.

### CreateProcess Struct (10 fields)

```json
{
  "cmd": "/bin/bash",
  "args": ["-l"],
  "env": {"KEY": "VALUE"},
  "cwd": "/home/user",
  "rows": 24,
  "cols": 80,
  "timeout": 300,
  "memory_limit_bytes": 1073741824,
  "clear_env": false,
  "uid": 1000,
  "gid": 1000,
  "allow_process_id_reuse": false
}
```

Fields:
| Field | Type | Description |
|-------|------|-------------|
| `cmd` | string | Command to execute |
| `args` | string[] | Command arguments |
| `env` | map | Environment variables |
| `cwd` | string | Working directory |
| `rows` | u32 | Terminal rows (PTY) |
| `cols` | u32 | Terminal columns (PTY) |
| `timeout` | u64? | Process timeout in seconds |
| `memory_limit_bytes` | u64? | Per-process memory limit |
| `clear_env` | bool | Clear inherited environment |
| `uid` | u32? | Run as user ID |
| `gid` | u32? | Run as group ID |
| `allow_process_id_reuse` | bool | Allow reusing a process_id |

### Server→Client Messages (Text JSON)

After connection, the server sends tagged JSON messages. The message type is encoded as a variant tag:

| Message | Description |
|---------|-------------|
| `ProcessCreated` | Process successfully spawned |
| `AttachedToProcess` | Reattached to existing detached process |
| `ProcessNotRunning` | Requested process is not running |
| `ProcessAlreadyAttached` | Process is already attached to another WS |
| `FailedToStart` | Process failed to start |
| `ProcessWithSameIdRunning` | A process with the same ID is already running |
| `InfraError` | Internal infrastructure error |
| `ExpectStdOut` | Server is about to send stdout data |
| `StdOutEOF` | stdout stream ended |
| `ExpectStdErr` | Server is about to send stderr data |
| `StdErrEOF` | stderr stream ended |
| `ProcessExited` | Process terminated (includes exit status) |
| `ProcessTimedOut` | Process exceeded timeout |
| `ProcessOutOfMemory` | Process killed by per-process OOM |
| `ContainerOutOfMemory` | Process killed by container-level OOM |
| `InvalidSignal` | Signal number was invalid |
| `FailedToSendSignal` | Failed to deliver signal |
| `SignalSent` | Signal successfully delivered |
| `ShuttingDown` | Server is shutting down |

### Client→Server Messages

| Message Type | Format | Description |
|--------------|--------|-------------|
| `SendSignal` | Text JSON: `{"SendSignal": <signal_number>}` | Send a signal to the process |
| `ExpectStdIn` | Text JSON: `{"ExpectStdIn": null}` | Indicate next binary frame is stdin data |
| stdin data | Binary frame (after `ExpectStdIn`) | Raw bytes for process stdin |
| `Resize` | Text JSON: `{"Resize": {"rows": N, "cols": N}}` | Resize PTY |
| `Detach` | Text JSON: `{"Detach": null}` | Detach from process (keeps it running) |
| `KeepAlive` | Text JSON: `{"KeepAlive": null}` | Keep connection alive |
| `Closed` | Text JSON: `{"Closed": null}` | Close the connection |

### Stdin Protocol

Stdin uses a two-message sequence:
1. Client sends text `ExpectStdIn`
2. Client sends binary frame with raw stdin bytes

If the server receives no message after `ExpectStdIn`, or receives a text message instead of binary, it's treated as an error.

### Stdout/Stderr Protocol

1. Server sends `ExpectStdOut` or `ExpectStdErr` (text)
2. Server sends binary frame with raw output bytes
3. When stream ends: `StdOutEOF` or `StdErrEOF`

### Process Lifecycle

```
Client                              Server
  |                                    |
  |--- WS Connect ------------------->|
  |--- JWT (optional) --------------->|  JWT verification
  |<-- (accepted) --------------------|
  |--- ProcessConnection JSON ------->|  Spawn or reattach
  |<-- ProcessCreated/AttachedTo... --|
  |                                    |
  |<-- ExpectStdOut ------------------|  stdout available
  |<-- [binary: stdout data] ---------|
  |<-- ExpectStdErr ------------------|  stderr available
  |<-- [binary: stderr data] ---------|
  |                                    |
  |--- ExpectStdIn ------------------>|  stdin write
  |--- [binary: stdin data] --------->|
  |                                    |
  |--- SendSignal ------------------->|  send SIGTERM etc
  |<-- SignalSent --------------------|
  |                                    |
  |--- Resize ----------------------->|  resize PTY
  |                                    |
  |--- KeepAlive -------------------->|  heartbeat
  |                                    |
  |--- Detach ----------------------->|  detach (process continues)
  |                                    |
  |<-- ProcessExited -----------------|  process done
  |<-- StdOutEOF --------------------|
  |<-- StdErrEOF --------------------|
```

### Status Response Fields

The server tracks and may include these in responses:
- `memory_usage_bytes`: Current process memory usage
- `memory_cgroup_path`: Cgroup path for memory tracking
- `process_group_pid`: PID of the process group
- `internal_state`: Internal state enum (Cgroup variant)

---

## 2. HTTP Control API (port 2025 / vsock)

The control server listens on a configurable TCP address (default `0.0.0.0:2025`) and/or a vsock port. It provides container lifecycle management.

Security: Connections from non-host CIDs are rejected on vsock.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/status` | Health check, returns `"OK"` |
| POST | `/fs_sync` | Flush filesystem buffers (`sync`), returns `"synced"` |
| POST | `/shutdown` | Graceful shutdown, drops page caches, returns `"Shutdown initiated"` |
| POST | `/auth_public_key` | Set the JWT verification public key, returns `"Auth public key set"` |
| POST | `/mount_root` | Mount root filesystem (snapstart), freeze/thaw root. Body is `MountRootConfig` JSON |
| POST | `/container_name` | Set/update container name (persisted to `/container_info.json`) |
| * | * | Returns `"Not Found"` (404) |

### MountRootConfig Struct

Used for the `/mount_root` endpoint (snapstart flow):

```json
{
  "etc_hosts": "...",
  "resolv_conf": "...",
  "ca_cert_pem": "...",
  "mount_model_tools": true,
  "mount_rclone_tools": true,
  "rclone_tools_dev_index": 0,
  "fuse_mounts": [...],
  "readonly_mounts": [...],
  "readonly_dev_start_index": 0,
  "realtime_unix_nanos": 1234567890000000000
}
```

### FuseMountConfig Struct (10 fields)

Each entry in `fuse_mounts`:

```json
{
  "destination": "/mnt/data",
  "filesystem_id": "fs-abc123",
  "memory_store_id": "mem-xyz",
  "auth_token": "...",
  "service_url": "https://...",
  "source": "/dev/fuse",
  "vfs_cache_mode": "full",
  "backend_cache_ttl": "1h",
  "dir_perms": "0755",
  "file_perms": "0644",
  "writes": true,
  "vfs_cache_max_size": "1G"
}
```

### Shutdown Flow

1. `POST /shutdown` received
2. `[CONTROL] Received shutdown request via HTTP`
3. `[CONTROL] Dropping page caches...` (writes "3" to `/proc/sys/vm/drop_caches`)
4. Sends shutdown signal to all processes
5. `[CONTROL] Shutdown signal sent successfully`
6. Returns `"Shutdown initiated"`

### Mount Root Flow (Snapstart)

1. `POST /mount_root` with `MountRootConfig` JSON body
2. `[CONTROL] Received mount_root request`
3. `[CONTROL] Freezing / ...` (FIFREEZE ioctl)
4. Mounts squashfs, rclone, FUSE filesystems
5. Sets up `/etc/hosts`, `/etc/resolv.conf`, CA certs
6. Sets realtime clock via `clock_settime`
7. `[CONTROL] / frozen` → `[CONTROL] mount_root succeeded`

---

## 3. CLI Arguments

```
process_api [OPTIONS] --addr <ADDR> --max-ws-buffer-size <SIZE> --oom-polling-period-ms <MS> --block-local-connections

Options:
  --addr <ADDR>                    WebSocket listen address (e.g., "0.0.0.0:2024")
  --max-ws-buffer-size <SIZE>      Max WebSocket buffer size [default: 32768]
  --memory-limit-bytes <BYTES>     Container memory limit
  --cpu-shares <SHARES>            CPU shares for cgroup
  --oom-polling-period-ms <MS>     OOM check interval [default: 100]
  --cgroupv2                       Enable cgroup v2 mode
  --control-server-addr <ADDR>     Control HTTP server address (e.g., "0.0.0.0:2025")
  --block-local-connections        Block connections from localhost/own IPs
  --listen-uds <PATH>              Listen on Unix domain socket instead of TCP
  --control-vsock-port <PORT>      Control server vsock port
  --listen-vsock-port <PORT>       WebSocket vsock port (Firecracker)
  --firecracker-init               Run as Firecracker VM init (PID 1)
```

---

## 4. Process Management Internals

### ProcHandle Struct

Internal state per process:
- `proc_handle`: OS process handle
- `controller`: process controller channel
- `stop_waiting_rx` / `stop_waiting_tx`: stop signal channels
- `exit_status_rx` / `exit_status_tx`: exit status channels
- `oom_killed_rx`: OOM kill notification receiver

### Cgroup Integration

- **v1**: `/sys/fs/cgroup/memory/process_api/` — uses `memory.usage_in_bytes`, `cpu.cfs_quota_us`
- **v2**: `/sys/fs/cgroup/process_api/` — uses `memory.current`, `cpu.weight`
- Per-process memory monitoring via `oom_polling_period_ms`
- Container-level OOM killer monitors total memory, kills largest process

### Orphan Adoption

The `adopter` module tracks orphaned processes (reparented to PID 1) and either:
- Reaps zombie processes
- Adopts them into the process tracking map
- Detaches non-reattachable processes

### Process Termination Reasons

Processes can exit with these status types:
- Normal exit (exit code)
- Signal termination (signal number)
- Signal stop (stopped, not terminated)
- OOM killed (per-process or container-level)
- Timeout exceeded
- Server shutdown
