## kernel/vfs.sage — SageOS-RV Virtual File System
##
## Provides a unified file system interface with mount points,
## path resolution, and file descriptors. Designed for embedded use.
##
## Layers:
##   VFS      — Path resolution, FD table, mount namespace
##   rootfs   — Embedded root filesystem driver (SRFS format)
##   Future:  — ext2, FAT32, devfs, procfs drivers
##
## API:
##   vfs_mount(dev, path, fstype)  — Mount a filesystem
##   vfs_open(path, mode)          — Open file, return FD
##   vfs_read(fd, buf, count)      — Read from FD
##   vfs_write(fd, buf, count)     — Write to FD
##   vfs_close(fd)                 — Close FD
##   vfs_seek(fd, offset, whence)  — Seek in FD
##   vfs_stat(path)                — Get file info
##   vfs_readdir(path)             — List directory entries
##   vfs_ls(path)                  — Print directory listing
##   vfs_cat(path)                 — Print file contents

## --- Constants ---

let VFS_MAX_FDS     = 32
let VFS_MAX_MOUNTS  = 8
let VFS_MAX_PATH    = 256
let VFS_NAME_MAX    = 64

let VFS_O_RDONLY    = 0
let VFS_O_WRONLY    = 1
let VFS_O_RDWR      = 2

let VFS_SEEK_SET    = 0
let VFS_SEEK_CUR    = 1
let VFS_SEEK_END    = 2

## --- File Types ---

let VFS_TYPE_FILE    = 0
let VFS_TYPE_DIR     = 1
let VFS_TYPE_DEV     = 2
let VFS_TYPE_SYMLINK = 3

## --- File Descriptor Table ---

let vfs_fds = array(VFS_MAX_FDS)
let vfs_fd_count = 0

proc vfs_fd_alloc():
    let i = 0
    while i < VFS_MAX_FDS:
        if vfs_fds[i] == nil:
            let fd = {
                inode:    nil,
                pos:      0,
                mode:     0,
                valid:    true
            }
            vfs_fds[i] = fd
            return i
        i = i + 1
    return -1

proc vfs_fd_free(fd):
    if fd >= 0 and fd < VFS_MAX_FDS:
        vfs_fds[fd] = nil

## --- Mount Table ---

let vfs_mounts = array(VFS_MAX_MOUNTS)
let vfs_mount_count = 0

proc vfs_mount_add(path, fs_driver):
    if vfs_mount_count >= VFS_MAX_MOUNTS:
        return -1
    let mnt = {
        path:     path,
        driver:   fs_driver,
        id:       vfs_mount_count
    }
    push(vfs_mounts, mnt)
    vfs_mount_count = vfs_mount_count + 1
    return mnt.id

proc vfs_find_mount(path):
    ## Find the mount point matching the longest path prefix
    let best = nil
    let best_len = 0
    let i = 0
    while i < vfs_mount_count:
        let mnt = vfs_mounts[i]
        if mnt != nil:
            let mnt_path = mnt.path
            let mnt_len = len(mnt_path)
            ## Check if mount path is a prefix of the requested path
            let match = true
            let j = 0
            while j < mnt_len:
                if path[j] != mnt_path[j]:
                    match = false
                j = j + 1
            if match and mnt_len > best_len:
                best = mnt
                best_len = mnt_len
        i = i + 1
    return best

## --- File API ---

proc vfs_open(path, mode):
    let mnt = vfs_find_mount(path)
    if mnt == nil:
        return -1

    let fd = vfs_fd_alloc()
    if fd < 0:
        return -1

    ## Ask the filesystem driver to open the file
    let inode = mnt.driver.open(path, mode)
    if inode == nil:
        vfs_fd_free(fd)
        return -1

    vfs_fds[fd].inode = inode
    vfs_fds[fd].mode  = mode
    vfs_fds[fd].pos   = 0
    return fd

proc vfs_read(fd, count):
    if fd < 0 or fd >= VFS_MAX_FDS:
        return nil
    let desc = vfs_fds[fd]
    if desc == nil or not desc.valid:
        return nil
    let data = desc.inode.read(desc.pos, count)
    desc.pos = desc.pos + len(data)
    return data

proc vfs_write(fd, data, count):
    return -1   ## Read-only for embedded rootfs

proc vfs_close(fd):
    vfs_fd_free(fd)

proc vfs_seek(fd, offset, whence):
    if fd < 0 or fd >= VFS_MAX_FDS:
        return -1
    let desc = vfs_fds[fd]
    if desc == nil:
        return -1
    if whence == VFS_SEEK_SET:
        desc.pos = offset
    elif whence == VFS_SEEK_CUR:
        desc.pos = desc.pos + offset
    elif whence == VFS_SEEK_END:
        desc.pos = desc.inode.size + offset
    return desc.pos

proc vfs_stat(path):
    let mnt = vfs_find_mount(path)
    if mnt == nil:
        return nil
    return mnt.driver.stat(path)

## --- Directory API ---

proc vfs_readdir(path):
    let mnt = vfs_find_mount(path)
    if mnt == nil:
        return nil
    return mnt.driver.readdir(path)

proc vfs_ls(path):
    let entries = vfs_readdir(path)
    if entries == nil:
        print("ls: cannot access '")
        print(path)
        print("': No such file or directory\n")
        return

    let i = 0
    while i < len(entries):
        let entry = entries[i]
        if entry != nil:
            if entry.type == VFS_TYPE_DIR:
                print("[DIR]  ")
            else:
                print("[FILE] ")
            print(entry.name)
            print("  ("); print(entry.size); print(" bytes)\n")
        i = i + 1

proc vfs_cat(path):
    let fd = vfs_open(path, VFS_O_RDONLY)
    if fd < 0:
        print("cat: '")
        print(path)
        print("': No such file\n")
        return

    let info = vfs_stat(path)
    if info != nil and info.size > 0:
        let data = vfs_read(fd, info.size)
        if data != nil:
            print(data)

    vfs_close(fd)
