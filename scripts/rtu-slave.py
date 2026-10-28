"""Minimal Modbus test pair for scripts/test-t2r.sh (stdlib only).

  rtu-slave.py /dev/ttyX       RTU slave 1 on a serial line: functions 3 and 4
                               return register N = 1000 + N; address 100 and up
                               is exception 02.
  rtu-slave.py --pty LINK      The same slave on a new pty; LINK points to its
                               line end, nothing holds it open (Modbus Tests
                               sees the line free once the gateway stops).
  rtu-slave.py --client PORT   Modbus TCP client: read 4 holding registers of
                               unit 1 from 127.0.0.1:PORT, check the values.
"""

import os
import socket
import struct
import sys
import termios
import time


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def slave(device: str) -> None:
    fd = os.open(device, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[3] &= ~(termios.ICANON | termios.ECHO)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    serve(fd)


def pty_slave(link: str) -> None:
    master, line = os.openpty()
    attrs = termios.tcgetattr(line)
    attrs[3] &= ~(termios.ICANON | termios.ECHO)
    termios.tcsetattr(line, termios.TCSANOW, attrs)
    if os.path.lexists(link):
        os.unlink(link)
    os.symlink(os.ttyname(line), link)
    os.close(line)
    serve(master)


def read_some(fd: int) -> bytes:
    """Read; a pty master gives EIO while nobody has the line end open."""
    while True:
        try:
            return os.read(fd, 256)
        except OSError:
            time.sleep(0.05)


def serve(fd: int) -> None:
    buf = b''
    while True:
        buf += read_some(fd)
        if len(buf) < 8:
            continue
        frame, buf = buf[:8], buf[8:]
        if crc16(frame[:6]) != struct.unpack('<H', frame[6:])[0]:
            buf = b''
            continue
        unit, func, start, count = struct.unpack('>BBHH', frame[:6])
        if unit != 1 or func not in {3, 4}:
            continue
        if start >= 100:
            body = struct.pack('>BBB', unit, func | 0x80, 2)
        else:
            body = struct.pack('>BBB', unit, func, 2 * count)
            body += b''.join(struct.pack('>H', 1000 + start + i) for i in range(count))
        time.sleep(0.005)
        os.write(fd, body + struct.pack('<H', crc16(body)))


def client(port: int) -> None:
    with socket.create_connection(('127.0.0.1', port), timeout=5) as s:
        s.sendall(struct.pack('>HHHBBHH', 7, 0, 6, 1, 3, 10, 4))
        answer = s.recv(256)
    values = struct.unpack('>4H', answer[9:17])
    ok = values == (1010, 1011, 1012, 1013)
    print(f'TCP {port}: registers 10..13 = {values} {"OK" if ok else "WRONG"}')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    if sys.argv[1] == '--client':
        client(int(sys.argv[2]))
    elif sys.argv[1] == '--pty':
        pty_slave(sys.argv[2])
    else:
        slave(sys.argv[1])
