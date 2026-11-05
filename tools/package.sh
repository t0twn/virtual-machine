#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
version=$(sed -n 's/^VMCTL_VERSION=//p' "$root/lib/vmctl.sh" | head -n 1)
[ -n "$version" ] || { printf 'error: cannot determine version\n' >&2; exit 1; }
[ -x "$root/runtime/bin/qemu-system-x86_64" ] ||
    { printf 'error: build runtime first with tools/build-runtime.sh\n' >&2; exit 1; }

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

(
    cd "$root/runtime"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c SHA256SUMS >/dev/null
    else
        shasum -a 256 -c SHA256SUMS >/dev/null
    fi
) || { printf 'error: runtime integrity verification failed\n' >&2; exit 1; }

if [ -d "$root/third_party/sources" ]; then
    (
        cd "$root/third_party/sources"
        : > SHA256SUMS
        find . -type f ! -name SHA256SUMS -print |
            LC_ALL=C sort |
            while IFS= read -r file; do checksum "$file"; done >> SHA256SUMS
    )
fi

dist=$root/dist
stage=$dist/.stage-vmctl-$version
rm -rf "$stage"
mkdir -p "$stage/vmctl-$version" "$dist"

tar -C "$root" -cf - \
    vmctl lib runtime README.md LICENSE SECURITY.md THIRD_PARTY_NOTICES.md \
    docs tools build tests Makefile .gitignore third_party/SOURCES.md |
    tar -C "$stage/vmctl-$version" -xf -

archive=$dist/vmctl-$version-linux-x86_64.tar.gz
tar -C "$stage" -czf "$archive" "vmctl-$version"
(cd "$dist" && checksum "${archive##*/}") > "$archive.sha256"

if [ -d "$root/third_party/sources" ]; then
    source_archive=$dist/vmctl-$version-corresponding-source.tar.gz
    tar -C "$root/third_party" -czf "$source_archive" SOURCES.md sources
    (cd "$dist" && checksum "${source_archive##*/}") > "$source_archive.sha256"
fi

rm -rf "$stage"
printf 'Release artifacts written to %s\n' "$dist"
