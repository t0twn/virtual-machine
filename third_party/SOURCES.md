# Corresponding source materials

`tools/package.sh` publishes `third_party/sources/` as a separate corresponding
source archive.

- `qemu-11.0.3.tar.xz` and its detached signature are the upstream QEMU
  11.0.3 release. `qemu-release-keyring.gpg` contains the fixed release-manager
  key whose fingerprint is `CEACC9E15534EBABB82D3FA03353C9CEF108B584`.
- `virtiofsd-1.13.2.tar.gz` is an archive of the exact upstream Git tag used by
  the build.
- `busybox-ubuntu-22.04/` contains the `.dsc`, pristine upstream archive, and
  Ubuntu patch archive for `busybox-static` source version
  `1:1.30.1-7ubuntu3.1`, matching the bundled Ubuntu 22.04 binary.

`sources/SHA256SUMS` is generated immediately before packaging.
