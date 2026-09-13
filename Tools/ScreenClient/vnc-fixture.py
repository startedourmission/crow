#!/usr/bin/env python3
"""Loopback-only RFB fixture: fragmented pixels, credential flow, and input recording.

This is a protocol test double, not a VNC server: any 16-byte auth response is accepted.
"""
import argparse
import json
import socket
import struct
import threading
from pathlib import Path


def serve(port_file, events_file):
    lock = threading.Lock()
    Path(events_file).write_text("")

    def record(**event):
        with lock, open(events_file, "a") as output:
            output.write(json.dumps(event) + "\n")

    def client(sock):
        def read(size):
            data = b""
            while len(data) < size:
                part = sock.recv(size - len(data))
                if not part:
                    raise EOFError()
                data += part
            return data

        def send(data):
            for start in range(0, len(data), 137):
                sock.sendall(data[start:start + 137])

        try:
            sock.settimeout(60)
            send(b"RFB 003.008\n")
            assert read(12) == b"RFB 003.008\n"
            send(b"\x01\x02")  # One security type: VNC password challenge.
            assert read(1) == b"\x02"
            send(bytes(range(16)))
            read(16)
            record(type="authentication")
            send(bytes(4))
            record(type="shared", value=read(1)[0])
            pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            name = b"Crow Screen Fixture"
            send(struct.pack(">HH", 64, 48) + pixel_format + struct.pack(">I", len(name)) + name)
            painted = False
            while True:
                kind = read(1)[0]
                if kind == 0:
                    read(3)
                    pixel_format = read(16)
                elif kind == 2:
                    read(1)
                    read(struct.unpack(">H", read(2))[0] * 4)
                elif kind == 3:
                    read(9)
                    if not painted:
                        bpp, _, big_endian, _, red, _, _, shift, _, _ = struct.unpack(">BBBBHHHBBB3x", pixel_format)
                        pixel = (red << shift).to_bytes(bpp // 8, "big" if big_endian else "little")
                        send(b"\x00\x00\x00\x01" + struct.pack(">HHHHi", 0, 0, 64, 48, 0) + pixel * 64 * 48)
                        painted = True
                elif kind == 4:
                    down, key = struct.unpack(">B2xI", read(7))
                    record(type="key", down=down, key=key)
                elif kind == 5:
                    buttons, x, y = struct.unpack(">BHH", read(5))
                    record(type="pointer", buttons=buttons, x=x, y=y)
                elif kind == 6:
                    read(3)
                    read(struct.unpack(">I", read(4))[0])
                else:
                    raise ValueError(f"Unexpected client message: {kind}")
        except EOFError:
            pass
        except Exception as error:
            record(type="error", message=str(error))
        finally:
            sock.close()
            record(type="closed")

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        Path(port_file).write_text(str(listener.getsockname()[1]))
        while True:
            sock, _ = listener.accept()
            threading.Thread(target=client, args=(sock,), daemon=True).start()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port_file")
    parser.add_argument("events_file")
    arguments = parser.parse_args()
    serve(arguments.port_file, arguments.events_file)
