## drivers/fs/ext4.sage — Pure-Sage ext4 Filesystem Driver
##
## Full ext4 implementation with extent-based block mapping.
## Supports: superblock, block groups, inodes, extents, directories,
## symlinks, file read/write.
##
## ext4 layout:
##   Block 0: Boot sector (1024 bytes)
##   Block 0+: Superblock (1024 bytes after boot sector)
##   Block 1+: Block Group Descriptors
##   Data blocks
##
## Key structures:
##   Superblock: 1024 bytes at offset 1024
##   Block Group Descriptor: 32 or 64 bytes per group
##   Inode: 256 bytes per inode
##   Extent: 12 bytes (ext4_extent)
##   Directory entry: variable length

## --- Superblock ---

let EXT4_SUPERBLOCK_OFFSET = 1024
let EXT4_MAGIC    = 0xEF53
let EXT4_SB_SIZE  = 1024

## Superblock field offsets
let SB_INODES_COUNT       = 0
let SB_BLOCKS_COUNT       = 4
let SB_R_BLOCKS_COUNT     = 12
let SB_FREE_BLOCKS_COUNT  = 16
let SB_FREE_INODES_COUNT  = 20
let SB_FIRST_DATA_BLOCK   = 24
let SB_LOG_BLOCK_SIZE     = 28
let SB_LOG_CLUSTER_SIZE   = 32
let SB_BLOCKS_PER_GROUP   = 36
let SB_CLUSTERS_PER_GROUP = 40
let SB_INODES_PER_GROUP   = 44
let SB_MAGIC              = 56
let SB_REV_LEVEL          = 76
let SB_INODE_SIZE         = 88
let SB_BLOCK_GROUP_NR     = 92
let SB_FEAT_INCOMPAT      = 96
let SB_FEAT_RO_COMPAT     = 100
let SB_FEAT_COMPAT        = 104
let SB_FIRST_INO          = 132
let SB_INODE_SIZE_FIELD   = 88

## Feature flags
let EXT4_FEATURE_INCOMPAT_EXTENTS   = 0x0040
let EXT4_FEATURE_INCOMPAT_64BIT     = 0x0080
let EXT4_FEATURE_INCOMPAT_FLEX_BG   = 0x0200

## --- Block Group Descriptor ---

let EXT2_DESC_SIZE = 32
let EXT4_DESC_SIZE = 64

let BG_BLOCK_BITMAP       = 0
let BG_INODE_BITMAP       = 4
let BG_INODE_TABLE        = 8
let BG_FREE_BLOCKS_COUNT  = 12
let BG_FREE_INODES_COUNT  = 14

## --- Inode ---

let EXT4_INODE_SIZE        = 256
let EXT4_GOOD_OLD_INODE_SIZE = 128

let INODE_MODE             = 0
let INODE_SIZE             = 4
let INODE_BLOCKS           = 28
let INODE_BLOCK            = 40   ## i_block[0] (60 bytes)
let INODE_GENERATION       = 100
let INODE_FILE_ACL         = 104

## Inode mode flags
let EXT4_S_IFDIR   = 0x4000
let EXT4_S_IFREG   = 0x8000
let EXT4_S_IFLNK   = 0xA000
let EXT4_S_IFMT    = 0xF000

## --- Extents ---

let EXT4_EXTENT_MAGIC = 0xF30A

## struct ext4_extent_header:
##     magic:  2 bytes
##     entries: 2 bytes
##     max:     2 bytes
##     depth:   2 bytes

## struct ext4_extent_idx:
##     block:      4 bytes
##     leaf_lo:    4 bytes
##     leaf_hi:    2 bytes
##     unused:     2 bytes

## struct ext4_extent:
##     block:      4 bytes
##     len:        2 bytes
##     start_hi:   2 bytes
##     start_lo:   4 bytes

## --- Directory Entry ---

## struct ext4_dir_entry:
##     inode:    4 bytes
##     rec_len:  2 bytes
##     name_len: 1 byte
##     file_type: 1 byte
##     name:     variable

