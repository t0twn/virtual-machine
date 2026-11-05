FROM ubuntu:22.04 AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG QEMU_VERSION=11.0.3
ARG VIRTIOFSD_VERSION=1.13.2
ARG RUST_VERSION=1.88.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git gnupg gpgv ninja-build pkg-config \
    python3 python3-venv xz-utils \
    libaio-dev libcap-ng-dev libfdt-dev libglib2.0-dev libpixman-1-dev \
    libseccomp-dev libslirp-dev liburing-dev libzstd-dev zlib1g-dev \
    busybox-static openssh-client socat util-linux xorriso \
    ubuntu-cloudimage-keyring \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-tomli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# QEMU release signatures are made by the documented release-manager key.
RUN gpg --batch --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys CEACC9E15534EBABB82D3FA03353C9CEF108B584 \
    && fingerprint=$(gpg --batch --with-colons --fingerprint \
        CEACC9E15534EBABB82D3FA03353C9CEF108B584 | awk -F: '$1 == "fpr" {print $10; exit}') \
    && test "$fingerprint" = CEACC9E15534EBABB82D3FA03353C9CEF108B584 \
    && curl --fail --location --proto '=https' --tlsv1.2 \
        --output qemu.tar.xz "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
    && curl --fail --location --proto '=https' --tlsv1.2 \
        --output qemu.tar.xz.sig "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz.sig" \
    && gpg --batch --verify qemu.tar.xz.sig qemu.tar.xz \
    && mkdir qemu-src \
    && tar -xJf qemu.tar.xz --strip-components=1 -C qemu-src \
    && gpgconf --kill all \
    && rm -rf /root/.gnupg

RUN cd qemu-src \
    && ./configure \
        --prefix=/usr/local \
        --target-list=x86_64-softmmu \
        --enable-kvm \
        --enable-slirp \
        --enable-tools \
        --disable-docs \
        --disable-gtk \
        --disable-sdl \
        --disable-vnc \
        --disable-spice \
        --disable-opengl \
        --disable-virglrenderer \
        --disable-rbd \
        --disable-libnfs \
        --disable-vde \
        --disable-modules \
        --disable-plugins \
        --disable-guest-agent \
        --disable-debug-info \
    && ninja -C build -j2 qemu-system-x86_64 qemu-img \
    && mkdir -p /stage/usr/local/bin /stage/usr/local/share/qemu \
    && cp build/qemu-system-x86_64 build/qemu-img /stage/usr/local/bin/ \
    && cp \
        pc-bios/bios.bin \
        pc-bios/bios-256k.bin \
        pc-bios/kvmvapic.bin \
        pc-bios/linuxboot_dma.bin \
        pc-bios/efi-virtio.rom \
        /stage/usr/local/share/qemu/ \
    && mkdir -p /stage/licenses \
    && cp COPYING /stage/licenses/QEMU-COPYING \
    && cd /build \
    && rm -rf qemu-src

RUN curl --fail --location --proto '=https' --tlsv1.2 \
        "https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init" \
        --output rustup-init \
    && chmod +x rustup-init \
    && ./rustup-init -y --profile minimal --default-toolchain "$RUST_VERSION"
ENV PATH=/root/.cargo/bin:$PATH

RUN git clone --depth 1 --branch "v${VIRTIOFSD_VERSION}" \
        https://gitlab.com/virtio-fs/virtiofsd.git virtiofsd-src \
    && cargo build --release --locked -j2 --manifest-path virtiofsd-src/Cargo.toml \
    && git -C virtiofsd-src archive --format=tar.gz \
        --output=/build/virtiofsd-${VIRTIOFSD_VERSION}.tar.gz HEAD \
    && cp virtiofsd-src/target/release/virtiofsd /stage/usr/local/bin/ \
    && for license in LICENSE-APACHE LICENSE-MIT; do \
        test ! -f "virtiofsd-src/$license" || \
            cp "virtiofsd-src/$license" "/stage/licenses/virtiofsd-$license"; \
       done \
    && rm -rf virtiofsd-src

COPY tools/collect-runtime.sh /usr/local/bin/collect-runtime
RUN chmod +x /usr/local/bin/collect-runtime \
    && QEMU_VERSION="$QEMU_VERSION" VIRTIOFSD_VERSION="$VIRTIOFSD_VERSION" \
        /usr/local/bin/collect-runtime /out \
    && mkdir -p /out/sources \
    && test "$(wc -c < /build/qemu.tar.xz)" -gt 100000000 \
    && test "$(wc -c < /build/qemu.tar.xz.sig)" -gt 100 \
    && cp /build/qemu.tar.xz /out/sources/qemu-${QEMU_VERSION}.tar.xz \
    && cp /build/qemu.tar.xz.sig /out/sources/qemu-${QEMU_VERSION}.tar.xz.sig \
    && cp "/build/virtiofsd-${VIRTIOFSD_VERSION}.tar.gz" /out/sources/ \
    && cmp /build/qemu.tar.xz /out/sources/qemu-${QEMU_VERSION}.tar.xz \
    && cmp /build/qemu.tar.xz.sig /out/sources/qemu-${QEMU_VERSION}.tar.xz.sig \
    && cmp "/build/virtiofsd-${VIRTIOFSD_VERSION}.tar.gz" \
        "/out/sources/virtiofsd-${VIRTIOFSD_VERSION}.tar.gz"

FROM scratch AS artifact
COPY --from=build /out /out
