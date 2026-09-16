"""Read CLI-owned conversation records. No credentials or tool output are returned."""
import hashlib
import shlex
import tempfile
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
    started = None
    if provider == "grok":
        metadata = json.loads((path.parent / "summary.json").read_text())
        session_id = metadata.get("info", {}).get("id", path.parent.name)
        cwd = metadata.get("info", {}).get("cwd")
        title = metadata.get("session_summary") or ""
    seen = set()
    for item in records(path):
        kind = item.get("type")
        if started is None and isinstance(item.get("timestamp"), str):
            try:
                started = datetime.datetime.fromisoformat(item["timestamp"].replace("Z", "+00:00")).timestamp()
            except ValueError:
                pass
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
            "modified": stat.st_mtime, "size": stat.st_size, "first": first, "recent": list(recent), "tokens": tokens,
            "started": started if started is not None else getattr(stat, "st_birthtime", None)}


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


def list_sessions(workspace, known_signature=None):
    result, warnings = [], []
    sources = []
    fingerprint = hashlib.sha256(canonical(workspace).encode())
    for provider, home in homes().items():
        paths = []
        for path in candidates(provider, home, workspace):
            try:
                if safe_file(path, home):
                    stat = path.stat()
                    paths.append((path, stat))
            except OSError:
                continue
        paths.sort(key=lambda item: item[1].st_mtime, reverse=True)
        count = len(paths)
        paths = paths[:2000]
        for path, stat in paths:
            fingerprint.update(f"{provider}:{path}:{stat.st_mtime_ns}:{stat.st_size}".encode())
            if provider == "grok":
                try:
                    summary = (path.parent / "summary.json").stat()
                    fingerprint.update(f"{summary.st_mtime_ns}:{summary.st_size}".encode())
                except OSError:
                    pass
        try:
            index_stat = (home / "session_index.jsonl").stat()
            fingerprint.update(f"{provider}:{index_stat.st_mtime_ns}:{index_stat.st_size}".encode())
        except OSError:
            pass
        sources.append((provider, home, [path for path, _ in paths], count))
    signature = fingerprint.hexdigest()
    if signature == known_signature:
        return {"sessions": [], "warnings": [], "signature": signature, "unchanged": True, "server_time": time.time()}
    deadline = time.monotonic() + 7
    complete = True
    for provider, home, paths, count in sources:
        names = {}
        index = home / "session_index.jsonl"
        if provider == "codex" and index.is_file():
            try:
                names = {row.get("id"): row["thread_name"] for row in records(index) if row.get("thread_name")}
            except OSError:
                pass
        for path in paths:
            if time.monotonic() > deadline:
                complete = False
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
        if count > 2000:
            warnings.append(provider.title() + ": checked the 2,000 most recently changed records.")
    result.sort(key=lambda item: item["modified"], reverse=True)
    return {"sessions": result[:100], "warnings": sorted(set(warnings)), "signature": signature if complete else None, "server_time": time.time()}


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


def delete_session(workspace, expected, closed_tab=False):
    provider, path = expected["provider"], pathlib.Path(expected["path"])
    home = homes().get(provider)
    if home is None or not safe_file(path, home):
        raise ValueError("Session file is outside this CLI's history directory.")
    current = conversation(provider, path, workspace, home)
    if not current or current["id"] != expected["id"]:
        raise ValueError("This session no longer belongs to the selected workspace.")
    if not closed_tab and (current["modified"] != expected["modified"] or current["size"] != expected["size"]):
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


def skill_metadata(path):
    """Read display metadata only. Never evaluate YAML tags or skill commands."""
    with open(path, encoding="utf-8-sig", errors="replace") as stream:
        lines = stream.read(65536).splitlines()
    values = {}
    if not lines or lines[0].strip() != "---":
        return values
    for index, line in enumerate(lines[1:], 1):
        if line.strip() in ("---", "..."):
            break
        match = re.match(r"^(name|description):\s*(.*)$", line)
        if not match:
            continue
        key, value = match.groups()
        if value.startswith(("|", ">")) or not value:
            parts = []
            for continuation in lines[index + 1:]:
                if continuation and not continuation[0].isspace():
                    break
                parts.append(continuation.strip())
            value = " ".join(parts)
        elif value.startswith('"') and value.endswith('"'):
            try:
                value = json.loads(value)
            except ValueError:
                value = value[1:-1]
        elif value.startswith("'") and value.endswith("'"):
            value = value[1:-1].replace("''", "'")
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0]
        values[key] = value[:2000]
    return values


