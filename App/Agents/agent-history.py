"""Read CLI-owned conversation records. No credentials or tool output are returned."""
import collections
import concurrent.futures
import datetime
import json
import os
import pathlib
import re
import selectors
import signal
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error


def canonical(path):
    return os.path.realpath(os.path.expanduser(path))


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(x.get("text", "") for x in value if isinstance(x, dict) and x.get("type") in ("text", "input_text", "output_text"))
    return ""


def records(path):
    # Bound each record and file while streaming; never load a whole transcript.
    total = 0
    with open(path, "rb") as stream:
        while total < 64 * 1024 * 1024:
            line = stream.readline(2 * 1024 * 1024)
            if not line:
                break
            total += len(line)
            if not line.endswith(b"\n"):
                while line and not line.endswith(b"\n"):
                    line = stream.readline(2 * 1024 * 1024)
                    total += len(line)
                continue
            try:
                value = json.loads(line)
                if isinstance(value, dict):
                    yield value
            except (ValueError, UnicodeError):
                continue


def valid_id(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F-]{36}", value) is not None


def safe_file(path, home):
    path = pathlib.Path(path)
    return path.is_file() and not path.is_symlink() and canonical(path).startswith(canonical(home) + os.sep)


def conversation(provider, path, workspace, home):
    workspace = canonical(workspace)
    first = None
    recent = collections.deque(maxlen=3)
    session_id = path.stem
    cwd = None
    title = ""
    tokens = None
    if provider == "grok":
        metadata = json.loads((path.parent / "summary.json").read_text())
        session_id = metadata.get("info", {}).get("id", path.parent.name)
        cwd = metadata.get("info", {}).get("cwd")
        title = metadata.get("session_summary") or ""
    seen = set()
    for item in records(path):
        kind = item.get("type")
        role, text = None, ""
        if provider == "codex":
            payload = item.get("payload") or {}
            if kind == "session_meta":
                cwd = payload.get("cwd")
                session_id = payload.get("id") or payload.get("session_id")
            if kind == "response_item" and payload.get("type") == "message":
                role = payload.get("role")
                text = text_content(payload.get("content"))
                # Agent setup is represented as user-role messages in older logs.
                if role == "user" and text.lstrip().startswith(("# AGENTS.md instructions", "<environment_context>", "<permissions instructions>")):
                    continue
            if kind == "event_msg" and payload.get("type") == "token_count":
                usage = (payload.get("info") or {}).get("total_token_usage") or {}
                tokens = usage.get("total_tokens", tokens)
        elif provider == "claude":
            if item.get("isSidechain"):
                return None
            cwd = item.get("cwd", cwd)
            session_id = item.get("sessionId", session_id)
            if kind == "custom-title":
                title = item.get("customTitle", title)
            if kind in ("user", "assistant") and not item.get("isMeta"):
                message = item.get("message") or {}
                role, text = kind, text_content(message.get("content"))
                identifier = item.get("uuid")
                if identifier and identifier in seen:
                    continue
                if identifier:
                    seen.add(identifier)
        else:
            if kind in ("user", "assistant") and not item.get("synthetic_reason"):
                role, text = kind, text_content(item.get("content"))
        if cwd and canonical(cwd) != workspace:
            return None
        if role not in ("user", "assistant") or not text.strip():
            continue
        message = {"role": role, "text": text.strip()[:1600]}
        if first is None and role == "user":
            first = message
        if not recent or recent[-1] != message:
            recent.append(message)
    if not cwd or canonical(cwd) != workspace or not valid_id(session_id) or first is None:
        return None
    stat = path.stat()
    return {"id": session_id, "provider": provider, "path": str(path), "title": (title or first["text"].split("\n")[0])[:150],
            "modified": stat.st_mtime, "size": stat.st_size, "first": first, "recent": list(recent), "tokens": tokens}


def candidates(provider, home, workspace):
    if not home.exists():
        return []
    if provider == "codex":
        return (home / "sessions").glob("**/*.jsonl")
    if provider == "claude":
        # Top-level records only; subagent logs live in nested directories.
        return (home / "projects").glob("*/*.jsonl")
    return (home / "sessions").glob("*/*/chat_history.jsonl")


