## shell/shell.sage — SageOS-RV Interactive Shell
##
## Pure Sage shell with basic command processing.
## Supports: help, version, mem, clear, halt, echo

let shell_running = true
let input_buffer = ""

## --- Shell Commands ---

proc cmd_help():
    console_puts("SageOS-RV Shell Commands:\n")
    console_puts("  help     Show this help\n")
    console_puts("  version  Show kernel version\n")
    console_puts("  mem      Show memory statistics\n")
    console_puts("  clear    Clear screen\n")
    console_puts("  echo     Echo text back\n")
    console_puts("  halt     Halt the system\n")
    console_puts("  about    About SageOS\n")

proc cmd_version():
    console_puts("SageOS-RV v")
    console_puts(KERNEL_VERSION)
    console_puts("\n")
    console_puts("Kernel: ")
    console_puts(KERNEL_NAME)
    console_puts("\n")
    console_puts("Arch: RISC-V 64 (rv64imac)\n")

proc cmd_mem():
    let stats = pmm_stats()
    console_puts("Memory Statistics:\n")
    console_puts("  Total pages: ")
    console_put_dec(stats["total_pages"])
    console_puts("\n")
    console_puts("  Free pages:  ")
    console_put_dec(stats["free_pages"])
    console_puts("\n")
    console_puts("  Used pages:  ")
    console_put_dec(stats["used_pages"])
    console_puts("\n")
    console_puts("  Total KB:    ")
    console_put_dec(stats["total_kb"])
    console_puts("\n")
    console_puts("  Free KB:     ")
    console_put_dec(stats["free_kb"])
    console_puts("\n")

proc cmd_clear():
    ## ANSI clear screen
    console_puts("\033[2J\033[H")

proc cmd_echo(args):
    console_puts(args)
    console_puts("\n")

proc cmd_halt():
    console_puts("System halting...\n")
    shell_running = false

proc cmd_about():
    console_puts("SageOS-RV — A Pure Sage Operating System\n")
    console_puts("Target: LicheeRV Nano (Sophgo SG2002, RISC-V 64)\n")
    console_puts("Philosophy: C only where silicon requires it.\n")
    console_puts("            Everything else is Pure Sage.\n")
    console_puts("\n")
    console_puts("This is the canonical demonstration that SageLang\n")
    console_puts("can build a complete software stack from bare metal\n")
    console_puts("to applications.\n")

## --- Command Parser ---

proc parse_command(line):
    let trimmed = trim(line)
    if trimmed == "":
        return

    let parts = split(trimmed, " ", 2)
    let cmd = parts[0]
    let args = ""
    if len(parts) > 1:
        args = parts[1]

    if cmd == "help":
        cmd_help()
    elif cmd == "version":
        cmd_version()
    elif cmd == "mem":
        cmd_mem()
    elif cmd == "clear":
        cmd_clear()
    elif cmd == "echo":
        cmd_echo(args)
    elif cmd == "halt":
        cmd_halt()
    elif cmd == "about":
        cmd_about()
    else:
        console_puts("Unknown command: ")
        console_puts(cmd)
        console_puts("\n")
        console_puts("Type 'help' for available commands.\n")

## --- String Utilities ---

proc trim(s):
    let start = 0
    let end = len(s) - 1
    while start < len(s) and s[start] == " ":
        start = start + 1
    while end >= 0 and s[end] == " ":
        end = end - 1
    if start > end:
        return ""
    let result = ""
    let i = start
    while i <= end:
        result = result + s[i]
        i = i + 1
    return result

proc split(s, delim, max_parts):
    let parts = []
    let current = ""
    let i = 0
    let count = 1
    while i < len(s):
        if s[i] == delim and count < max_parts:
            push(parts, current)
            current = ""
            count = count + 1
        else:
            current = current + s[i]
        i = i + 1
    push(parts, current)
    return parts

## --- Shell Main Loop ---

proc shell_main():
    console_puts("SageOS-RV Shell (type 'help' for commands)\n\n")

    shell_running = true
    while shell_running:
        console_puts("sage# ")
        input_buffer = ""

        ## Read line from UART
        let done = false
        while not done:
            let ch = uart_getc()
            if ch == -1:
                pass
            elif ch == 10 or ch == 13:
                console_puts("\n")
                done = true
            elif ch == 8 or ch == 127:
                ## Backspace
                if len(input_buffer) > 0:
                    input_buffer = input_buffer[:len(input_buffer)-1]
                    console_puts("\b \b")
            elif ch >= 32 and ch < 127:
                ## Printable character
                input_buffer = input_buffer + int_to_char(ch)
                uart_putc(ch)

        parse_command(input_buffer)

    console_puts("Goodbye.\n")

proc int_to_char(code):
    if code == 32: return " "
    if code == 33: return "!"
    if code == 34: return "\""
    if code >= 48 and code <= 57: return chr_digit(code)
    if code >= 65 and code <= 90: return chr_upper(code)
    if code >= 97 and code <= 122: return chr_lower(code)
    return "?"

proc chr_digit(code):
    if code == 48: return "0"
    if code == 49: return "1"
    if code == 50: return "2"
    if code == 51: return "3"
    if code == 52: return "4"
    if code == 53: return "5"
    if code == 54: return "6"
    if code == 55: return "7"
    if code == 56: return "8"
    if code == 57: return "9"
    return "?"

proc chr_upper(code):
    if code == 65: return "A"
    if code == 66: return "B"
    if code == 67: return "C"
    if code == 68: return "D"
    if code == 69: return "E"
    if code == 70: return "F"
    if code == 71: return "G"
    if code == 72: return "H"
    if code == 73: return "I"
    if code == 74: return "J"
    if code == 75: return "K"
    if code == 76: return "L"
    if code == 77: return "M"
    if code == 78: return "N"
    if code == 79: return "O"
    if code == 80: return "P"
    if code == 81: return "Q"
    if code == 82: return "R"
    if code == 83: return "S"
    if code == 84: return "T"
    if code == 85: return "U"
    if code == 86: return "V"
    if code == 87: return "W"
    if code == 88: return "X"
    if code == 89: return "Y"
    if code == 90: return "Z"
    return "?"

proc chr_lower(code):
    if code == 97: return "a"
    if code == 98: return "b"
    if code == 99: return "c"
    if code == 100: return "d"
    if code == 101: return "e"
    if code == 102: return "f"
    if code == 103: return "g"
    if code == 104: return "h"
    if code == 105: return "i"
    if code == 106: return "j"
    if code == 107: return "k"
    if code == 108: return "l"
    if code == 109: return "m"
    if code == 110: return "n"
    if code == 111: return "o"
    if code == 112: return "p"
    if code == 113: return "q"
    if code == 114: return "r"
    if code == 115: return "s"
    if code == 116: return "t"
    if code == 117: return "u"
    if code == 118: return "v"
    if code == 119: return "w"
    if code == 120: return "x"
    if code == 121: return "y"
    if code == 122: return "z"
    return "?"
