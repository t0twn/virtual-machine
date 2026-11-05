# Portable runtime placeholder

Run `tools/build-runtime.sh` on an x86_64 Linux builder (or through an
amd64-capable Podman/Docker environment). The generated `runtime/` directory
contains QEMU 11.0.3, virtiofsd, firmware, command-line utilities, the ELF
loader, shared libraries, certificates, keyrings, and license files.

Only this README is stored in the source tree before the runtime is built.
