#!/usr/bin/env python3
"""Loopback-only RFB fixture: fragmented pixels, credential flow, and input recording.

This is a protocol test double, not a VNC server. It verifies the password "fixture".
"""
import argparse
import hmac
import hashlib
import getpass
import secrets
import subprocess
import json
import socket
import struct
import threading
from pathlib import Path


def serve(port_file, events_file):
    lock = threading.Lock()
    Path(events_file).write_text("")
    Path(events_file + ".auth").write_text("both")

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
            # Prefer the shared password on the server, so the client must explicitly
            # choose account authentication for a workspace account.
            mode_file = Path(events_file + ".auth")
            mode = mode_file.read_text().strip() if mode_file.exists() else "both"
            types = {"both": [2, 30], "account": [30], "vnc": [2], "unsupported-apple": [2, 33]}[mode]
            send(bytes([len(types), *types]))
            method = read(1)[0]
            record(type="security", method=method)
            username = None
            if method == 30:
                # Independent ARD type-30 server: DH, MD5, AES-128-ECB credentials.
                prime = int("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08"
                    "8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B"
                    "302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E"
                    "9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1"
                    "FE649286651ECE65381FFFFFFFFFFFFFFFF", 16)
                width = 128
                private = secrets.randbits(256)
                send(struct.pack(">HH", 2, width) + prime.to_bytes(width, "big")
                     + pow(2, private, prime).to_bytes(width, "big"))
                encrypted = read(128)
                public = int.from_bytes(read(width), "big")
                assert 1 < public < prime - 1
                shared = pow(public, private, prime).to_bytes(width, "big")
                key = hashlib.md5(shared).hexdigest()
                # This process only handles disposable fixture credentials.
                plain = subprocess.run(["/usr/bin/openssl", "enc", "-aes-128-ecb", "-d",
                    "-nopad", "-K", key], input=encrypted, capture_output=True, check=True).stdout
                username = plain[:64].split(b"\0", 1)[0].decode("utf-8")
                password = plain[64:].split(b"\0", 1)[0]
                accepted = username in (getpass.getuser(), "crow-screen-other") and hmac.compare_digest(password, b"fixture")
            elif method == 2:
                send(bytes(range(16)))
                # Independent DES-ECB vector for challenge 00..0f and "fixture".
                expected = bytes.fromhex("b6cdfeac10a6a456b5d53a1644a7a475")
                accepted = hmac.compare_digest(read(16), expected)
            else:
                raise ValueError(f"Unexpected authentication: {method}")
            if not accepted:
                reason = b"Authentication or authorization failure"
                send(struct.pack(">II", 1, len(reason)) + reason)
                record(type="authentication-rejected")
                return
            record(type="authentication", username=username)
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
