# Architecture

## Trust and dependency boundary

The release archive owns all user-space dependencies. The host supplies only
the x86_64 Linux kernel, `/bin/sh`, hardware resources, optional `/dev/kvm`,
and optional unprivileged user namespaces.

The bootstrap re-executes under the bundled BusyBox shell and prepends bundled
applets to `PATH`. Dynamically linked programs are invoked through the bundled
glibc loader with a private library search path.

## Persistent state

Configuration uses tab-separated, non-executable records. Values containing
tabs or newlines are rejected, and configuration is never evaluated or sourced
as shell code.

Cloud images are content-addressed. An instance overlay records a relative
backing-file path, so the project can be relocated while every VM is stopped.
Instance creation happens in a same-depth temporary directory and is renamed
only after its disk, cloud-init seed, and configuration are complete.

## Process model

Each running instance consists of one QEMU process and zero or more
`virtiofsd` processes. A VirtioFS daemon and Unix socket are created per share
before QEMU starts. QEMU receives shared RAM through `memory-backend-memfd` and
connects each `vhost-user-fs-pci` device to its daemon.

The QEMU PID, QMP socket, daemon PIDs, and logs live inside the instance
directory. Missing share daemons produce a `degraded` state without killing
the VM.

## Resource adjustment

`resize` locks the instance and changes one resource per invocation. Stopped
instances use config edits and `qemu-img resize`; running instances use QMP
`device_add`, `balloon`, and `block_resize`. Disk shrinking and live CPU removal
are rejected. CPU additions persist one at a time so a partial failure retains
the count of acknowledged additions. Config updates use atomic renames.

New starts normally expose 255 single-core CPU sockets with a matching `maxcpus` limit
(to avoid requiring extended APIC support merely to boot a small VM). Explicit
256-vCPU boot configurations retain 256 slots and their existing APIC requirements
and a virtio balloon. The selected CPU driver and boot memory ceiling are
recorded in `resources.tsv`; missing records require a restart before CPU or
memory adjustment. RAM (including the shared memfd backend for VirtioFS) is
sized at the ceiling, then ballooned to the saved target after SSH readiness.
The ceiling defaults to initial RAM and can only be changed while stopped.
Balloon acceptance is not confirmation of Guest convergence. Disk growth does
not change Guest partitions or filesystems.

QMP requests negotiate capabilities and correlate acknowledgements by ID,
ignoring unrelated events. Transport and reply waits are bounded; errors and
missing replies fail without persisting the requested target. A lost reply can
still leave an applied change in QEMU, so the operator must inspect live state
after an ambiguous failure. The control protocol follows the
[QEMU QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html)
and [CPU topology options](https://www.qemu.org/docs/master/system/qemu-manpage.html).

## Guest initialization

The NoCloud seed creates a locked-password `ubuntu` user and injects the
project-specific Ed25519 public key. Initial shares are written by cloud-init.
After every CLI-driven start, `vmctl` synchronizes its marked `/etc/fstab`
section over SSH so shares added or removed after creation remain persistent.

## Security choices

- Network forwarding binds to `127.0.0.1` unless explicitly overridden.
- Shares are read-only unless explicitly changed to read-write.
- Rootless VirtioFS requires the namespace sandbox; there is no automatic
  unsandboxed or 9p fallback.
- Guest UID/GID requests are squashed to the invoking host UID/GID.
- State, runtime, credentials, disks, caches, project root, and critical Guest
  mount targets are rejected as share paths.
- VM deletion requires confirmation unless `--yes` is supplied.
