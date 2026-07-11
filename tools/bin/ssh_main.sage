## tools/bin/ssh_main.sage — SSH client command
##
## This file is concatenated AFTER kernel/net/tcp_stack.sage by
## tools/gen_ssh.sh to produce tools/bin/ssh.sage, which build_tools.sh
## then compiles to rootfs/bin/ssh.sgvm.  It must stay import-free and
## self-contained (the embedded RV64 VM has no import support).
##
## The command reads its arguments from argv() — a builtin supplied by the
## kernel.  It establishes a real TCP connection (using the kernel/net TCP
## stack) and performs the SSH identification (banner) exchange.  Key
## exchange and user authentication are layered on top of this transport in
## a later step; the TCP layer built here is what was missing before.

proc ssh_atoi(s):
    let v = 0
    let i = 0
    while i < len(s):
        let c = ord(s[i])
        if c >= 48 and c <= 57:
            v = v * 10 + (c - 48)
        i = i + 1
    return v

proc ssh_find(s, ch, start):
    let i = start
    while i < len(s):
        if s[i] == ch: return i
        i = i + 1
    return -1

proc ssh_substr(s, a, b):
    let r = ""
    let i = a
    while i < b and i < len(s):
        r = r + s[i]
        i = i + 1
    return r

proc ssh_resolve(host):
    ## Minimal resolver: well-known names + dotted-quad.
    if streq(host, "localhost"): return ip_aton("127.0.0.1")
    if streq(host, "127.0.0.1"): return ip_aton("127.0.0.1")
    if streq(host, "host"): return ip_aton("10.0.2.2")
    let ip = ip_aton(host)
    if ip != 0: return ip
    return 0

proc ssh_parse_target(arg):
    ## "user@host:port" | "host:port" | "user@host" | "host"
    let user = "root"
    let hostpart = arg
    let at = ssh_find(arg, "@", 0)
    if at >= 0:
        user = ssh_substr(arg, 0, at)
        hostpart = ssh_substr(arg, at + 1, len(arg))
    let port = 22
    let colon = ssh_find(hostpart, ":", 0)
    if colon >= 0:
        port = ssh_atoi(ssh_substr(hostpart, colon + 1, len(hostpart)))
        hostpart = ssh_substr(hostpart, 0, colon)
    return {"user": user, "host": hostpart, "port": port}

proc ssh_str_from_bytes(b):
    let s = ""
    let i = 0
    while i < len(b):
        s = s + chr(b[i])
        i = i + 1
    return s

proc ssh_connect_demo(target):
    print("[SSH] Resolving ")
    print(target["host"])
    print(" ...\n")
    let ip = ssh_resolve(target["host"])
    if ip == 0:
        print("[SSH] Cannot resolve host: ")
        print(target["host"])
        print("\n")
        return false
    print("[SSH] IP = ")
    print(ip_ntoa(ip))
    print(":")
    print(target["port"])
    print("\n")
    let fd = tcp_socket()
    tcp_connect(fd, ip, target["port"])
    let tries = 0
    while tries < 100 and not tcp_is_established(fd):
        tcp_poll(fd)
        tries = tries + 1
        net_clock = net_clock + 100
    if not tcp_is_established(fd):
        print("[SSH] TCP connection failed (timeout)\n")
        return false
    print("[SSH] TCP connection ESTABLISHED (")
    print(tcp_state_name(fd))
    print(")\n")
    let banner = []
    let bs = "SSH-2.0-SageOS-RV\r\n"
    let i = 0
    while i < len(bs):
        push(banner, ord(bs[i]))
        i = i + 1
    tcp_write(fd, banner)
    let rb = 0
    let got = nil
    while rb < 100:
        tcp_poll(fd)
        let data = tcp_read(fd)
        if not (data == nil):
            got = data
            break
        rb = rb + 1
        net_clock = net_clock + 100
    if not (got == nil):
        print("[SSH] Server banner: ")
        print(ssh_str_from_bytes(got))
    else:
        print("[SSH] (no server banner received)\n")
    print("[SSH] SSH transport established. KEX/auth layered next.\n")
    tcp_close(fd)
    return true

proc ssh_main():
    let args = argv()
    if streq(args, "") or streq(args, "help"):
        print("SSH Client - SSH-2.0 (RFC 4251-4254)\n")
        print("Usage:\n")
        print("  ssh <host>          e.g. ssh 127.0.0.1\n")
        print("  ssh <user>@<host>   e.g. ssh root@127.0.0.1\n")
        print("  ssh <host>:<port>\n")
        return
    let target = ssh_parse_target(args)
    ssh_connect_demo(target)

ssh_main()
