#!/usr/bin/env python3
"""tests/qemu_test.py — Automated QEMU shell test using PTY
Spawns QEMU, waits for shell prompt, sends commands, validates output.
Usage: python3 tests/qemu_test.py [sagevm|c-only]
"""

import subprocess, sys, os, time, signal, pty

PASS = FAIL = 0
GREEN = '\033[0;32m'; RED = '\033[0;31m'; CYAN = '\033[0;36m'; RESET = '\033[0m'

def T(name, condition):
    global PASS, FAIL
    if condition:
        print(f"  {GREEN}[PASS]{RESET} {name}")
        PASS += 1
    else:
        print(f"  {RED}[FAIL]{RESET} {name}")
        FAIL += 1

def run_qemu(mode='c-only'):
    """Launch QEMU with PTY serial, return (master_fd, proc)"""
    env = os.environ.copy()
    if mode == 'sagevm':
        env['SAGEVM'] = '1'
    
    master_fd, slave_fd = pty.openpty()
    
    cmd = ['qemu-system-riscv64',
           '-machine', 'virt', '-cpu', 'rv64', '-m', '128M',
           '-display', 'none',
           '-serial', f'/dev/pts/{os.ttyname(slave_fd).split("/")[-1]}' if False else f'fd:{slave_fd}',
           '-bios', '/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin',
           '-kernel', 'build/sageos.elf']
    
    # Actually use stdio since PTY fd passing is complex
    proc = subprocess.Popen(
        ['qemu-system-riscv64',
         '-machine', 'virt', '-cpu', 'rv64', '-m', '128M',
         '-display', 'none',
         '-chardev', f'file,id=char0,path=/tmp/qemu_out_{mode}.log',
         '-serial', 'chardev:char0',
         '-bios', '/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin',
         '-kernel', 'build/sageos.elf'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env
    )
    return proc

import fcntl
def set_nonblocking(fd):
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

def expect(proc, pattern, timeout=30):
    start = time.time()
    buf = ''
    set_nonblocking(proc.stdout.fileno())
    while time.time() - start < timeout:
        if proc.poll() is not None: break
        try:
            chunk = os.read(proc.stdout.fileno(), 1024).decode(errors='replace')
            if not chunk:
                time.sleep(0.1)
                continue
            buf += chunk
            if pattern in buf:
                return buf
        except BlockingIOError:
            time.sleep(0.1)
            continue
        except Exception:
            pass
    return buf

# =====================================================================
print(f"{CYAN}[BUILD] Compiling...{RESET}")
subprocess.run(['./sagemake', 'build'], capture_output=True)

# Test C-only mode
print(f"\n{CYAN}[TEST] C-Only Kernel...{RESET}")
proc = subprocess.Popen(
    ['qemu-system-riscv64',
     '-machine', 'virt', '-cpu', 'rv64', '-m', '128M',
     '-display', 'none',
     '-chardev', 'stdio,id=char0,mux=off',
     '-serial', 'chardev:char0',
     '-bios', '/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin',
     '-kernel', 'build/sageos.elf'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
)

# Wait for prompt
out = expect(proc, 'sage#', timeout=20)
T("Kernel boots to prompt", 'sage#' in out)

# Send help command
proc.stdin.write(b'help\n')
proc.stdin.flush()
out2 = expect(proc, 'Commands', timeout=5)
T("C-only: prompt appears", 'sage#' in out2 or 'sage#' in out)
T("C-only: help responds", 'Commands' in out2 or 'Commands' in out)

# Send halt
proc.stdin.write(b'halt\n')
proc.stdin.flush()
time.sleep(1)

proc.terminate()
proc.wait()

# =====================================================================
print(f"\n{CYAN}[TEST] SageVM Kernel...{RESET}")
env = os.environ.copy()
env['SAGEVM'] = '1'
subprocess.run(['./sagemake', 'build'], env=env, capture_output=True)

proc2 = subprocess.Popen(
    ['qemu-system-riscv64',
     '-machine', 'virt', '-cpu', 'rv64', '-m', '128M',
     '-display', 'none',
     '-chardev', 'stdio,id=char0,mux=off',
     '-serial', 'chardev:char0',
     '-bios', '/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin',
     '-kernel', 'build/sageos.elf'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
)

out3 = expect(proc2, 'sage#', timeout=20)
T("SageVM boots to prompt", 'sage#' in out3)

proc2.stdin.write(b'help\n')
proc2.stdin.flush()
time.sleep(1)

proc2.terminate()
proc2.wait()

# =====================================================================
total = PASS + FAIL
print(f"\n{CYAN}========================================{RESET}")
print(f"{CYAN}  QEMU Test Results{RESET}")
print(f"{CYAN}========================================{RESET}")
print(f"  Total:  {total}")
print(f"  {GREEN}Passed: {PASS}{RESET}")
print(f"  {RED}Failed: {FAIL}{RESET}")
print(f"{CYAN}========================================{RESET}")

if FAIL == 0:
    print(f"\n{GREEN}ALL TESTS PASSED{RESET}\n")
    sys.exit(0)
else:
    print(f"\n{RED}SOME TESTS FAILED{RESET}\n")
    sys.exit(1)
