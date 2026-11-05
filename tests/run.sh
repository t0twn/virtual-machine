#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
sh -n "$root/vmctl"
sh -n "$root/lib/vmctl.sh"
for script in "$root"/tools/*.sh "$root"/tests/*.sh "$root"/tests/fixtures/bin/*; do
    sh -n "$script"
done
"$root/tests/unit.sh"
"$root/tests/integration-fake.sh"