def homes():
    return {"codex": pathlib.Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser(),
            "claude": pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser(),
            "grok": pathlib.Path(os.environ.get("GROK_HOME", "~/.grok")).expanduser()}


def list_sessions(workspace):
    result, warnings = [], []
    deadline = time.monotonic() + 7
    for provider, home in homes().items():
        names = {}
        index = home / "session_index.jsonl"
        if provider == "codex" and index.is_file():
            try:
                names = {row.get("id"): row["thread_name"] for row in records(index) if row.get("thread_name")}
            except OSError:
                pass
        paths = [p for p in candidates(provider, home, workspace) if safe_file(p, home)]
        paths.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        for path in paths[:2000]:
            if time.monotonic() > deadline:
                warnings.append("History scan reached its time limit. Showing sessions read so far.")
                break
            try:
                item = conversation(provider, path, workspace, home)
                if item:
                    if item["id"] in names:
                        item["title"] = names[item["id"]][:150]
                    result.append(item)
                if len(result) >= 100:
                    warnings.append("Showing the first 100 matching sessions.")
                    break
            except (OSError, ValueError, TypeError):
                continue
        if len(paths) > 2000:
            warnings.append(provider.title() + ": checked the 2,000 most recently changed records.")
    result.sort(key=lambda item: item["modified"], reverse=True)
    return {"sessions": result[:100], "warnings": sorted(set(warnings))}


def codex_rpc(method, params):
    process = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffered = b""

        def request(identifier, method, params):
            nonlocal buffered
            process.stdin.write((json.dumps({"id": identifier, "method": method, "params": params}) + "\n").encode())
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                while b"\n" in buffered:
                    line, buffered = buffered.split(b"\n", 1)
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    if value.get("id") == identifier:
                        if value.get("error"):
                            raise ValueError(value["error"].get("message", "Codex request failed"))
                        return value.get("result", {})
                if selector.select(timeout=0.1):
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise ValueError("Codex app server closed before replying.")
                    buffered += chunk
                    if len(buffered) > 2 * 1024 * 1024:
                        raise ValueError("Codex reply exceeded its limit.")
            raise ValueError("Codex request timed out.")

        request(1, "initialize", {"clientInfo": {"name": "crow", "version": "1.0"}, "capabilities": {"experimentalApi": True}})
        process.stdin.write(b'{"method":"initialized"}\n')
        return request(2, method, params)
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdin.close()
        process.stdout.close()


