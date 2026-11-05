#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
engine=${CONTAINER_ENGINE:-}
if [ -z "$engine" ]; then
    if command -v podman >/dev/null 2>&1; then
        engine=podman
    elif command -v docker >/dev/null 2>&1; then
        engine=docker
    else
        printf 'error: podman or docker is required on the build machine\n' >&2
        exit 1
    fi
fi

tag=vmctl-runtime-build:0.1.0
tmp=$root/.runtime-build.$$
container=
cleanup() {
    [ -z "$container" ] || "$engine" rm "$container" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp"
"$engine" build --platform linux/amd64 \
    --file "$root/build/runtime.Dockerfile" --tag "$tag" "$root"
container=$("$engine" create --platform linux/amd64 "$tag")
"$engine" cp "$container:/out/." "$tmp/"

[ -x "$tmp/runtime/bin/qemu-system-x86_64" ] ||
    { printf 'error: runtime build did not produce QEMU\n' >&2; exit 1; }
[ -x "$tmp/runtime/bin/busybox" ] && [ -x "$tmp/runtime/bin/realpath" ] ||
    { printf 'error: runtime build did not produce a usable BusyBox environment\n' >&2; exit 1; }
[ -s "$tmp/runtime/SHA256SUMS" ] ||
    { printf 'error: runtime build did not produce integrity manifest\n' >&2; exit 1; }
[ "$(wc -c < "$tmp/sources/qemu-11.0.3.tar.xz")" -gt 100000000 ] ||
    { printf 'error: QEMU corresponding source is incomplete\n' >&2; exit 1; }
[ "$(wc -c < "$tmp/sources/qemu-11.0.3.tar.xz.sig")" -gt 100 ] ||
    { printf 'error: QEMU source signature is incomplete\n' >&2; exit 1; }

rm -rf "$root/runtime" "$root/third_party/sources"
mkdir -p "$root/third_party"
mv "$tmp/runtime" "$root/runtime"
mv "$tmp/sources" "$root/third_party/sources"
printf 'Portable runtime written to %s/runtime\n' "$root"