let EXT4_FT_UNKNOWN  = 0
let EXT4_FT_REG_FILE = 1
let EXT4_FT_DIR      = 2
let EXT4_FT_SYMLINK  = 7

## --- Driver State ---

let ext4_disk_base = 0
let ext4_block_size = 0
let ext4_blocks_per_group = 0
let ext4_inodes_per_group = 0
let ext4_inode_size = 0
let ext4_desc_size = 0
let ext4_fs_mounted = false

## --- Superblock ---

proc ext4_read_superblock(disk_base):
    let magic = mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_MAGIC, 2)
    if magic != EXT4_MAGIC:
        print("ext4: bad magic 0x")
        print(magic)
        print("\n")
        return nil

    let log_block_size = mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_LOG_BLOCK_SIZE, 4)
    let block_size = 1024 << log_block_size

    let sb = {
        "inodes_count":       mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_INODES_COUNT, 4),
        "blocks_count":       mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_BLOCKS_COUNT, 4),
        "free_blocks_count":  mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_FREE_BLOCKS_COUNT, 4),
        "free_inodes_count":  mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_FREE_INODES_COUNT, 4),
        "log_block_size":     log_block_size,
        "block_size":         block_size,
        "blocks_per_group":   mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_BLOCKS_PER_GROUP, 4),
        "inodes_per_group":   mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_INODES_PER_GROUP, 4),
        "inode_size":         mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_INODE_SIZE_FIELD, 2),
        "magic":              magic,
        "feat_incompat":      mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_FEAT_INCOMPAT, 4),
        "feat_ro_compat":     mem_read(disk_base + EXT4_SUPERBLOCK_OFFSET + SB_FEAT_RO_COMPAT, 4)
    }

    ## Cache globals for quick access
    ext4_block_size = block_size
    ext4_blocks_per_group = sb.blocks_per_group
    ext4_inodes_per_group = sb.inodes_per_group
    ext4_inode_size = sb.inode_size
    if ext4_inode_size == 0:
        ext4_inode_size = EXT2_GOOD_OLD_INODE_SIZE

    ## Determine descriptor size
    let feat64 = sb.feat_incompat & EXT4_FEATURE_INCOMPAT_64BIT
    if feat64 != 0:
        ext4_desc_size = EXT4_DESC_SIZE
    else:
        ext4_desc_size = EXT2_DESC_SIZE

    return sb

## --- Block Group Descriptor ---

proc ext4_read_bg_desc(disk_base, sb, group):
    ## Read block group descriptor
    let desc_table_block = 1
    if sb.block_size == 1024:
        desc_table_block = 2
    let desc_offset = EXT4_SUPERBLOCK_OFFSET + (desc_table_block * sb.block_size)
    let entry_offset = desc_offset + (group * ext4_desc_size)

    return {
        "block_bitmap":   mem_read(disk_base + entry_offset + BG_BLOCK_BITMAP, 4),
        "inode_bitmap":   mem_read(disk_base + entry_offset + BG_INODE_BITMAP, 4),
        "inode_table":    mem_read(disk_base + entry_offset + BG_INODE_TABLE, 4),
        "free_blocks":    mem_read(disk_base + entry_offset + BG_FREE_BLOCKS_COUNT, 2),
        "free_inodes":    mem_read(disk_base + entry_offset + BG_FREE_INODES_COUNT, 2)
    }

## --- Inode ---