def skill_project_directories(workspace):
    """Nearest directory first, stopping at the Git/worktree boundary."""
    directory = pathlib.Path(canonical(workspace))
    directories = []
    for _ in range(64):
        directories.append(directory)
        if (directory / ".git").exists() or directory == directory.parent:
            break
        directory = directory.parent
    return directories


def skill_json(path, warnings):
    try:
        with open(path, encoding="utf-8") as stream:
            value = json.loads(stream.read(2 * 1024 * 1024))
        return value if isinstance(value, dict) else {}
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        warnings.append("Could not read skill settings: " + str(path))
        return {}


def skill_files(root, provider, scope, warnings, prefix=""):
    result = []
    try:
        # One level only: do not crawl the workspace or plugin cache.
        with os.scandir(root) as entries:
            for index, entry in enumerate(entries):
                if index >= 1000:
                    warnings.append("Skill folder limit reached: " + str(root))
                    break
                if entry.name.startswith(".") or entry.name == "synced":
                    continue
                path = pathlib.Path(entry.path) / "SKILL.md"
                if not path.is_file():
                    continue
                try:
                    metadata = skill_metadata(path)
                    result.append({"provider": provider, "name": prefix + (metadata.get("name") or entry.name),
                                   "description": metadata.get("description", ""), "path": canonical(path), "scope": scope})
                except OSError:
                    warnings.append("Could not read skill: " + str(path))
    except FileNotFoundError:
        pass
    except OSError:
        warnings.append("Could not read skill folder: " + str(root))
    return sorted(result, key=lambda item: item["name"].casefold())


def claude_skills(workspace, warnings):
    home = homes()["claude"]
    directories = skill_project_directories(workspace)
    enabled, overrides = {}, {}
    settings_paths = [home / "settings.json"]
    for directory in reversed(directories):
        settings_paths.extend([directory / ".claude/settings.json", directory / ".claude/settings.local.json"])
    managed = pathlib.Path("/Library/Application Support/ClaudeCode" if sys.platform == "darwin" else "/etc/claude-code")
    settings_paths.append(managed / "managed-settings.json")
    for path in settings_paths:
        settings = skill_json(path, warnings)
        for key, target in (("enabledPlugins", enabled), ("skillOverrides", overrides)):
            if isinstance(settings.get(key), dict):
                target.update(settings[key])
    # Personal skills take precedence over project skills; nested project skills
    # may share a name. Preserve both paths rather than silently dropping one.
    result = skill_files(managed / "skills", "claude", "Managed", warnings)
    managed_names = {item["name"] for item in result}
    result += [item for item in skill_files(home / "skills", "claude", "User", warnings) if item["name"] not in managed_names]
    global_names = {item["name"] for item in result}
    for directory in directories:
        result += [item for item in skill_files(directory / ".claude/skills", "claude", "Project", warnings)
                   if item["name"] not in global_names]
    result = [item for item in result if overrides.get(item["name"]) != "off"]
    installed = skill_json(home / "plugins/installed_plugins.json", warnings).get("plugins", {})
    if isinstance(installed, dict):
        for plugin, installations in list(installed.items())[:500]:
            if enabled.get(plugin) is not True or not isinstance(installations, list):
                continue
            eligible = [item for item in installations if isinstance(item, dict)
                        and (item.get("scope") in ("user", "managed")
                             or (item.get("scope") in ("project", "local") and item.get("projectPath")
                                 and canonical(item["projectPath"]) in {str(d) for d in directories}))]
            eligible.sort(key=lambda item: {"local": 0, "project": 1, "user": 2, "managed": 3}.get(item.get("scope"), 4))
            if eligible and isinstance(eligible[0].get("installPath"), str):
                result += skill_files(pathlib.Path(eligible[0]["installPath"]) / "skills", "claude", "Plugin", warnings,
                                      prefix=plugin.split("@")[0] + ":")
    return result


