# SageFS Integration

## Overview

SageFS is the primary, native root filesystem used by SageOS. It is a log-structured, Copy-on-Write (CoW), B-tree based filesystem written entirely in SageLang.

*   **Submodule Location**: `fs/sagefs/`
*   **Repository**: [SageFS on GitHub](https://github.com/Night-Traders-Dev/SageFS)
*   **Driver Output**: `drv_sagefs.sgvm`

## Architecture

SageFS provides robust storage functionality that maps seamlessly onto SD/MMC and SPI NOR/NAND Flash hardware. By maintaining a log-structured approach with out-of-place updates, SageFS provides crash consistency without a separate journaling block device, which aligns cleanly with the flash storage architectures used by embedded hardware (e.g. LicheeRV Nano W).

## Integration in SageOS

SageOS pulls in the SageFS repository as a Git submodule. The `sagemake` build system is configured to compile the entire SageFS stack by targeting its `fs/sagefs/src/all.sage` graph.

During the build process:
1. `sagemake` locates the submodule at `fs/sagefs`.
2. It compiles `src/all.sage` directly into `build/drv_sagefs.sgvm`.
3. The kernel mounts the `sagefs` driver during initialization.

Because the entire filesystem logic operates as SageVM bytecode, it seamlessly interacts with the `sdcard.sage` block drivers and `cache.sage` logic in userspace, providing memory-safe, isolated filesystem handling without adding bulk to the microkernel!
