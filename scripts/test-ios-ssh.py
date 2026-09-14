#!/usr/bin/env python3
"""Run iOS terminal tests against an isolated local sshd, using a booted simulator.

Usage: python3 scripts/test-ios-ssh.py SIMULATOR_UDID
Only generated test keys are used; the Mac's SSH configuration is unchanged.
"""

import argparse
import base64
import getpass
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    build = ["xcodebuild", "-project", "Crow.xcodeproj", "-scheme", "Crow-iOS",
             "-destination", f"platform=iOS Simulator,id={args.simulator}",
             "-disableAutomaticPackageResolution"]
    subprocess.run(build + ["build-for-testing", "-quiet"], cwd=repo, check=True)
    settings = json.loads(subprocess.check_output(build + ["-showBuildSettings", "-json"], cwd=repo))
    app = next(item["buildSettings"] for item in settings if item["target"] == "Crow-iOS")
    subprocess.run(["xcrun", "simctl", "install", args.simulator,
                    str(Path(app["TARGET_BUILD_DIR"]) / app["FULL_PRODUCT_NAME"])], check=True)

    def fixture_path():
        container = subprocess.check_output([
            "xcrun", "simctl", "get_app_container", args.simulator, "dev.chajinwoo.crow", "data"
        ], text=True).strip()
        return Path(container) / "Documents" / "crow-ios-ssh-fixture.json"

    with tempfile.TemporaryDirectory(prefix="crow-ios-ssh-") as temporary:
        root = Path(temporary).resolve()
        project = root / "project with ' spaces"
        project.mkdir()
        subprocess.run(["/usr/bin/git", "init", "-q", "-b", "crow-fixture", str(project)], check=True)
        (project / "note.md").write_text("# Changed remote note\n")
        subprocess.run(["/usr/bin/git", "-C", str(project), "remote", "add", "origin", "git@github.com:fixture/repository.git"], check=True)
        subprocess.run(["/usr/bin/git", "-C", str(project), "config", "user.name", "iPad Fixture"], check=True)
        subprocess.run(["/usr/bin/git", "-C", str(project), "config", "user.email", "fixture@example.org"], check=True)
        (project / "download.png").write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII="))
        (project / "Move Destination").mkdir()
        for name in ("host-key", "user-key"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        username = getpass.getuser()
        (root / "sshd_config").write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host-key
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/user-key.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {username}
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
""")
        with (root / "sshd.log").open("w") as log:
            server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")],
                                      stdout=log, stderr=log)
        screen = subprocess.Popen(["python3", str(repo / "Tools/ScreenClient/vnc-fixture.py"),
                                   str(root / "vnc-port"), str(root / "vnc-events")])
        try:
            time.sleep(0.3)
            if server.poll() is not None:
                raise RuntimeError((root / "sshd.log").read_text())
            for _ in range(100):
                if (root / "vnc-port").exists():
                    break
                time.sleep(0.05)
            fixture = fixture_path()
            fixture.parent.mkdir(parents=True, exist_ok=True)
            fixture.write_text(json.dumps({"port": port, "username": username,
                "privateKey": (root / "user-key").read_text(), "directory": str(project),
                "screenPort": int((root / "vnc-port").read_text()), "screenEvents": str(root / "vnc-events")}))
            subprocess.run(build + ["test-without-building", "-quiet",
                "-only-testing:CrowTests/IOSTerminalIntegrationTests"], cwd=repo, check=True)
        finally:
            screen.terminate()
            screen.wait(timeout=5)
            try:
                fixture_path().unlink(missing_ok=True)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
