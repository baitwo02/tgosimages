# AxVisor ivshmem UIO driver

`uio_ivshmem.c` and `Makefile` are vendored unchanged from the local TGOSKits
commit `5aeb5331ab533b94a62ac4b8d9c370720241949b`, path
`apps/linux/ivshmem/uio_ivshmem/` (fork: `baitwo02/tgoskits`). That commit was
not available from the remote fork when imported; image builds use this
checked-in copy, not a fetch of that commit.

License: GPL-2.0-only, as declared in both source files; see [COPYING](COPYING).
This module is not covered by the repository's top-level MIT license.
Imported `uio_ivshmem.c` SHA-256:
`4120e3758d75a8bb2d9bb354b7f65a2b1d80ace6fe796e26485452cfab221f15`.

This is the driver used by the AxVisor ivshmem suite, not a generic driver
for every device named ivshmem. It matches PCI `1af4:1110`, revision `01`,
requires exactly one MSI-X vector, and exposes BAR0 (registers) and BAR2
(shared memory) through UIO. It has no MSI/INTx fallback.

The standard AArch64 image builder compiles it in `build/standard-aarch64/`
against the same kernel tree as `uio.ko`, including UIO's exported symbols.
Both modules must be loaded, with `uio.ko` first. `axvisor.ko` is a separate
IVC driver, not a substitute.