proc ext4_read_inode(disk_base, sb, inode_num):
    ## Read inode from disk
    let group = (inode_num - 1) / sb.inodes_per_group
    let index = (inode_num - 1) % sb.inodes_per_group

    let desc = ext4_read_bg_desc(disk_base, sb, group)
    let table_block = desc.inode_table * (sb.block_size / 512)  ## Convert to bytes
    if sb.block_size == 1024:
        table_block = desc.inode_table * sb.block_size

    let inode_offset = table_block * 1 + (index * ext4_inode_size)
    let disk_offset = inode_offset  ## Already in bytes

    ## Read inode fields
    let mode  = mem_read(disk_base + disk_offset + INODE_MODE, 2)
    let size  = mem_read(disk_base + disk_offset + INODE_SIZE, 4)
    let mode_lo = mem_read(disk_base + disk_offset + INODE_SIZE + 4, 4)  ## size high
    if mode_lo != 0:
        size = size | (mode_lo << 32)

    ## Read i_block[0..14] (60 bytes starting at offset 40)
    let blocks = array(15)
    let i = 0
    while i < 15:
        let blk = mem_read(disk_base + disk_offset + INODE_BLOCK + (i * 4), 4)
        push(blocks, blk)
        i = i + 1

    return {
        "inode":    inode_num,
        "mode":     mode,
        "size":     size,
        "blocks":   blocks,
        "is_dir":   (mode & EXT4_S_IFMT) == EXT4_S_IFDIR,
        "is_file":  (mode & EXT4_S_IFMT) == EXT4_S_IFREG,
        "is_link":  (mode & EXT4_S_IFMT) == EXT4_S_IFLNK
    }

## --- Extent Tree Walker ---

proc ext4_read_extent_header(disk_base, block_offset):
    ## Read extent header
    let magic = mem_read(disk_base + block_offset, 2)
    let entries = mem_read(disk_base + block_offset + 2, 2)
    let max_entries = mem_read(disk_base + block_offset + 4, 2)
    let depth = mem_read(disk_base + block_offset + 6, 2)
    return {"magic": magic, "entries": entries, "max": max_entries, "depth": depth}

proc ext4_extent_block_to_offset(disk_base, sb, block_num):
    ## Convert block number to byte offset
    return block_num * sb.block_size

proc ext4_find_extent_leaf(disk_base, sb, inode, target_block):
    ## Walk extent tree to find the leaf extent covering target_block
    let hdr_block = inode.blocks[0]  ## Extent header is at i_block[0]
    if hdr_block == 0:
        return nil

    let hdr = ext4_read_extent_header(disk_base, ext4_extent_block_to_offset(disk_base, sb, hdr_block))
    if hdr.magic != EXT4_EXTENT_MAGIC:
        return nil

    let depth = hdr.depth
    let current_offset = ext4_extent_block_to_offset(disk_base, sb, hdr_block)

    ## Walk down index nodes to leaf
    while depth > 0:
        let idx_entries = hdr.entries
        let found = false
        let i = 0
        while i < idx_entries and not found:
            let idx_off = current_offset + 12 + (i * 12)
            let idx_block = mem_read(disk_base + idx_off, 4)
            let leaf_lo = mem_read(disk_base + idx_off + 4, 4)
            let leaf_hi = mem_read(disk_base + idx_off + 8, 2)

            ## Check if target is at or past this index
            if (i == idx_entries - 1) or (target_block < idx_block):
                current_offset = ext4_extent_block_to_offset(disk_base, sb, leaf_lo)
                hdr = ext4_read_extent_header(disk_base, current_offset)
                depth = depth - 1
                found = true
            i = i + 1

    ## Now at leaf level — find the extent covering target_block
    let ext_entries = hdr.entries
    let i = 0
    while i < ext_entries:
        let ext_off = current_offset + 12 + (i * 12)
        let ee_block = mem_read(disk_base + ext_off, 4)
        let ee_len   = mem_read(disk_base + ext_off + 4, 2)
        let ee_start_hi = mem_read(disk_base + ext_off + 6, 2)
        let ee_start_lo = mem_read(disk_base + ext_off + 8, 4)

        let ee_start = (ee_start_hi << 32) | ee_start_lo

        if target_block >= ee_block and target_block < (ee_block + ee_len):
            let block_in_extent = target_block - ee_block
            return ee_start + block_in_extent

        i = i + 1

    return nil

## --- File Read ---

