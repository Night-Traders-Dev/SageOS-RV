#!/usr/bin/env bash
## tools/mkrootfs.sh — Create SageOS-RV root filesystem archive
## Generates an SRFS-format archive from a directory tree.
## Usage: ./tools/mkrootfs.sh <input_dir> <output_file>

set -euo pipefail
INPUT="${1:-rootfs}"
OUTPUT="${2:-build/rootfs.bin}"

echo "Creating rootfs archive: $OUTPUT"

# Create temp file for the archive
TMP=$(mktemp)
trap "rm -f $TMP" EXIT

# Write magic "SRFS"
printf 'SRFS' > "$TMP"

# Count files (non-directory, non-hidden)
FILE_COUNT=$(find "$INPUT" -type f ! -name '.*' 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    # Create at least a welcome file for testing
    mkdir -p "$INPUT"
    echo "Welcome to SageOS-RV root filesystem!" > "$INPUT/welcome.txt"
    echo "Version: 0.3.0" >> "$INPUT/welcome.txt"
    echo "This is an embedded rootfs for SageOS-RV." >> "$INPUT/welcome.txt"
    FILE_COUNT=1
fi

# Write file count (4 bytes, little-endian)
printf '%08x' "$FILE_COUNT" | xxd -r -p >> "$TMP"

# Add each file
find "$INPUT" -type f ! -name '.*' | sort | while read -r f; do
    name=$(basename "$f")
    size=$(wc -c < "$f")
    
    # Name (64 bytes, null-padded)
    printf '%-64s' "$name" | head -c 64 >> "$TMP"
    
    # Size (4 bytes, little-endian)
    printf '%08x' "$size" | xxd -r -p >> "$TMP"
    
    # Data
    cat "$f" >> "$TMP"
    
    # Pad to 4-byte boundary
    while [ $(( $(wc -c < "$TMP") % 4 )) -ne 0 ]; do
        printf '\0' >> "$TMP"
    done
    
    echo "  + $name ($size bytes)"
done

cp "$TMP" "$OUTPUT"
echo "Created $OUTPUT ($(wc -c < "$OUTPUT") bytes, $FILE_COUNT files)"
