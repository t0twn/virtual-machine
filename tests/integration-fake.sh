#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
tmp=$root/tests/.tmp-integration-$$
state=$tmp/state
shared=$tmp/shared
cleanup() {
    if [ -s "$state/instances/demo/qemu.pid" ]; then
        pid=$(sed -n '1p' "$state/instances/demo/qemu.pid")
        kill "$pid" 2>/dev/null || true
    fi
    for pidfile in "$state/instances/demo"/virtiofs-*.pid; do
        [ -f "$pidfile" ] || continue
        kill "$(sed -n '1p' "$pidfile")" 2>/dev/null || true
    done
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$state/images/objects" "$state/images/refs" "$shared"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
: > "$state/images/objects/$sha.img"
printf '%s\n' "$sha" > "$state/images/refs/24.04"
printf 'host input\n' > "$shared/input.txt"

run_vmctl() {
    VMCTL_STATE_DIR=$state \
    VMCTL_RUNTIME_DIR=$root/tests/fixtures \
    VMCTL_ALLOW_HOST_TOOLS=1 \
    VMCTL_TESTING=1 \
    VMCTL_SSH_TIMEOUT=4 \
        "$root/vmctl" "$@"
}

VMCTL_QMP_LOG=$tmp/qmp.log
VMCTL_QEMU_LOG=$tmp/qemu.log
VMCTL_IMG_LOG=$tmp/img.log
export VMCTL_QMP_LOG VMCTL_QEMU_LOG VMCTL_IMG_LOG

expect_failure() {
    if run_vmctl "$@" > "$tmp/failure.log" 2>&1; then
        printf 'unexpected success: %s\n' "$*" >&2
        exit 1
    fi
}
assert_config() {
    actual=$(awk -F '\t' -v key="$1" '$1 == key {print $2}' "$state/instances/demo/config.tsv")
    [ "$actual" = "$2" ] || { printf 'config %s: expected %s, got %s\n' "$1" "$2" "$actual" >&2; exit 1; }
}

run_vmctl create demo --no-start --memory-max 8192 \
    --ssh-port 22444 \
    --forward tcp:28080:80 \
    --share "tests/.tmp-integration-$$/shared:/mnt/code:rw"

test -f "$state/instances/demo/disk.qcow2"
test -f "$state/instances/demo/seed.iso"
grep -q "$(printf 'ssh_port\t22444')" "$state/instances/demo/config.tsv"
grep -q "$(printf '\t/mnt/code\trw')" "$state/instances/demo/shares.tsv"
run_vmctl share list demo | grep -q '/mnt/code'

if run_vmctl share add demo --source tests/fixtures --target /mnt/unsafe >/dev/null 2>&1; then
    printf 'protected runtime share unexpectedly succeeded\n' >&2
    exit 1
fi

# Offline changes, validation, disk failure and shrink rejection.
run_vmctl resize demo --cpus 3
run_vmctl resize demo --memory 4096
assert_config cpus 3
assert_config memory_mib 4096
assert_config memory_max_mib 8192
expect_failure resize demo --disk 10
expect_failure resize demo --cpus 0
expect_failure resize demo --cpus 999999999999999999999999
expect_failure resize demo --memory invalid
expect_failure resize demo --memory-max 1024
expect_failure resize demo --cpus 4 --memory 4096
VMCTL_IMG_FAIL=1; export VMCTL_IMG_FAIL
expect_failure resize demo --disk 25
assert_config disk_gib 20
unset VMCTL_IMG_FAIL
run_vmctl resize demo --disk 25
assert_config disk_gib 25

run_vmctl start demo
# Launch includes CPU slots, balloon, the ceiling and shared RAM at that ceiling.
grep -q '3,sockets=255,cores=1,threads=1,maxcpus=255' "$VMCTL_QEMU_LOG"
grep -q 'virtio-balloon-pci,id=balloon0' "$VMCTL_QEMU_LOG"
grep -q 'size=8192M,share=on' "$VMCTL_QEMU_LOG"
grep -q '"execute":"balloon".*4294967296' "$VMCTL_QMP_LOG"

run_vmctl resize demo --cpus 5
assert_config cpus 5
grep -q '"socket-id":4' "$VMCTL_QMP_LOG"
expect_failure resize demo --cpus 256
expect_failure resize demo --cpus 2
expect_failure resize demo --memory-max 16384
expect_failure resize demo --memory 16384
run_vmctl resize demo --memory 2048
assert_config memory_mib 2048
run_vmctl resize demo --memory 6144
assert_config memory_mib 6144
run_vmctl resize demo --disk 30
assert_config disk_gib 30
grep -q '"execute":"block_resize".*"device":"root","size":32212254720' "$VMCTL_QMP_LOG"
expect_failure resize demo --disk 25

VMCTL_QMP_FAIL=1; export VMCTL_QMP_FAIL
expect_failure resize demo --memory 4096
assert_config memory_mib 6144
expect_failure resize demo --disk 35
assert_config disk_gib 30
unset VMCTL_QMP_FAIL
VMCTL_QMP_NO_REPLY=1; export VMCTL_QMP_NO_REPLY
expect_failure resize demo --memory 4096
assert_config memory_mib 6144
unset VMCTL_QMP_NO_REPLY
# Partial CPU additions are persisted, allowing a retry from the right socket.
VMCTL_QMP_FAIL_MATCH='"socket-id":6'; export VMCTL_QMP_FAIL_MATCH
expect_failure resize demo --cpus 8
assert_config cpus 6
unset VMCTL_QMP_FAIL_MATCH
run_vmctl resize demo --cpus 08
assert_config cpus 8
# A legacy running VM must restart before live CPU / memory adjustments.
mv "$state/instances/demo/resources.tsv" "$tmp/resources.tsv"
expect_failure resize demo --cpus 9
expect_failure resize demo --memory 4096
mv "$tmp/resources.tsv" "$state/instances/demo/resources.tsv"
run_vmctl status demo | grep -q "$(printf 'state\trunning')"
run_vmctl share list demo | grep -q 'running'
run_vmctl stop demo --force
run_vmctl status demo | grep -q "$(printf 'state\tstopped')"

run_vmctl resize demo --cpus 2
run_vmctl resize demo --memory 12288
assert_config memory_max_mib 12288
run_vmctl resize demo --memory 4096
run_vmctl resize demo --memory-max 4096
assert_config memory_max_mib 4096
run_vmctl share remove demo --target /mnt/code
# Restart persists new resources and also exercises ballooning without VirtioFS.
run_vmctl start demo
grep -q '2,sockets=255,cores=1,threads=1,maxcpus=255' "$VMCTL_QEMU_LOG"
if grep -q memory-backend-memfd "$VMCTL_QEMU_LOG"; then exit 1; fi
run_vmctl resize demo --memory 3072
mv "$state/instances/demo/qmp.sock" "$tmp/qmp.sock"
expect_failure resize demo --memory 2048
assert_config memory_mib 3072
mv "$tmp/qmp.sock" "$state/instances/demo/qmp.sock"
run_vmctl stop demo --force
test ! -s "$state/instances/demo/shares.tsv"
run_vmctl delete demo --yes
test ! -e "$state/instances/demo"

printf 'fake integration lifecycle passed\n'