def selected_providers(value, default=("claude", "codex", "grok")):
    if value is None:
        return list(default)
    if not isinstance(value, list) or any(item not in ("claude", "codex", "grok") for item in value):
        raise ValueError("Invalid agent providers.")
    return list(dict.fromkeys(value))


def grok_skills(workspace, warnings):
    # The CLI's report includes trust, plugin, compatibility and disabled-skill
    # decisions. Do not guess availability by scanning vendor directories.
    # https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/08-skills.md
    executable = shutil.which("grok")
    if not executable:
        warnings.append("Grok CLI is not installed on this host.")
        return []
    try:
        response = subprocess.run([executable, "inspect", "--json"], cwd=workspace,
                                  stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=8)
        if response.returncode:
            raise ValueError("Could not inspect skills. Check the Grok configuration or update its CLI.")
        report = json.loads(response.stdout)
        if canonical(report.get("cwd", "")) != canonical(workspace):
            raise ValueError("Grok returned skills for a different folder.")
        result = []
        for item in report.get("skills", [])[:1000]:
            source = item.get("source") or {}
            path = source.get("path")
            if item.get("disabled") or item.get("compatibilityStatus") == "disabled" or not isinstance(path, str):
                continue
            result.append({"provider": "grok", "name": item.get("invocableAs") or item.get("name") or pathlib.Path(path).parent.name,
                           "description": item.get("description") or "", "path": canonical(os.path.join(workspace, path)),
                           "scope": {"configToml": "Config", "plugin": "Plugin", "project": "Project", "user": "User",
                                     "bundled": "Bundled", "server": "Server", "managed": "Managed"}.get(source.get("type"), "Project")})
        return result
    except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
        warnings.append("Grok skill discovery unavailable: " + str(error))
        return []


def list_skills(workspace, providers=None):
    providers = selected_providers(providers, ("claude", "codex"))
    warnings = []
    result = claude_skills(workspace, warnings) if "claude" in providers else []
    if "codex" in providers:
        try:
            response = codex_rpc("skills/list", {"cwds": [workspace], "forceReload": True})
            for group in response.get("data", []):
                if canonical(group.get("cwd", "")) != canonical(workspace):
                    continue
                for item in group.get("skills", [])[:1000]:
                    if item.get("enabled") is False or not isinstance(item.get("path"), str):
                        continue
                    interface = item.get("interface") or {}
                    result.append({"provider": "codex", "name": interface.get("displayName") or item.get("name") or pathlib.Path(item["path"]).parent.name,
                                   "description": interface.get("shortDescription") or item.get("description") or "",
                                   "path": item["path"], "scope": "Plugin" if item.get("pluginId") else
                                   {"repo": "Project", "user": "User", "system": "System", "admin": "Managed"}.get(item.get("scope"), "Project")})
                for error in group.get("errors", []):
                    warnings.append("Codex: " + str(error.get("message", "Could not load a skill.")))
        except (OSError, ValueError, TypeError, AttributeError) as error:
            warnings.append("Codex skill discovery unavailable: " + str(error))
    if "grok" in providers:
        result += grok_skills(workspace, warnings)
    seen = set()
    unique = []
    for item in sorted(result, key=lambda item: (item["provider"], item["name"].casefold(), item["path"])):
        key = (item["provider"], canonical(item["path"]))
        if key not in seen:
            seen.add(key)
            unique.append(item)
    if len(unique) > 500:
        warnings.append("Showing the first 500 skills.")
    return {"skills": unique[:500], "warnings": sorted(set(warnings))}



