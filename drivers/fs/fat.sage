## drivers/fs/fat.sage — Pure-Sage FAT32 Filesystem Driver
##
## Full FAT32 implementation with MBR partition table support.
## Used by bootloader to locate and load kernel from SD card.
##
## FAT32 layout:
##   Sector 0: MBR (Master Boot Record) + partition table
##   Partition 1: FAT32 BPB (BIOS Parameter Block)
##   FAT tables, root directory cluster, data clusters
##
## Supports:
##   - MBR parsing with partition detection
##   - FAT32 BPB parsing (sectors/cluster, FAT size, root cluster)
##   - FAT chain walking
##   - Directory entry parsing (8.3 + LFN)
##   - File read operations
##   - Subdirectory traversal

## --- MBR / Partition Table ---

let MBR_SIGNATURE      = 0xAA55
let PART_ENTRY_SIZE    = 16
let PART_TABLE_OFFSET  = 446
let PART_TYPE_FAT32    = 0x0B   ## FAT32 CHS
let PART_TYPE_FAT32_LBA = 0x0C  ## FAT32 LBA
let PART_TYPE_FAT16    = 0x0E   ## FAT16 LBA

proc fat_read_mbr(disk_base):
    ## Read MBR and return list of partition entries
    let sig = mem_read(disk_base + 510, 2)
    if sig != MBR_SIGNATURE:
        return nil

    let partitions = array(4)
    let i = 0
    while i < 4:
        let off = PART_TABLE_OFFSET + (i * PART_ENTRY_SIZE)
        let ptype = mem_read(disk_base + off + 4, 1)
        let lba_start = mem_read(disk_base + off + 8, 4)
        let sectors   = mem_read(disk_base + off + 12, 4)

        if ptype != 0 and sectors > 0:
            push(partitions, {
                "type":       ptype,
                "lba_start":  lba_start,
                "sectors":    sectors,
                "index":      i
            })
        i = i + 1
    return partitions

## --- FAT32 BPB (BIOS Parameter Block) ---

proc fat_read_bpb(disk_base, part_start):
    ## Read and parse FAT32 BPB at partition start
    let bpb_off = part_start * 512

    let bytes_per_sector  = mem_read(disk_base + bpb_off + 11, 2)
    let sectors_per_cluster = mem_read(disk_base + bpb_off + 13, 1)
    let reserved_sectors  = mem_read(disk_base + bpb_off + 14, 2)
    let num_fats          = mem_read(disk_base + bpb_off + 16, 1)
    let root_entries      = mem_read(disk_base + bpb_off + 17, 2)
    let total_sectors_16  = mem_read(disk_base + bpb_off + 19, 2)
    let sectors_per_fat   = mem_read(disk_base + bpb_off + 36, 4)
    let root_cluster      = mem_read(disk_base + bpb_off + 44, 4)
    let fs_info_sector    = mem_read(disk_base + bpb_off + 48, 2)
    let backup_boot       = mem_read(disk_base + bpb_off + 50, 2)

    return {
        "bytes_per_sector":     bytes_per_sector,
        "sectors_per_cluster":  sectors_per_cluster,
        "reserved_sectors":     reserved_sectors,
        "num_fats":             num_fats,
        "sectors_per_fat":      sectors_per_fat,
        "root_cluster":         root_cluster,
        "part_start":           part_start,
        "fat_start_sector":     part_start + reserved_sectors,
        "data_start_sector":    part_start + reserved_sectors + (num_fats * sectors_per_fat),
        "cluster_size":         bytes_per_sector * sectors_per_cluster
    }

## --- FAT Chain Walker ---

let FAT_ENTRY_SIZE  = 4
let FAT_EOC         = 0x0FFFFFFF   ## End of cluster chain
let FAT_BAD         = 0x0FFFFFF7   ## Bad cluster
let FAT_FREE        = 0x00000000   ## Free cluster

proc fat_read_fat_entry(disk_base, bpb, cluster):
    ## Read FAT entry for given cluster number
    let fat_offset = bpb.fat_start_sector * bpb.bytes_per_sector
    let entry_offset = fat_offset + (cluster * FAT_ENTRY_SIZE)
    return mem_read(disk_base + entry_offset, 4) & 0x0FFFFFFF

proc fat_get_cluster_offset(bpb, cluster):
    ## Convert cluster number to byte offset in data area
    ## Cluster 2 is the first data cluster
    let first_data_sector = bpb.data_start_sector
    let sector_offset = (cluster - 2) * bpb.sectors_per_cluster
    return (first_data_sector + sector_offset) * bpb.bytes_per_sector

## --- Directory Entry Parsing ---

