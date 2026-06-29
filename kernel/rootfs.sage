## kernel/rootfs.sage — Embedded Root Filesystem Driver (SRFS format)
##
## Provides a read-only filesystem from an embedded archive.
## Format: "SRFS" magic + 4-byte file count + file entries.
## Each entry: 64-byte name + 4-byte size + data (padded to 4 bytes).
##
## The rootfs is embedded as a kernel section (.rootfs) and accessed
## via linker symbols _binary_rootfs_bin_start/_end.

let ROOTFS_MAGIC = 0x53465253    ## "SRFS" little-endian

## --- Rootfs Driver State ---

let rootfs_data = nil
let rootfs_size = 0
let rootfs_files = array(64)
let rootfs_file_count = 0
let rootfs_mounted = false

## --- File Entry ---

proc rootfs_mount(data_ptr, data_size):
    ## Mount the rootfs from embedded binary data
    rootfs_data = data_ptr
    rootfs_size = data_size

    ## Verify magic
    let magic = mem_read(data_ptr, 4)
    if magic != ROOTFS_MAGIC:
        print("rootfs: bad magic 0x")
        print(magic)
        print("\n")
        return false

    let count = mem_read(data_ptr + 4, 4)
    rootfs_file_count = count

    print("rootfs: mounted (")
    print(count)
    print(" files, ")
    print(data_size)
    print(" bytes)\n")

    ## Parse file entries
    let pos = 8
    let i = 0
    while i < count:
        ## Read name (64 bytes)
        let name = ""
        let j = 0
        while j < 64:
            let c = mem_read(data_ptr + pos + j, 1)
            if c == 0:
                pos = pos + 64
                break
            j = j + 1

        ## Read size (4 bytes)
        let fsize = mem_read(data_ptr + pos, 4)
        pos = pos + 4

        ## Record entry
        let entry = {
            name:   name,
            size:   fsize,
            offset: pos,
            type:   VFS_TYPE_FILE
        }
        push(rootfs_files, entry)

        ## Skip data (padded to 4 bytes)
        let padded = (fsize + 3) & ~3
        pos = pos + padded
        i = i + 1

    ## Add root directory
    let root_dir = {
        name:   "/",
        size:   0,
        offset: 0,
        type:   VFS_TYPE_DIR
    }

    rootfs_mounted = true
    return true

## --- VFS Driver Interface ---

proc rootfs_open(path, mode):
    ## Find file by path
    if not rootfs_mounted:
        return nil

    ## Strip leading '/' if present
    let lookup = path

    let i = 0
    while i < rootfs_file_count:
        let entry = rootfs_files[i]
        if entry != nil:
            if rootfs_path_match(lookup, entry.name):
                return {
                    name:   entry.name,
                    size:   entry.size,
                    offset: entry.offset,
                    type:   entry.type,
                    read:   rootfs_read_data
                }
        i = i + 1
    return nil

proc rootfs_read_data(self, pos, count):
    ## Read data from file at position pos
    if pos >= self.size:
        return ""
    let remaining = self.size - pos
    let n = count
    if n > remaining:
        n = remaining

    let result = ""
    let i = 0
    while i < n:
        let c = mem_read(rootfs_data + self.offset + pos + i, 1)
        result = result + c
        i = i + 1
    return result

proc rootfs_stat(path):
    let inode = rootfs_open(path, 0)
    if inode == nil:
        return nil
    return {
        name: inode.name,
        size: inode.size,
        type: inode.type
    }

proc rootfs_readdir(path):
    ## Return all files (flat filesystem — no subdirectories)
    let result = array(rootfs_file_count)
    let i = 0
    while i < rootfs_file_count:
        let entry = rootfs_files[i]
        if entry != nil:
            push(result, {
                name: entry.name,
                size: entry.size,
                type: entry.type
            })
        i = i + 1
    return result

proc rootfs_path_match(path, name):
    ## Simple string comparison for flat paths
    let pl = len(path)
    let nl = len(name)
    if pl != nl:
        return false
    let i = 0
    while i < pl:
        if path[i] != name[i]:
            return false
        i = i + 1
    return true

## --- Rootfs driver descriptor ---

let rootfs_driver = {
    open:    rootfs_open,
    stat:    rootfs_stat,
    readdir: rootfs_readdir
}