def reverse_tool(root, name, args):
    root = canonical(root)
    def path(value="."):
        result = canonical(os.path.join(root, value))
        if os.path.commonpath([root, result]) != root:
            raise ValueError("Path is outside the selected client workspace.")
        return result
    if name == "workspace_info":
        return {"root": root, "host": os.uname().nodename, "platform": sys.platform}
    if name == "list_directory":
        with os.scandir(path(args.get("path", "."))) as entries:
            return [{"name": item.name, "directory": item.is_dir()} for _, item in zip(range(1000), entries)]
    if name == "read_file":
        with open(path(args["path"]), encoding="utf-8") as stream:
            text = stream.read(200001)
        return {"text": text[:200000], "truncated": len(text) > 200000}
    if name in ("write_file", "edit_file"):
        target = path(args["path"])
        if name == "write_file":
            text = args["text"]
            if os.path.exists(target):
                raise ValueError("File exists. Use edit_file with exact old_text to change it.")
            mode = "x"
        else:
            with open(target, encoding="utf-8", newline="") as stream:
                original = stream.read(2000001)
            if len(original) > 2000000:
                raise ValueError("File exceeds the edit limit; use the client shell.")
            old = args["old_text"]
            if not old or original.count(old) != 1:
                raise ValueError("old_text must match exactly once; read the file again.")
            text = original.replace(old, args["new_text"], 1)
            mode = "w"
        if not isinstance(text, str) or len(text) > 2000000:
            raise ValueError("Text exceeds the write limit.")
        with open(target, mode, encoding="utf-8", newline="") as stream:
            stream.write(text)
        return {"path": target, "written": True}
    if name == "shell":
        directory = path(args.get("cwd", "."))
        timeout = min(120, max(1, float(args.get("timeout", 60))))
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(["/bin/zsh", "-lc", "cd -- " + shlex.quote(directory) + " && " + args["command"]], cwd=directory,
                                       stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True)
            try:
                deadline = time.monotonic() + timeout
                while process.poll() is None:
                    if time.monotonic() > deadline or os.fstat(output.fileno()).st_size > 4 * 1024 * 1024:
                        raise ValueError("Client command exceeded its time or output limit.")
                    time.sleep(0.05)
                output.seek(0)
                data = output.read(200001)
                return {"exit_code": process.returncode, "output": data[:200000].decode("utf-8", errors="replace"),
                        "truncated": len(data) > 200000, "cwd": directory}
            finally:
                # Also reap child processes left behind by the shell.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
    raise ValueError("Unknown client tool.")


def reverse_tool_definitions(root):
    def tool(name, description, properties, required=()):
        return {"name": name, "description": description + " Runs on the Crow CLIENT. Workspace: " + root,
                "inputSchema": {"type": "object", "properties": properties, "required": list(required), "additionalProperties": False}}
    string = {"type": "string"}
    return [tool("workspace_info", "Identify the client and fixed working root.", {}),
            tool("list_directory", "List up to 1,000 entries.", {"path": string}),
            tool("read_file", "Read a UTF-8 file (up to 200,000 characters).", {"path": string}, ["path"]),
            tool("write_file", "Create a new UTF-8 file. Existing files are never overwritten.", {"path": string, "text": string}, ["path", "text"]),
            tool("edit_file", "Replace one exact occurrence of old_text in a UTF-8 file.", {"path": string, "old_text": string, "new_text": string}, ["path", "old_text", "new_text"]),
            tool("shell", "Run a shell command on the client. Default cwd is the workspace. Commands stop on timeout; use no detached jobs.",
                 {"command": string, "cwd": string, "timeout": {"type": "number", "minimum": 1, "maximum": 120}}, ["command"])]


def reverse_serve(root):
    if not os.path.isdir(root):
        raise ValueError("Client workspace no longer exists.")
    for line in sys.stdin:
        request = json.loads(line)
        identifier = request.get("id")
        if identifier is None:
            continue
        method = request.get("method")
        response = {"jsonrpc": "2.0", "id": identifier}
        try:
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "crow-client", "version": "1.0"}}
            elif method == "tools/list":
                result = {"tools": reverse_tool_definitions(root)}
            elif method == "ping":
                result = {}
            elif method == "tools/call":
                params = request["params"]
                try:
                    value = reverse_tool(root, params["name"], params.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
                except Exception as error:
                    result = {"isError": True, "content": [{"type": "text", "text": str(error)}]}
            else:
                response["error"] = {"code": -32601, "message": "Method not found"}
                result = None
            if "error" not in response:
                response["result"] = result
        except Exception as error:
            response["error"] = {"code": -32602, "message": str(error)}
        print(json.dumps(response, ensure_ascii=False), flush=True)
    return None


def reverse_guard():
    request = json.load(sys.stdin)
    name = request.get("tool_name", "")
    # Claude and Codex both expose MCP tool names with this prefix. Grok's
    # plugin namespace includes the same dedicated server name.
    allowed = re.search(r"(?:^|__)crow_client__", name) is not None
    allowed = allowed or name in ("update_plan", "request_user_input", "AskUserQuestion", "TodoWrite")
    decision = "allow" if allowed else "deny"
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision,
            "permissionDecisionReason": "Use crow_client tools: this session works on the client, not on the agent server."}}


