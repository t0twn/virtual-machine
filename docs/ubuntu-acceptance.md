# Ubuntu x86_64 acceptance

Run these checks on both Ubuntu 22.04 and Ubuntu 24.04 x86_64 hosts.

## Clean-host prerequisite check

The test host must not need QEMU, libvirt, virtiofsd, xorriso, curl, or SSH
installed specifically for vmctl. Extract the release and run:

```sh
./vmctl doctor
```

Record whether `/dev/kvm` and unprivileged user namespaces are available.

## Guest lifecycle

```sh
mkdir -p testdata-ro testdata-rw
printf 'from-host\n' > testdata-ro/input.txt

./vmctl create acceptance \
  --share testdata-ro:/mnt/readonly \
  --share testdata-rw:/mnt/readwrite:rw \
  --forward tcp:28080:8080

./vmctl ssh acceptance -- sh -c 'cat /mnt/readonly/input.txt'
./vmctl ssh acceptance -- sh -c 'printf "from-guest\n" > /mnt/readwrite/output.txt'
test "$(cat testdata-rw/output.txt)" = from-guest

if ./vmctl ssh acceptance -- sh -c 'touch /mnt/readonly/must-fail'; then
  echo 'read-only share unexpectedly accepted a write' >&2
  exit 1
fi

./vmctl stop acceptance
./vmctl start acceptance
./vmctl ssh acceptance -- test -f /mnt/readwrite/output.txt
./vmctl stop acceptance
./vmctl delete acceptance --yes
```

Confirm that files written through the read-write share are owned by the host
user running `vmctl`.

## Required negative cases

- Repeat with `/dev/kvm` inaccessible and verify the TCG warning.
- Create with `--strict-kvm` while KVM is inaccessible and verify startup is
  rejected.
- Disable or block unprivileged user namespaces and verify only directory
  sharing is rejected.
- Interrupt an image download and verify no partial object becomes a cache
  reference.
- Move the entire stopped project and confirm a relative share still mounts.
- Remove an absolute shared directory and verify startup reports its exact
  missing path.
- Kill one `virtiofsd` process and verify `vmctl status` reports `degraded`.

## Resource adjustment (real QEMU)

Run on both supported Ubuntu hosts with KVM, then repeat under TCG. Test once
without shares and once with a VirtioFS share. Record Guest-visible values,
not just CLI success. These checks require enough host memory for the ceiling.

```sh
./vmctl create resources --cpus 2 --memory 2048 --memory-max 4096 --disk 20
./vmctl ssh resources -- lscpu
./vmctl resize resources --cpus 4
./vmctl ssh resources -- lscpu
./vmctl resize resources --memory 3072
./vmctl ssh resources -- free -m
./vmctl resize resources --memory 2048
./vmctl ssh resources -- free -m
./vmctl resize resources --disk 30
./vmctl ssh resources -- lsblk -b
```

Allow balloon changes to settle. Confirm that total Guest memory moves toward
both targets and that CPUs become online. If CPU auto-onlining is disabled,
online the newly added CPUs through the Guest's CPU sysfs controls. Check disk
capacity increases to 30 GiB while the filesystem remains unchanged until grown.
For a standard ext4 cloud image with root on `/dev/vda1` (verify first):

```sh
./vmctl ssh resources -- findmnt /
./vmctl ssh resources -- sudo growpart /dev/vda 1
./vmctl ssh resources -- sudo resize2fs /dev/vda1
./vmctl ssh resources -- df -h /
```

Check live CPU decrease, live ceiling changes, memory above the ceiling, and
any disk decrease are rejected. Stop the VM, reduce CPU count, increase the
memory ceiling, restart, and confirm saved resources and the new ceiling work:

```sh
./vmctl stop resources
./vmctl resize resources --cpus 2
./vmctl resize resources --memory-max 6144
./vmctl start resources
./vmctl resize resources --memory 5120
./vmctl ssh resources -- lscpu
./vmctl ssh resources -- free -m
./vmctl ssh resources -- lsblk -b
./vmctl stop resources
./vmctl delete resources --yes
```

Also start an instance created before the upgrade and confirm the fallback
memory ceiling equals its saved memory. A VM still running the old launch
configuration must reject live CPU/memory changes until restarted.
