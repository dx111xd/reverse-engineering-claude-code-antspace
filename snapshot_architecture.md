# Firecracker Snapshot Architecture

## Overview

Claude Code web sessions run inside Firecracker microVMs that are restored from pre-built
snapshots. The `process_api` binary (PID 1, Rust/tokio) serves as both the VM init system
and the process supervisor. Snapshots use Firecracker's native snapshot/restore API, with
block device backends hot-swapped at restore time to inject session-specific content.

## Evidence from This VM

### dmesg Timeline

```
[   0.000000] Command line: ... rdinit=/process_api init_on_free=1 -- --firecracker-init ...
[  30.459416] Unpacking initramfs...              ← 3108K initramfs (just /process_api)
[  30.477900] Freeing initrd memory: 3108K
[  30.731516] Run /process_api as init process
[  30.732975]   with arguments: /process_api --firecracker-init --addr 0.0.0.0:2024 ...

    ~~~ 48.5 HOUR GAP — VM WAS FROZEN AS A SNAPSHOT ~~~

[174695.927758] virtio_blk: [vdc] new size: 24848 sectors (12.1 MiB)    ← block devices swapped
[174695.928185] virtio_blk: [vda] new size: 536870912 sectors (256 GiB)
[174695.931631] virtio_blk: [vdb] new size: 130392 sectors (63.7 MiB)
[174695.953952] random: crng reseeded due to virtual machine fork        ← VM fork detected
[174695.980760] tokio-runtime-w (507): drop_caches: 3                    ← process_api drops caches
[174695.993628] EXT4-fs (vda): mounted filesystem r/w without journal    ← new rootfs mounted
[174696.004046] EXT4-fs (vda): mounted 00000000-0000-0000-0000-000000000000
```

### Block Device Transformation

| Device | Template (t=30s) | After Restore (t=174695s) | Content |
|--------|-----------------|--------------------------|---------|
| vda | 256 GiB (placeholder) | 256 GiB (new ext4 image) | Session rootfs (Ubuntu 24.04) |
| vdb | 256 GiB (placeholder) | 63.7 MB (squashfs) | `/opt/claude-code` |
| vdc | 256 GiB (placeholder) | 12.1 MB (squashfs) | `/opt/env-runner` |

The ext4 on vda has mount count=11 and `Last mounted on: /mnt`, showing the image has been
reused across 11 sessions, always mounted at `/mnt` before `pivot_root`.

### Timeline Reconstruction

```
2026-03-16 13:52:38 UTC — Template VM first booted (kernel t=0)
2026-03-16 13:53:08 UTC — process_api started as init (kernel t=30.7s)
                          Minimal init: /proc, /sys, /dev, cgroups, networking
                          Signaled SNAPSTART_READY
                          Firecracker host took full VM snapshot

    ~~~ Snapshot stored as template for ~48.5 hours ~~~

2026-03-18 14:24:14 UTC — This session's VM restored from snapshot
                          Block device backends swapped by host
                          process_api woke up, mounted everything
                          environment-manager started
```

## Two Snapshot Modes

### Mode 1: Snapstart (Deferred Mount) — Used by This VM

The initramfs contains **only** `/process_api` (3.1 MB, no `mount_config.json`).

**Template Creation Phase:**
1. Firecracker boots: kernel + 3.1MB initramfs
2. `rdinit=/process_api -- --firecracker-init --addr 0.0.0.0:2024 --max-ws-buffer-size 32768 --block-local-connections`
3. `process_api` does **minimal init only**:
   - Mount essential filesystems: `/proc`, `/sys`, `/dev` (devtmpfs), `/dev/shm`, `/dev/pts`
   - Mount cgroups: cpu, cpuacct, memory, devices, freezer, blkio, pids, cgroup2
   - Configure networking: IP=192.0.2.2/24, GW=192.0.2.1, MTU=1400
   - Start WebSocket listener on 0.0.0.0:2024
4. `process_api` logs: `[INIT] Snapstart template mode: signaling ready...`
5. Signals readiness via `SNAPSTART_READY` (likely stdout or vsock to host)
6. Firecracker host calls `PUT /snapshot/create` → saves memory + VM state

**Session Restore Phase:**
1. Firecracker host prepares session-specific block devices:
   - vda: ext4 image (pre-populated Ubuntu 24.04 rootfs with user home, packages, etc.)
   - vdb: squashfs (claude-code tooling)
   - vdc: squashfs (environment-manager + runner)
2. Host calls `PUT /snapshot/load` with new block device backends
3. VM resumes — kernel detects device size changes, reseeds CRNG
4. `process_api` detects restore (`resumed from frozen full-checkpoint snapshot`):
   a. **Drop page caches**: writes "3" to `/proc/sys/vm/drop_caches` (flush stale template data)
   b. **Remount devtmpfs**: restore device nodes for new block devices
   c. **Mount ext4**: `/dev/vda` → `/mnt` (ext4, rw, no journal)
   d. **pivot_root**: `/mnt` becomes new `/`, old root unmounted
   e. **Mount squashfs**: `/dev/vdb` → `/opt/claude-code`, `/dev/vdc` → `/opt/env-runner`
   f. **Set wall clock**: `clock_settime(CLOCK_REALTIME, realtime_unix_nanos)` — fixes clock from template epoch
   g. **Load container.env**: session-specific environment variables from new rootfs
   h. **Drop CAP_SYS_RESOURCE**: security hardening
   i. **Accept connections**: WebSocket server ready for environment-manager

