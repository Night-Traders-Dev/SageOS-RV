#!/bin/bash -e
# tools/make-sd-image.sh — Create bootable SD card image for LicheeRV Nano
#
# Usage:
#   ./tools/make-sd-image.sh <device>
#   ./tools/make-sd-image.sh <image-file>
#
# If a block device (e.g. /dev/sdb) is given, writes directly to it.
# If a file path is given, creates an image file.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

TARGET="$1"
if [ -z "$TARGET" ]; then
    echo "Usage: $0 <device|image-file>"
    echo "  e.g. sudo $0 /dev/sdb"
    echo "  e.g. $0 images/sageos-sd.img"
    exit 1
fi

FIP_SRC="/home/kraken/Devel/buildroot/LicheeSG-Nano-Build/fsbl/build/sg2002_licheervnano_sd/fip.bin"
DTS_SRC="boot/dts/sg2002-licheerv-nano.dts"

BOOT_SIZE_MB=64
IMAGE_SIZE_MB=256

echo "== SageOS-RV SD Card Image Builder =="
echo "  Target: $TARGET"
echo ""

# --- Verify source files ---
for f in images/sageos.bin images/boot.scr "$FIP_SRC" "$DTS_SRC"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing $f"
        exit 1
    fi
done

# Compile DTB
DTB_OUT=$(mktemp /tmp/sageos-dtb-XXXXXX)
dtc -I dts -O dtb -o "$DTB_OUT" "$DTS_SRC" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to compile $DTS_SRC"
    exit 1
fi
echo "  Compiled device tree."
echo ""

# --- Determine if target is a block device or file ---
if [ -b "$TARGET" ]; then
    DEVICE="$TARGET"
    IS_BLOCK=1
    echo "Writing directly to block device $DEVICE"
    echo "WARNING: This will ERASE all data on $DEVICE!"
    if [ -t 0 ]; then
        echo "Press Ctrl+C to abort, Enter to continue."
        read -r
    else
        echo "(non-interactive, proceeding in 3 seconds...)"
        sleep 3
    fi
else
    DEVICE=""
    IMG_FILE="$TARGET"
    IS_BLOCK=0
    echo "Creating image file: $IMG_FILE"
fi

echo ""

# --- Create or write image ---
if [ "$IS_BLOCK" -eq 0 ]; then
    echo "Creating ${IMAGE_SIZE_MB}MB image file..."
    dd if=/dev/zero of="$IMG_FILE" bs=1M count="$IMAGE_SIZE_MB" status=progress
    DEVICE="$IMG_FILE"
fi

echo ""

# --- Partition table ---
echo "Wiping existing partition table to prevent auto-mounter interference..."
if [ "$IS_BLOCK" -eq 1 ]; then
    wipefs -a "$DEVICE" 2>/dev/null || true
    dd if=/dev/zero of="$DEVICE" bs=1M count=10 status=none
    partprobe "$DEVICE" 2>/dev/null || true
    sleep 2
fi

echo "Writing partition table..."
PART_START=2048
PART_SIZE_SECTORS=$((BOOT_SIZE_MB * 2048))

sfdisk "$DEVICE" <<EOF
label: dos
unit: sectors

1 : start=$PART_START, size=$PART_SIZE_SECTORS, type=c
EOF

echo ""

# --- Get partition device ---
if [ "$IS_BLOCK" -eq 1 ]; then
    # Re-read partition table
    partprobe "$DEVICE" 2>/dev/null || sleep 2
    PART_DEV="${DEVICE}1"
    echo "Using partition device: $PART_DEV"
else
    # Set up loop device
    LOOP_DEV=$(losetup --find --partscan --show "$DEVICE" 2>/dev/null || true)
    if [ -z "$LOOP_DEV" ]; then
        # Fallback: direct offset
        echo "losetup --partscan not available, using offset..."
        PART_OFFSET=$((PART_START * 512))
        PART_DEV=""
    else
        sleep 1
        PART_DEV="${LOOP_DEV}p1"
        echo "Using loop partition: $PART_DEV"
    fi
fi

# --- Format partition 1 as FAT32 ---
if [ -n "$PART_DEV" ]; then
    echo "Formatting ${PART_DEV} as FAT32..."
    mkfs.vfat -F32 -n "SAGEOS_BOOT" "$PART_DEV"
else
    echo "Formatting partition 1 as FAT32 (direct offset)..."
    mkfs.vfat -F32 -n "SAGEOS_BOOT" -I --offset=$PART_START "$DEVICE"
fi

echo ""

# --- Copy files to partition ---
echo "Copying boot files..."
TMP_MNT=$(mktemp -d)

if [ -n "$PART_DEV" ]; then
    mount "$PART_DEV" "$TMP_MNT"
else
    mount -o loop,offset=$PART_OFFSET "$DEVICE" "$TMP_MNT"
fi

# --- Generate FIT Image (boot.sd) ---
echo "Generating boot.sd (FIT image)..."
ITS_FILE=$(mktemp /tmp/sageos-its-XXXXXX)
cat > "$ITS_FILE" <<EOF
/dts-v1/;
/ {
    description = "SageOS-RV FIT Image";
    #address-cells = <1>;
    images {
        kernel {
            description = "SageOS-RV Kernel";
            data = /incbin/("$PROJECT_DIR/images/sageos.bin");
            type = "kernel";
            arch = "riscv";
            os = "linux";
            compression = "none";
            load = <0x80200000>;
            entry = <0x80200000>;
        };
        fdt {
            description = "SageOS-RV Device Tree";
            data = /incbin/("$DTB_OUT");
            type = "flat_dt";
            arch = "riscv";
            compression = "none";
        };
    };
    configurations {
        default = "config-sg2002_licheervnano_sd";
        config-sg2002_licheervnano_sd {
            description = "Boot SageOS-RV (LicheeRV Nano)";
            kernel = "kernel";
            fdt = "fdt";
        };
        config-cv1800b_sophpi_duo_sd {
            description = "Boot SageOS-RV (Milk-V Duo)";
            kernel = "kernel";
            fdt = "fdt";
        };
        conf-sg2002_licheervnano_sd {
            description = "Boot SageOS-RV (alt conf name)";
            kernel = "kernel";
            fdt = "fdt";
        };
    };
};
EOF
mkimage -f "$ITS_FILE" "$TMP_MNT/boot.sd" >/dev/null 2>&1
rm -f "$ITS_FILE"

cp "$FIP_SRC"                "$TMP_MNT/fip.bin"
cp "$PROJECT_DIR/images/boot.scr" "$TMP_MNT/boot.scr"
cp "$PROJECT_DIR/images/sageos.bin" "$TMP_MNT/sageos.bin"
cp "$PROJECT_DIR/images/uImage"     "$TMP_MNT/uImage"
cp "$DTB_OUT"                "$TMP_MNT/sg2002-licheerv-nano.dtb"

sync
umount "$TMP_MNT"
rmdir "$TMP_MNT"
rm -f "$DTB_OUT"

echo "  Files copied."
echo ""

# --- Cleanup ---
if [ "$IS_BLOCK" -eq 0 ] && [ -n "$LOOP_DEV" ]; then
    losetup -d "$LOOP_DEV"
fi

echo "=== Done ==="
if [ "$IS_BLOCK" -eq 0 ]; then
    echo "Image created: $IMG_FILE"
    echo "Flash with: sudo dd if=$IMG_FILE of=/dev/sdb bs=1M status=progress"
fi