def delete_session(workspace, expected):
    provider, path = expected["provider"], pathlib.Path(expected["path"])
    home = homes().get(provider)
    if home is None or not safe_file(path, home):
        raise ValueError("Session file is outside this CLI's history directory.")
    current = conversation(provider, path, workspace, home)
    if not current or current["id"] != expected["id"]:
        raise ValueError("This session no longer belongs to the selected workspace.")
    if current["modified"] != expected["modified"] or current["size"] != expected["size"]:
        raise ValueError("This session changed. Refresh before deleting it.")
    if provider == "codex":
        codex_rpc("thread/delete", {"threadId": current["id"]})
    elif provider == "grok":
        result = subprocess.run(["grok", "sessions", "delete", current["id"]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
        if result.returncode:
            raise ValueError(result.stderr.decode(errors="replace")[:600] or "Grok could not delete this session.")
    else:
        # Claude stores the conversation in this JSONL; leave unrelated sessions untouched.
        index = path.parent / "sessions-index.json"
        if index.exists():
            data = json.loads(index.read_text())
            data["entries"] = [entry for entry in data.get("entries", []) if entry.get("sessionId") != current["id"]]
            temporary = index.with_name(index.name + ".crow-" + str(os.getpid()))
            try:
                with open(temporary, "x", encoding="utf-8") as stream:
                    json.dump(data, stream, ensure_ascii=False)
                os.chmod(temporary, index.stat().st_mode & 0o777)
                os.replace(temporary, index)
            finally:
                temporary.unlink(missing_ok=True)
        path.unlink()
        # Per-session subagent/tool records are also part of the deleted conversation.
        related = path.with_suffix("")
        if related.is_dir() and not related.is_symlink() and canonical(related).startswith(canonical(home) + os.sep):
            shutil.rmtree(related)
    return {"deleted": True}


def main():
    request = json.loads(sys.argv[1])
    action = request.get("action", "list")
    workspace = canonical(request["workspace"])
    if action == "list":
        return list_sessions(workspace)
    if action == "delete":
        return delete_session(workspace, request["session"])
    if action == "codex-usage":
        return codex_rpc("account/rateLimits/read", {})
    if action == "usage":
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            return {"providers": list(executor.map(provider_usage, ("claude", "codex", "grok")))}
    raise ValueError("Unknown history action.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Usage endpoint redirected; credentials were not forwarded.")


def get_json(url, headers):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.build_opener(NoRedirect).open(request, timeout=4) as response:
        return json.loads(response.read(512 * 1024))


def reset_time(value):
    if isinstance(value, (int, float)):
        return value
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


def provider_usage(provider):
    result = {"provider": provider, "windows": [], "error": None}
    try:
        if provider == "codex":
            data = codex_rpc("account/rateLimits/read", {})
            limits = (data.get("rateLimitsByLimitId") or {}).get("codex") or data.get("rateLimits") or {}
            for key in ("primary", "secondary"):
                window = limits.get(key)
                if window and "usedPercent" in window:
                    minutes = window.get("windowDurationMins")
                    label = "Weekly" if minutes == 10080 else "5 hours" if minutes == 300 else "Usage"
                    result["windows"].append({"label": label, "used": window["usedPercent"], "resets": window.get("resetsAt")})
        elif provider == "claude":
            credentials = homes()["claude"] / ".credentials.json"
            if not credentials.exists():
                raise ValueError("No readable Claude Code login on this host.")
            token = json.loads(credentials.read_text()).get("claudeAiOauth", {}).get("accessToken")
            if not token:
                raise ValueError("Sign in with Claude Code to view account usage.")
            data = get_json("https://api.anthropic.com/api/oauth/usage", {"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20", "User-Agent": "Crow/1.0"})
            for key, label in (("five_hour", "5 hours"), ("seven_day", "Weekly")):
                window = data.get(key)
                if window and window.get("utilization") is not None:
                    result["windows"].append({"label": label, "used": window["utilization"], "resets": reset_time(window.get("resets_at"))})
        else:
            credentials = homes()["grok"] / "auth.json"
            data = json.loads(credentials.read_text())
            auth = next((value for key, value in data.items() if key.startswith("https://auth.x.ai::") and isinstance(value, dict) and value.get("key")), None)
            if not auth:
                raise ValueError("Sign in with Grok Build to view account usage.")
            response = get_json("https://cli-chat-proxy.grok.com/v1/billing?format=credits", {"Authorization": "Bearer " + auth["key"], "X-XAI-Token-Auth": "xai-grok-cli", "x-userid": auth.get("user_id", ""), "User-Agent": "Crow/1.0"})
            config = response.get("config") or {}
            used = config.get("creditUsagePercent")
            if used is None:
                limit = (config.get("monthlyLimit") or {}).get("val", 0)
                if float(limit) > 0:
                    used = 100 * float((config.get("used") or {}).get("val", 0)) / float(limit)
            if used is not None:
                period = config.get("currentPeriod") or {}
                label = "Weekly" if "WEEKLY" in period.get("type", "") else "Current period"
                result["windows"].append({"label": label, "used": used, "resets": reset_time(period.get("end") or config.get("billingPeriodEnd"))})
        if not result["windows"]:
            result["error"] = "This account did not report usage limits."
    except urllib.error.HTTPError as error:
        result["error"] = "Usage temporarily rate-limited. Try again later." if error.code == 429 else "Usage request failed (HTTP %s). Check the CLI's login." % error.code
    except FileNotFoundError:
        result["error"] = "CLI or saved login not found on this host."
    except Exception as error:
        # Network exceptions and CLI diagnostics can contain account details. Never return credentials.
        result["error"] = str(error)[:250] if isinstance(error, ValueError) else "Could not read account usage. Check the CLI login and connection."
    return result


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError("Cancelled")))
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