def reverse_prepare(request):
    provider = request["provider"]
    if provider not in ("claude", "codex", "grok"):
        raise ValueError("Unsupported agent provider.")
    executable = shutil.which(provider)
    if not executable:
        raise ValueError(provider.title() + " CLI is not installed on the selected server.")
    help_text = subprocess.run([executable, "--help"], capture_output=True, text=True, timeout=15).stdout
    required = {"claude": ["--tools", "--mcp-config", "--strict-mcp-config", "--settings"],
                "codex": ["--dangerously-bypass-hook-trust"],
                "grok": ["--tools", "--plugin-dir", "--rules"]}[provider]
    if any(flag not in help_text for flag in required):
        raise ValueError("Update " + provider.title() + " on the server: this version does not support Crow's client tool routing.")
    identity = request["client_id"] + "\n" + request["client_root"]
    workspace = pathlib.Path.home() / ".crow/reverse-agents" / hashlib.sha256(identity.encode()).hexdigest()[:32]
    workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
    if workspace.is_symlink() or workspace.stat().st_mode & 0o077:
        raise ValueError("Reverse agent storage must be private.")
    launch = pathlib.Path(tempfile.mkdtemp(prefix="launch-", dir=workspace))
    def write(relative, text):
        target = launch / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(target, "x", encoding="utf-8") as stream:
            os.chmod(target, 0o600)
            stream.write(text)
        return str(target)
    try:
        runtime = write("runtime.py", request["runtime_source"])
        local_request = json.dumps({"action": "reverse-tools", "workspace": request["client_root"]})
        remote_command = "exec " + shlex.quote(request["client_python"]) + " " + shlex.quote(request["client_runtime"]) + " " + shlex.quote(local_request)
        connector = shlex.split(request["connector"])
        if len(connector) != 1 or not os.path.isabs(connector[0]) or not os.access(connector[0], os.X_OK):
            raise ValueError("Reverse SSH connector is unavailable. Enable Reverse SSH again.")
        server = {"command": connector[0], "args": ["-T", remote_command]}
        probe = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "workspace_info", "arguments": {}}}
        checked = subprocess.run([server["command"]] + server["args"], input=json.dumps(probe) + "\n", capture_output=True, text=True, timeout=15)
        messages = [json.loads(line) for line in checked.stdout.splitlines() if line.startswith("{")]
        if checked.returncode or not messages or messages[0].get("result", {}).get("isError"):
            raise ValueError("Could not verify the client workspace over Reverse SSH.")
        info = json.loads(messages[0]["result"]["content"][0]["text"])
        if canonical(info["root"]) != canonical(request["client_root"]):
            raise ValueError("Reverse SSH reached a different workspace.")
        instructions = ("This is a Crow reverse agent session. You run on a server using its saved login, but the ONLY work target is the client workspace "
                        + request["client_root"] + ". Use crow_client MCP tools for ALL filesystem reads, edits, searches, git, tests, and shell commands. "
                        "Server-side tools are disabled or denied. Never use server filesystem paths for project work. Begin by calling workspace_info. "
                        "Use shell for searches or commands that are not covered by the other client tools. Read AGENTS.md and CLAUDE.md on the client if present.")
        hook_command = shlex.quote(sys.executable) + " " + shlex.quote(runtime) + " " + shlex.quote(json.dumps({"action": "reverse-guard", "workspace": str(workspace)}))
        hooks = {"PreToolUse": [{"matcher": ".*", "hooks": [{"type": "command", "command": hook_command, "timeout": 5}]}]}
        if provider == "claude":
            config = write("mcp.json", json.dumps({"mcpServers": {"crow_client": server}}))
            settings = write("settings.json", json.dumps({"hooks": hooks, "disableAllHooks": False}))
            args = [executable, "--dangerously-skip-permissions", "--tools", "", "--strict-mcp-config", "--mcp-config", config,
                    "--settings", settings, "--append-system-prompt", instructions]
        elif provider == "codex":
            # Per-process overrides retain the server account's authentication and
            # history. No persistent user config or credential is copied/changed.
            def toml(value):
                if isinstance(value, dict):
                    return "{" + ",".join(json.dumps(k) + "=" + toml(v) for k, v in value.items()) + "}"
                if isinstance(value, list):
                    return "[" + ",".join(map(toml, value)) + "]"
                return json.dumps(value)
            args = [executable, "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
                    "-c", "mcp_servers.crow_client=" + toml(server), "-c", "hooks.PreToolUse=" + toml(hooks["PreToolUse"]),
                    "-c", "developer_instructions=" + toml(instructions), "-c", "projects." + json.dumps(str(workspace)) + ".trust_level=\"trusted\"", "--enable", "hooks", "--disable", "shell_tool", "--disable", "multi_agent"]
        else:
            write("plugin/.claude-plugin/plugin.json", json.dumps({"name": "crow-client", "version": "1.0.0"}))
            write("plugin/.mcp.json", json.dumps({"mcpServers": {"crow_client": server}}))
            write("plugin/hooks/hooks.json", json.dumps({"hooks": hooks}))
            args = [executable, "--always-approve", "--no-leader", "--tools", "", "--plugin-dir", str(launch / "plugin"), "--rules", instructions]
        if request.get("session_id"):
            if not valid_id(request["session_id"]):
                raise ValueError("Invalid saved session ID.")
            if provider == "codex":
                args += ["fork" if request.get("fork") else "resume", request["session_id"]]
            else:
                args += ["--resume", request["session_id"]] + (["--fork-session"] if request.get("fork") else [])
        write("launch.json", json.dumps({"cwd": str(workspace), "argv": args}))
        command = "exec " + shlex.quote(sys.executable) + " " + shlex.quote(runtime) + " " + shlex.quote(json.dumps({"action": "reverse-launch", "workspace": str(workspace), "launch": str(launch)}))
        return {"directory": str(workspace), "launch": str(launch), "command": command}
    except BaseException:
        shutil.rmtree(launch)
        raise