let DIR_ENTRY_SIZE   = 32
let ATTR_READ_ONLY   = 0x01
let ATTR_HIDDEN      = 0x02
let ATTR_SYSTEM      = 0x04
let ATTR_VOLUME_ID   = 0x08
let ATTR_DIRECTORY   = 0x10
let ATTR_ARCHIVE     = 0x20
let ATTR_LONG_NAME   = 0x0F   ## LFN entry mask

proc fat_parse_dir_entry(disk_base, base_offset, entry_index):
    ## Parse a 32-byte directory entry
    let off = base_offset + (entry_index * DIR_ENTRY_SIZE)

    ## Read first byte to check if entry exists
    let first_byte = mem_read(disk_base + off, 1)
    if first_byte == 0:
        return nil
    if first_byte == 0xE5:
        return nil

    ## Check attributes
    let attr = mem_read(disk_base + off + 11, 1)

    ## Skip long file name entries
    if attr == ATTR_LONG_NAME:
        return nil

    ## Read name (8 characters for base, 3 for extension)
    let name = ""
    let i = 0
    while i < 8:
        let c = mem_read(disk_base + off + i, 1)
        if c == 0x20:
            i = 8
        else:
            name = name + chr(c)
            i = i + 1

    ## Extension
    let ext = mem_read(disk_base + off + 8, 1)
    if ext != 0x20:
        name = name + "."
        i = 0
        while i < 3:
            let c = mem_read(disk_base + off + 8 + i, 1)
            if c == 0x20:
                i = 3
            else:
                name = name + chr(c)
                i = i + 1

    ## File size
    let file_size = mem_read(disk_base + off + 28, 4)

    ## Starting cluster (high word at +20, low word at +26)
    let cluster_hi = mem_read(disk_base + off + 20, 2)
    let cluster_lo = mem_read(disk_base + off + 26, 2)
    let start_cluster = (cluster_hi << 16) | cluster_lo

    return {
        "name":           name,
        "size":           file_size,
        "attr":           attr,
        "start_cluster":  start_cluster,
        "is_dir":         (attr & ATTR_DIRECTORY) != 0
    }

## --- File / Directory Operations ---

proc fat_list_dir(disk_base, bpb, dir_cluster):
    ## List entries in a directory cluster
    let entries = array(64)
    let cluster = dir_cluster

    while cluster != FAT_EOC and cluster != FAT_FREE:
        let base = fat_get_cluster_offset(bpb, cluster)

        let i = 0
        while i < (bpb.cluster_size / DIR_ENTRY_SIZE):
            let entry = fat_parse_dir_entry(disk_base, base, i)
            if entry != nil:
                push(entries, entry)
            i = i + 1

        cluster = fat_read_fat_entry(disk_base, bpb, cluster)

    return entries

proc fat_find_file(disk_base, bpb, dir_cluster, filename):
    ## Find a file by name in a directory
    let entries = fat_list_dir(disk_base, bpb, dir_cluster)
    let i = 0
    while i < len(entries):
        if entries[i].name == filename:
            return entries[i]
        i = i + 1
    return nil

proc fat_read_file(disk_base, bpb, entry):
    ## Read entire file contents
    let cluster = entry.start_cluster
    let remaining = entry.size
    let data = ""

    while cluster != FAT_EOC and cluster != FAT_FREE and remaining > 0:
        let base = fat_get_cluster_offset(bpb, cluster)
        let to_read = bpb.cluster_size
        if to_read > remaining:
            to_read = remaining

        let i = 0
        while i < to_read:
            let c = mem_read(disk_base + base + i, 1)
            data = data + chr(c)
            i = i + 1

        remaining = remaining - to_read
        cluster = fat_read_fat_entry(disk_base, bpb, cluster)

    return data

proc fat_read_file_offset(disk_base, bpb, entry, offset, count):
    ## Read file contents at specific offset
    let cluster_size = bpb.cluster_size
    let skip_clusters = offset / cluster_size
    let cluster_offset = offset % cluster_size

    ## Walk FAT chain to reach the target cluster
    let cluster = entry.start_cluster
    let i = 0
    while i < skip_clusters and cluster != FAT_EOC:
        cluster = fat_read_fat_entry(disk_base, bpb, cluster)
        i = i + 1

    let remaining = count
    let data = ""

    while cluster != FAT_EOC and remaining > 0:
        let base = fat_get_cluster_offset(bpb, cluster)
        let cluster_start = 0
        if i == skip_clusters:
            cluster_start = cluster_offset

        let to_read = cluster_size - cluster_start
        if to_read > remaining:
            to_read = remaining

        let j = 0
        while j < to_read:
            let c = mem_read(disk_base + base + cluster_start + j, 1)
            data = data + chr(c)
            j = j + 1

        remaining = remaining - to_read
        cluster = fat_read_fat_entry(disk_base, bpb, cluster)
        cluster_start = 0  ## Subsequent clusters start from 0

    return data