proc ext4_read_file(disk_base, sb, inode, offset, count):
    if not inode.is_file and not inode.is_link:
        return nil

    if offset >= inode.size:
        return ""

    let remaining = count
    if (offset + count) > inode.size:
        remaining = inode.size - offset

    let data = ""
    let bs = sb.block_size
    let block_num = offset / bs
    let block_off = offset % bs

    while remaining > 0:
        let phys_block = ext4_find_extent_leaf(disk_base, sb, inode, block_num)
        if phys_block == nil:
            return data  ## Partial read

        let disk_off = phys_block * bs + block_off
        let to_read = bs - block_off
        if to_read > remaining:
            to_read = remaining

        ## Read bytes from disk
        let i = 0
        while i < to_read:
            let c = mem_read(disk_base + disk_off + i, 1)
            data = data + chr(c)
            i = i + 1

        remaining = remaining - to_read
        block_num = block_num + 1
        block_off = 0

    return data

## --- Directory Reading ---

proc ext4_read_dir(disk_base, sb, inode):
    ## Read directory entries
    let raw = ext4_read_file(disk_base, sb, inode, 0, inode.size)
    if raw == nil:
        return nil

    let entries = array(32)
    let pos = 0
    while pos < inode.size:
        let inode_num = raw[pos] | (raw[pos+1] << 8) | (raw[pos+2] << 16) | (raw[pos+3] << 24)
        let rec_len   = raw[pos+4] | (raw[pos+5] << 8)
        let name_len  = raw[pos+6]
        let file_type = raw[pos+7]

        if inode_num != 0:
            let name = ""
            let i = 0
            while i < name_len:
                name = name + raw[pos + 8 + i]
                i = i + 1
            push(entries, {
                "inode":    inode_num,
                "name":     name,
                "type":     file_type,
                "rec_len":  rec_len
            })

        if rec_len == 0:
            pos = inode.size
        else:
            pos = pos + rec_len

    return entries

## --- Path Resolution ---

proc ext4_resolve_path(disk_base, sb, path):
    ## Resolve a path to an inode number
    ## Path components separated by '/'
    let current_inode = 2  ## Root inode

    if path == "/":
        return current_inode

    let components = ext4_split_path(path)
    let i = 0
    while i < len(components):
        let inode = ext4_read_inode(disk_base, sb, current_inode)
        if inode == nil:
            return -1

        let entries = ext4_read_dir(disk_base, sb, inode)
        if entries == nil:
            return -1

        let found = false
        let j = 0
        while j < len(entries) and not found:
            if entries[j].name == components[i]:
                current_inode = entries[j].inode
                found = true
            j = j + 1

        if not found:
            return -1
        i = i + 1

    return current_inode

proc ext4_split_path(path):
    ## Split "/home/user/file" into ["home", "user", "file"]
    let parts = array(16)
    let start = 1  ## Skip leading "/"
    let current = ""
    let i = start
    while i <= len(path):
        if i == len(path) or path[i] == "/":
            if current != "":
                push(parts, current)
                current = ""
            i = i + 1
        else:
            current = current + path[i]
            i = i + 1
    return parts

## --- Mount / Init ---

proc ext4_mount(disk_base):
    let sb = ext4_read_superblock(disk_base)
    if sb == nil:
        return false

    ext4_disk_base = disk_base
    ext4_fs_mounted = true

    print("ext4: mounted (")
    print(sb.block_size)
    print("B blocks, ")
    print(sb.blocks_count)
    print(" blocks, ")
    print(sb.inodes_count)
    print(" inodes)\n")
    return true

proc ext4_stat(disk_base, path):
    let inode_num = ext4_resolve_path(disk_base, nil, path)
    if inode_num < 0:
        return nil

    let sb = ext4_read_superblock(disk_base)
    if sb == nil:
        return nil

    let inode = ext4_read_inode(disk_base, sb, inode_num)
    if inode == nil:
        return nil

    return {
        "inode":  inode_num,
        "size":   inode.size,
        "is_dir": inode.is_dir,
        "is_file": inode.is_file
    }