def reverse_launch(request):
    launch = pathlib.Path(request["launch"])
    config = json.loads((launch / "launch.json").read_text())
    os.chdir(config["cwd"])
    os.execv(config["argv"][0], config["argv"])

def main():
    request = json.loads(sys.argv[1])
    action = request.get("action", "list")
    workspace = canonical(request["workspace"])
    if action == "reverse-cleanup":
        target = pathlib.Path(request["launch"])
        base = canonical(pathlib.Path.home() / ".crow/reverse-agents")
        if target.is_symlink() or not canonical(target).startswith(base + os.sep) or not target.name.startswith("launch-"):
            raise ValueError("Invalid reverse-agent cleanup path.")
        shutil.rmtree(target, ignore_errors=True)
        return {"removed": True}
    if action == "reverse-tools":
        return reverse_serve(workspace)
    if action == "reverse-guard":
        return reverse_guard()
    if action == "reverse-prepare":
        return reverse_prepare(request)
    if action == "reverse-launch":
        return reverse_launch(request)
    if action == "skills":
        return list_skills(workspace, request.get("providers"))
    if action == "list":
        return list_sessions(workspace, request.get("known_signature"))
    if action == "delete":
        return delete_session(workspace, request["session"], request.get("closed_tab", False))
    if action == "codex-usage":
        return codex_rpc("account/rateLimits/read", {})
    if action == "usage":
        providers = selected_providers(request.get("providers"))
        if not providers:
            return {"providers": []}
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(providers)) as executor:
            return {"providers": list(executor.map(provider_usage, providers))}
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
        result["error"] = "Codex CLI was not found in this host's PATH." if provider == "codex" else "Saved CLI login not found on this host."
    except Exception as error:
        # Network exceptions and CLI diagnostics can contain account details. Never return credentials.
        result["error"] = str(error)[:250] if isinstance(error, ValueError) else "Could not read account usage. Check the CLI login and connection."
    return result


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError("Cancelled")))
    try:
        result = main()
        if result is not None:
            print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
