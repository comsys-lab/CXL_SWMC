#!/usr/bin/env python3
"""Drive a libvirt serial console non-interactively and log everything.

Usage:
  vm-console.py --domain cxl_vm0 --log LOG [--start] [--timeout 180]
                [--wait REGEX] [--send CMD]... [--expect REGEX]

Steps: run `virsh console DOMAIN` (or `virsh start --console DOMAIN` with
--start) inside a pty; wait for --wait (default: a shell prompt); send each
--send line; then wait for --expect. Exit 0 on success, 2 on timeout, 3 if
virsh exits early. Never sends anything that is not passed via --send.
"""
import argparse, os, pty, re, select, signal, subprocess, sys, time

p = argparse.ArgumentParser()
p.add_argument('--uri', default='qemu:///system')
p.add_argument('--domain', required=True)
p.add_argument('--log', required=True)
p.add_argument('--start', action='store_true')
p.add_argument('--timeout', type=float, default=180)
p.add_argument('--wait', default=r'(^|\n)[^\n]*[#$] ?$')
p.add_argument('--send', action='append', default=[])
p.add_argument('--expect', default=None)
a = p.parse_args()

cmd = ['virsh', '-c', a.uri] + (['start', '--console', a.domain] if a.start
                                else ['console', a.domain])
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                        close_fds=True, start_new_session=True)
os.close(slave)
deadline = time.monotonic() + a.timeout
buf = b''
log = open(a.log, 'ab', buffering=0)
log.write(('\n=== %s %s\n' % (time.strftime('%FT%T%z'), ' '.join(cmd))).encode())


def read_until(pattern, poke=False):
    global buf
    rx = re.compile(pattern.encode(), re.M)
    start = len(buf)
    last_poke = time.monotonic()
    while time.monotonic() < deadline:
        if rx.search(buf[start:]):
            return True
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b''
            if not data:
                return None
            log.write(data)
            buf += data
        elif poke and time.monotonic() - last_poke > 10:
            os.write(master, b'\r')   # wake an idle console to show a prompt
            last_poke = time.monotonic()
    return False


def finish(code):
    try:
        os.write(master, b'\x1d')     # Ctrl-] detaches virsh console only
        proc.wait(timeout=5)
    except Exception:
        os.killpg(proc.pid, signal.SIGTERM)
    log.write(('\n=== exit %d\n' % code).encode())
    sys.exit(code)


res = read_until(a.wait, poke=True)
if res is not True:
    finish(2 if res is False else 3)
for line in a.send:
    os.write(master, line.encode() + b'\r')
    time.sleep(0.5)
if a.expect:
    res = read_until(a.expect)
    if res is not True:
        finish(2 if res is False else 3)
finish(0)
