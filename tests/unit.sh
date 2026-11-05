#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

VMCTL_ROOT=$tmp/project
VMCTL_STATE_DIR=$tmp/state
VMCTL_RUNTIME_DIR=$project_root/tests/fixtures
VMCTL_ALLOW_HOST_TOOLS=1
export VMCTL_ROOT VMCTL_STATE_DIR VMCTL_RUNTIME_DIR VMCTL_ALLOW_HOST_TOOLS
mkdir -p "$VMCTL_ROOT/work tree" "$VMCTL_RUNTIME_DIR"

# shellcheck source=../lib/vmctl.sh
. "$project_root/lib/vmctl.sh"
init_state

failures=0
assert_eq() {
    expected=$1 actual=$2 label=$3
    if [ "$expected" != "$actual" ]; then
        printf 'not ok - %s (expected <%s>, got <%s>)\n' "$label" "$expected" "$actual"
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$label"
    fi
}

parsed=$(parse_share_spec 'work tree:/mnt/code:rw')
assert_eq 'work tree' "$(printf '%s' "$parsed" | awk -F "$TAB" '{print $1}')" 'share source parsing'
assert_eq '/mnt/code' "$(printf '%s' "$parsed" | awk -F "$TAB" '{print $2}')" 'share target parsing'
assert_eq 'rw' "$(printf '%s' "$parsed" | awk -F "$TAB" '{print $3}')" 'share mode parsing'

instance=$INSTANCES_DIR/test
mkdir -p "$instance"
share_add_record "$instance" 'work tree' /mnt/code ro
assert_eq relative "$(awk -F "$TAB" 'NR == 1 {print $2}' "$instance/shares.tsv")" 'project path is portable'
assert_eq /mnt/code "$(awk -F "$TAB" 'NR == 1 {print $4}' "$instance/shares.tsv")" 'share record target'

if (validate_name '../escape') >/dev/null 2>&1; then
    printf 'not ok - traversal name rejected\n'
    failures=$((failures + 1))
else
    printf 'ok - traversal name rejected\n'
fi
if (validate_guest_target /etc/shadow) >/dev/null 2>&1; then
    printf 'not ok - critical guest path rejected\n'
    failures=$((failures + 1))
else
    printf 'ok - critical guest path rejected\n'
fi

assert_eq "tcp${TAB}8080${TAB}80" "$(parse_forward_spec tcp:8080:80)" 'forward parsing'
[ "$failures" -eq 0 ]