### Mode 2: Fresh Boot (Full Init from Config)

The initramfs contains `/process_api` **and** `/mount_config.json`.

1. `process_api` reads `/mount_config.json` from initramfs (before pivot_root)
2. Performs **all** mounts immediately during init
3. No snapshot involved — VM runs from cold boot
4. Can still be snapshotted externally by the host after full init

### Mode 3: Snapstart with Control Server

Uses `--control-vsock-port` to receive mount config post-restore.

1. Template boots minimally (same as Mode 1)
2. Signals ready, host snapshots
3. On restore, host calls `POST /mount_root` via vsock with `MountRootConfig` JSON
4. `process_api` receives config, mounts everything, pivot_roots
5. More flexible: mount config is dynamic per session, not baked into block devices

## Initramfs Structure

```
Size: 3108 KB (compressed cpio archive)
Memory: [0xbfcf7000 - 0xbfffffff]

Contents:
  /process_api    — 3.1 MB static Rust binary (PID 1 init + process supervisor)
  (possibly /mount_config.json in fresh boot mode)
```

The initramfs is intentionally minimal — just the init binary. The actual rootfs (Ubuntu 24.04
with all packages, user home, etc.) lives on the ext4 block device (vda), which is provided
by the Firecracker host at snapshot restore time.

## Mount Hierarchy After Restore

```
/                       ← /dev/vda ext4 (pivot_root from /mnt)
├── /proc               ← procfs (mounted during template init)
├── /sys                ← sysfs
│   └── /sys/fs/cgroup  ← tmpfs + cgroup mounts
├── /dev                ← devtmpfs (remounted after restore)
│   ├── /dev/shm        ← tmpfs
│   └── /dev/pts        ← devpts
├── /opt/claude-code    ← /dev/vdb squashfs (ro)
└── /opt/env-runner     ← /dev/vdc squashfs (ro)
```

## Block Device Convention

`process_api` uses a hardcoded device naming scheme:

| Device | Purpose | Filesystem | Mode |
|--------|---------|-----------|------|
| `/dev/vda` | Session rootfs | ext4 | rw |
| `/dev/vdb` | Primary squashfs (tools/code) | squashfs | ro |
| `/dev/vdc`+ | Additional squashfs mounts | squashfs | ro |

The field `readonly_dev_start_index` controls which devices are read-only.
Device names are generated as `/dev/vd[a-z]` (max 26 devices, validated).

## Post-Restore Initialization Detail

### Page Cache Drop
Immediately after VM resume, `process_api` writes "3" to `/proc/sys/vm/drop_caches`.
This is critical because the snapshot's page cache contains stale data from the template's
placeholder block devices. Without this, reads would return garbage from cache instead of
hitting the new block device backends.

### CRNG Reseed
The kernel automatically detects the VM fork and reseeds the CRNG:
`random: crng reseeded due to virtual machine fork`
This prevents cryptographic predictability across instances sharing the same snapshot.

### Clock Fixup
The `realtime_unix_nanos` field in mount config (or hardcoded) sets the wall clock via
`clock_settime(CLOCK_REALTIME, ...)`. Without this, the clock would show the template's
creation time (48.5 hours ago in our case) instead of the current time.

### Filesystem Freeze/Thaw
For the `/mount_root` control server path, `process_api` uses `FIFREEZE`/`FITHAW` ioctls
to freeze the root filesystem during mount operations:
```
[CONTROL] Freezing / ...
[CONTROL] / frozen
[CONTROL] mount_root succeeded
[CONTROL] Thawed /
```

## Security Measures

1. **init_on_free=1** kernel parameter: zeroes freed memory pages (prevents data leakage between sessions)
2. **CAP_SYS_RESOURCE dropped**: `process_api` drops this capability from the bounding set after init
3. **CRNG reseed**: automatic on VM fork
4. **--block-local-connections**: prevents localhost connections to the WebSocket server
5. **JWT auth**: WebSocket connections can require JWT verification via `/auth_public_key`
6. **Auth token scrubbing**: `[INIT] Auth tokens scrubbed from config(s)` — removes secrets from mount configs after use

## Comparison: Firecracker vs gVisor Deployment

| Aspect | Firecracker (this VM) | gVisor/runc |
|--------|----------------------|-------------|
| Init process | `process_api` as PID 1 via `rdinit=` | Regular process (not PID 1) |
| Rootfs setup | `process_api` mounts + pivot_root | Container runtime handles it |
| Transport | TCP (`:2024`) or vsock | TCP or Unix domain socket |
| Snapshotting | Firecracker snapshot API | Not applicable (or container checkpointing) |
| Networking | Manual setup (192.0.2.2/24) | Container runtime handles it |
| Block devices | virtio-blk (vda/vdb/vdc) | Overlay/bind mounts |
| `--firecracker-init` | Active | Ignored ("has no effect on gVisor/runc") |
