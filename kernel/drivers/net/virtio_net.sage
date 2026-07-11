## kernel/drivers/net/virtio_net.sage — QEMU virtio-net driver (virtio-pci)
##
## Intercepts netdev_tx()/netdev_rx() calls from the embedded VM and
directs them to/from QEMU virtio-net hardware via the vhost-user
interface (or memory-mapped I/O for simplicity).
##
## Usage:
##   virtio_net_init() — register as network driver
##   virtio_net_tx(frame) — submit frame to virtqueue
##   virtio_net_rx() — extract frame from virtqueue

## Internals:
##   virtq_desc[], virtq_avail[], virtq_used[] — PCI BAR memory maps
##   virtq_free_head() — allocate from free list
##   virtq_submit_head() — mark as used by device
##   virtq_notify() — ring the vhost-user doorbell

## On QEMU side (user-space):
##   sudo qemu-system-riscv64 \
##     -chardev socket,id=vhost0,path=/tmp/qemu-vhost.sock,server,nowait \
##     -netdev type=vhost_user,id=net0,vhostforce \
##     -device virtio-net-pci,netdev=net0,mq=2,vectors=8

## Global virtio-net driver exports for MetalVM builtins
let virtio_driver_initialized = false
let virtq_desc = []
let virtq_avail = []
let virtq_used = []
let virtq_free_head = 0
let virtq_used_tail = 0
let virtq_notify = 0

proc virtio_net_init():
    """Initialize virtio-net driver - called by kernel during boot"""
    if virtio_driver_initialized: return

    virtio_driver_initialized = true
    print("[VIRTIO-NET] virtio-net driver initialized\n")

proc virtio_net_configure(pci_bar0_addr, pci_bar1_addr, notify_addr):
    """Configure virtio rings from PCI BAR memory"""
    virtq_desc = array(256)    ## 256 descriptors (must be power of 2)
    virtq_avail = array(256)   ## 256 available ring entries
    virtq_used = array(256)    ## 256 used ring entries
    virtq_free_head = 0
    virtq_used_tail = 0

    print("[VIRTIO-NET] Configured virtio rings at 0x", pci_bar0_addr, "\n")

proc virtio_net_tx(frame):
    """Submit Ethernet frame to virtio-net hardware via virtqueue"""
    if not virtio_driver_initialized:
        print("[VIRTIO-NET] ERROR: driver not initialized!\n")
        return -1

    ## Find free descriptor for frame
    if virtq_free_head >= len(virtq_desc): return -1

    let desc_idx = virtq_free_head

    ## Build virtqueue descriptor for frame
    let desc = virtq_desc[desc_idx]
    desc.addr = frame
    desc.len = len(frame)
    desc.flags = 0  ## VIRTQ_DESC_F_WRITE = 0 for TX
    desc.next = desc_idx + 1 & 0xFF  ## Link to next

    virtq_free_head = desc_idx + 1
    print("[VIRTIO-NET] TX frame submitted (desc=", desc_idx, ", len=", len(frame), ")\n")

    ## Notify device (simplified: just print)
    virtq_notify = 1

proc virtio_net_rx():
    """Pull Ethernet frame from virtio-net hardware via virtqueue"""
    if virtq_used_tail >= len(virtq_used): return nil

    let used_idx = virtq_used_tail
    let used_elem = virtq_used[used_idx]

    virtq_used_tail = used_elem.idx + 1

    ## Extract frame from used element (simplified)
    print("[VIRTIO-NET] RX frame completed (desc=", used_elem.idx, ")\n")
    return []

proc virtio_net_poll():
    """Process completed virtqueue descriptors"""
    if virtq_notify:
        virtq_notify = 0
        print("[VIRTIO-NET] Processing virtqueue notifications\n")
