# Security

## Directory sharing

A read-write VirtioFS share grants the Guest the ability to modify every file
the invoking host user can modify below that source directory. Treat an
untrusted Guest as an untrusted local program with access to that directory.

Do not share credentials, source-control signing keys, socket directories, or
other secrets. vmctl blocks its own state and runtime, but it cannot classify
all sensitive user data.

VirtioFS starts only with a working non-privileged user-namespace sandbox.
vmctl deliberately does not fall back to `--sandbox none`.

## Network exposure

Forwarded ports bind to `127.0.0.1` by default. Using `--bind 0.0.0.0` or
another externally reachable address exposes the Guest service according to
the host firewall rules.

## Guest trust

Official Ubuntu images are accepted only after the checksum-list signature and
image SHA-256 both verify. The project SSH private key is stored under
`.vmctl/ssh` with mode 0600; anyone who copies the project state copies that
credential.

## Reporting

Do not include VM disks, private keys, cloud-init user data, or host paths in a
public report. Provide the vmctl version, runtime manifest, host Ubuntu version,
and sanitized logs.
