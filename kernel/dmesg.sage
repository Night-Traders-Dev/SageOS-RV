## kernel/dmesg.sage — Persistent Diagnostic Message Log
##
## Ring buffer stored at a fixed physical address for persistence
## across warm resets. Survives soft reboot (DRAM not cleared).
## Cold boot initializes the buffer.
##
## Features:
##   - 256 messages, 128 bytes each (~32KB total)
##   - Timestamp (tick count) per message
##   - Severity levels: DEBUG, INFO, WARN, ERROR, FATAL
##   - Full dump and filtering

## --- Configuration ---

let DMESG_BASE      = 0x87010000    ## Physical address for log buffer
let DMESG_MAX_MSGS  = 256
let DMESG_MSG_SIZE  = 128
let DMESG_MAGIC     = 0x444D5347    ## "DMSG"

## --- Severity Levels ---

let DMESG_DEBUG  = 0
let DMESG_INFO   = 1
let DMESG_WARN   = 2
let DMESG_ERROR  = 3
let DMESG_FATAL  = 4

let severity_names = ["DEBUG", "INFO ", "WARN ", "ERROR", "FATAL"]

## --- Ring Buffer State (4KB header at DMESG_BASE) ---

proc dmesg_init():
    ## Check if dmesg buffer already has magic (warm boot)
    let magic = mem_read(DMESG_BASE, 4)
    if magic == DMESG_MAGIC:
        print("dmesg: warm boot detected, log preserved (")
        let count = mem_read(DMESG_BASE + 4, 4)
        print(count)
        print(" messages)\n")
        return

    ## Cold boot: initialize buffer
    print("dmesg: initializing log buffer @ 0x")
    print(DMESG_BASE)
    print("\n")

    ## Write magic
    mem_write(DMESG_BASE, DMESG_MAGIC, 4)
    ## Write count = 0
    mem_write(DMESG_BASE + 4, 0, 4)
    ## Write write position = 0
    mem_write(DMESG_BASE + 8, 0, 4)

proc dmesg_write(severity, message):
    ## Write a message to the ring buffer
    let count = mem_read(DMESG_BASE + 4, 4)
    let wpos  = mem_read(DMESG_BASE + 8, 4)
    let total = mem_read(DMESG_BASE + 12, 4)

    ## Message offset: header (16 bytes) + wpos * entry_size
    let entry_off = 16 + (wpos * DMESG_MSG_SIZE)

    ## Write severity byte
    mem_write(DMESG_BASE + entry_off, severity, 1)

    ## Write timestamp (tick count placeholder)
    let tick = total
    mem_write(DMESG_BASE + entry_off + 4, tick, 4)

    ## Write message (null-terminated, max 120 chars)
    let i = 0
    while i < 120:
        let c = message[i] & 0xFF
        mem_write(DMESG_BASE + entry_off + 8 + i, c, 1)
        if c == 0:
            break
        i = i + 1

    ## Update state
    wpos = (wpos + 1) % DMESG_MAX_MSGS
    if count < DMESG_MAX_MSGS:
        count = count + 1
    total = total + 1

    mem_write(DMESG_BASE + 4, count, 4)
    mem_write(DMESG_BASE + 8, wpos, 4)
    mem_write(DMESG_BASE + 12, total, 4)

    ## Also print to console for real-time visibility
    print("[")
    print(severity_names[severity])
    print("] ")
    print(message)
    print("\n")

proc dmesg_dump():
    ## Print all messages in the log
    let count = mem_read(DMESG_BASE + 4, 4)
    let wpos  = mem_read(DMESG_BASE + 8, 4)
    let total = mem_read(DMESG_BASE + 12, 4)

    print("\n========================================\n")
    print("  Diagnostig Message Log (dmesg)\n")
    print("  Messages: "); print(count); print("\n")
    print("  Total:    "); print(total); print("\n")
    print("========================================\n\n")

    ## Print from oldest to newest
    let start = wpos
    if count < DMESG_MAX_MSGS:
        start = 0

    let i = 0
    while i < count:
        let idx = (start + i) % DMESG_MAX_MSGS
        let entry_off = 16 + (idx * DMESG_MSG_SIZE)

        let sev = mem_read(DMESG_BASE + entry_off, 1)
        let tick = mem_read(DMESG_BASE + entry_off + 4, 4)

        print("["); print(i); print("] ")
        print("[");
        if sev <= DMESG_FATAL:
            print(severity_names[sev])
        else:
            print("???? ")
        print("] ")
        ## Print message body
        let j = 0
        while j < 120:
            let c = mem_read(DMESG_BASE + entry_off + 8 + j, 1)
            if c == 0:
                break
            print(c)
            j = j + 1
        print(" (tick="); print(tick); print(")\n")
        i = i + 1

    print("\n--- end of dmesg ---\n")

proc dmesg_filter(severity_min):
    ## Print messages at or above severity_min
    let count = mem_read(DMESG_BASE + 4, 4)
    let wpos  = mem_read(DMESG_BASE + 8, 4)
    let start = wpos
    if count < DMESG_MAX_MSGS:
        start = 0

    let i = 0
    while i < count:
        let idx = (start + i) % DMESG_MAX_MSGS
        let entry_off = 16 + (idx * DMESG_MSG_SIZE)
        let sev = mem_read(DMESG_BASE + entry_off, 1)
        if sev >= severity_min:
            ## Print this entry
            print("["); print(severity_names[sev]); print("] ")
            let j = 0
            while j < 120:
                let c = mem_read(DMESG_BASE + entry_off + 8 + j, 1)
                if c == 0:
                    break
                print(c)
                j = j + 1
            print("\n")
        i = i + 1

proc dmesg_clear():
    ## Clear the log buffer
    mem_write(DMESG_BASE + 4, 0, 4)
    mem_write(DMESG_BASE + 8, 0, 4)
    mem_write(DMESG_BASE + 12, 0, 4)
    print("dmesg: log cleared\n")
