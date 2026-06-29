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

def expect(proc, pattern, timeout=30):
    """Wait for pattern in QEMU output"""
    start = time.time()
    buf = ''
    while time.time() - start < timeout:
        line = ''
        try:
            line = proc.stdout.readline().decode(errors='replace')
        except:
            pass
        if not line and proc.poll() is not None:
            break
        buf += line
        if pattern in line:
            return buf
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
out = ''
for _ in range(200):  # ~20 seconds
    if proc.poll() is not None: break
    try:
        line = proc.stdout.readline().decode(errors='replace')
    except:
        time.sleep(0.1)
        continue
    if not line: break
    out += line
    if 'sage#' in line:
        break

T("Kernel boots to prompt", 'sage#' in out)

# Send help command
proc.stdin.write(b'help\n')
proc.stdin.flush()
time.sleep(1)
out2 = ''
try:
    while True:
        line = proc.stdout.readline().decode(errors='replace')
        if not line: break
        out2 += line
except:
    pass

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

out3 = ''
for _ in range(200):
    if proc2.poll() is not None: break
    try:
        line = proc2.stdout.readline().decode(errors='replace')
    except:
        time.sleep(0.1)
        continue
    if not line: break
    out3 += line
    if 'sage#' in line:
        break

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
