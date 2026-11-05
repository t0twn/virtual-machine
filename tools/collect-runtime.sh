#!/bin/sh
set -eu

out=${1:?output directory is required}
qemu_version=${QEMU_VERSION:?QEMU_VERSION is required}
virtiofsd_version=${VIRTIOFSD_VERSION:?VIRTIOFSD_VERSION is required}

mkdir -p "$out/runtime/bin" "$out/runtime/libexec" "$out/runtime/lib" \
    "$out/runtime/share/qemu" "$out/runtime/share/keyrings" \
    "$out/runtime/licenses"

cp -a /stage/usr/local/share/qemu/. "$out/runtime/share/qemu/"
cp /stage/usr/local/bin/qemu-system-x86_64 "$out/runtime/libexec/"
cp /stage/usr/local/bin/qemu-img "$out/runtime/libexec/"
cp /stage/usr/local/bin/virtiofsd "$out/runtime/libexec/"

for tool in curl gpgv xorriso ssh ssh-keygen socat unshare; do
    path=$(command -v "$tool")
    cp -L "$path" "$out/runtime/libexec/$tool"
done

cp /bin/busybox "$out/runtime/bin/busybox"
for applet in $(/bin/busybox --list); do
    [ "$applet" = busybox ] && continue
    ln -sf busybox "$out/runtime/bin/$applet"
done

cat > "$out/runtime/bin/.vmctl-tool-launcher" <<'EOF'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
runtime_dir=$(CDPATH= cd -- "$bin_dir/.." && pwd -P)
tool=${0##*/}
export SSL_CERT_FILE="$runtime_dir/share/ca-certificates.crt"
export CURL_CA_BUNDLE="$runtime_dir/share/ca-certificates.crt"
exec "$runtime_dir/lib/ld-linux-x86-64.so.2" \
    --library-path "$runtime_dir/lib" "$runtime_dir/libexec/$tool" "$@"
EOF
chmod +x "$out/runtime/bin/.vmctl-tool-launcher"

for tool in qemu-system-x86_64 qemu-img virtiofsd curl gpgv xorriso ssh ssh-keygen socat unshare; do
    ln -sf .vmctl-tool-launcher "$out/runtime/bin/$tool"
done

copy_elf_deps() {
    binary=$1
    ldd "$binary" |
        awk '
            /=> \// { print $3 }
            /^[[:space:]]*\// { sub(/^[[:space:]]*/, "", $1); print $1 }
        ' |
        while IFS= read -r library; do
            [ -n "$library" ] || continue
            cp -Lf "$library" "$out/runtime/lib/${library##*/}"
        done
}

for binary in "$out/runtime/libexec/"*; do
    copy_elf_deps "$binary"
done

# glibc loads NSS/resolver modules dynamically, so they do not appear in ldd.
for library in \
    /lib/x86_64-linux-gnu/libnss_dns.so.2 \
    /lib/x86_64-linux-gnu/libnss_files.so.2 \
    /lib/x86_64-linux-gnu/libresolv.so.2 \
    /lib64/ld-linux-x86-64.so.2; do
    [ ! -e "$library" ] || cp -Lf "$library" "$out/runtime/lib/${library##*/}"
done

cp /etc/ssl/certs/ca-certificates.crt "$out/runtime/share/"
cp /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg \
    "$out/runtime/share/keyrings/ubuntu-cloudimage-keyring.gpg"

cp /stage/licenses/QEMU-COPYING "$out/runtime/licenses/QEMU-COPYING"
for license in /stage/licenses/virtiofsd-*; do
    [ ! -f "$license" ] || cp "$license" "$out/runtime/licenses/"
done
for package in busybox-static curl gnupg xorriso openssh-client socat util-linux ubuntu-cloudimage-keyring; do
    [ ! -f "/usr/share/doc/$package/copyright" ] ||
        cp "/usr/share/doc/$package/copyright" "$out/runtime/licenses/$package.copyright"
done

cat > "$out/runtime/MANIFEST" <<EOF
runtime_format=1
architecture=x86_64
build_base=ubuntu-22.04
qemu=$qemu_version
virtiofsd=$virtiofsd_version
EOF

env -i HOME=/tmp PATH=/usr/bin:/bin \
    "$out/runtime/bin/qemu-system-x86_64" --version
env -i HOME=/tmp PATH=/usr/bin:/bin \
    "$out/runtime/bin/virtiofsd" --version
"$out/runtime/bin/busybox" sh -c \
    'command -v realpath >/dev/null && command -v sha256sum >/dev/null'

(
    cd "$out/runtime"
    find MANIFEST bin lib libexec licenses share -type f -print |
        LC_ALL=C sort |
        xargs sha256sum
) > "$out/runtime/SHA256SUMS"
