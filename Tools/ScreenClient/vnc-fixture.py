#!/usr/bin/env python3
"""Loopback-only RFB fixture: fragmented pixels, credential flow, and input recording.

This is a protocol test double, not a VNC server. It verifies the password "fixture".
"""
import argparse
import hmac
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
            greeting = read(12)
            if greeting == b"CROW FLOOD\r\n":
                # Exercise SSH teardown while substantial inbound data is still in flight.
                record(type="flood-start")
                try:
                    for _ in range(2048):
                        sock.sendall(bytes(32768))
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            assert greeting == b"RFB 003.008\n"
            # Mac-style ordering: account authentication first, then VNC password.
            send(b"\x02\x1e\x02")
            assert read(1) == b"\x02"
            send(bytes(range(16)))
            # Independent DES-ECB vector: challenge 00..0f, password "fixture",
            # padded to 8 bytes and with each key byte's bits reversed (RFB 3.8).
            expected = bytes.fromhex("b6cdfeac10a6a456b5d53a1644a7a475")
            if not hmac.compare_digest(read(16), expected):
                reason = b"Authentication or authorization failure"
                send(struct.pack(">II", 1, len(reason)) + reason)
                record(type="authentication-rejected")
                return
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
                        send(b"\x00\x00\x00\x02" + struct.pack(">HHHHi", 0, 0, 64, 48, 0) + pixel * 64 * 48
                             + struct.pack(">HHHHi", 0, 0, 0, 0, -239))  # Empty cursor: viewer must keep a visible fallback.
                        painted = True
                elif kind == 4:
                    down, key = struct.unpack(">B2xI", read(7))
                    record(type="key", down=down, key=key)
                    if down and key == ord('c'):
                        text = b"remote clipboard"
                        send(b"\x03\x00\x00\x00" + struct.pack(">I", len(text)) + text)
                elif kind == 5:
                    buttons, x, y = struct.unpack(">BHH", read(5))
                    record(type="pointer", buttons=buttons, x=x, y=y)
                elif kind == 6:
                    read(3)
                    text = read(struct.unpack(">I", read(4))[0])
                    record(type="clipboard", text=text.decode('latin-1'))
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
