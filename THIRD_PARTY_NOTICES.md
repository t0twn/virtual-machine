# Third-party software

Release archives bundle third-party software including QEMU, SeaBIOS,
virtiofsd, BusyBox, curl, GnuPG/gpgv, xorriso, OpenSSH, socat, util-linux,
glibc, and their shared-library dependencies.

Exact versions and the build base are recorded in `runtime/MANIFEST`. License
texts and distribution copyright notices are copied into `runtime/licenses`.
QEMU and BusyBox are GPL-licensed; their corresponding upstream/Ubuntu source
materials and the exact virtiofsd source tag are published beside the binary
release by `tools/package.sh`. The source bundle includes checksums, the QEMU
detached signature, and the pinned QEMU release public key.

The source-tree copy of vmctl itself is licensed under the MIT License.
