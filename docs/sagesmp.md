# SageSMP Integration

## Overview

SageSMP is the multicore and distributed message-passing protocol for SageOS. It provides an Erlang-inspired mailbox architecture to allow different components of the system to communicate, whether they are running on different harts (cores) on the same SoC, or entirely different networked nodes!

*   **Submodule Location**: `kernel/smp/`
*   **Repository**: [SageSMP on GitHub](https://github.com/Night-Traders-Dev/SageSMP)
*   **Driver Output**: `drv_smp.sgvm`

## Architecture

At its core, SageSMP relies on:
*   **Mailboxes**: Thread-safe FIFO queues for inter-process communication.
*   **Node Registry**: Discovery and directory tracking for distributed topologies.
*   **Protocol Encoding**: Custom serialization framing.
*   **Cryptography**: End-to-end OTP (One Time Pad) style encryption for secure transmission.

It integrates seamlessly with the pure-Sage implementation of SageRTOS, sharing task coordination and scheduling mechanisms natively.

## Integration in SageOS

SageOS includes SageSMP as a Git submodule under the kernel drivers tree. During the build process, `sagemake` targets the `kernel/smp/src/sage/all.sage` wrapper file, which statically links all necessary SageSMP primitives into `drv_smp.sgvm`.

Once the kernel is booted, SageOS will initialize the local node, allowing userland tasks to request mailboxes and communicate securely over either local memory channels or the integrated TCP/IP stack!
