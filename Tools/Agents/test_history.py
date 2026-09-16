import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("history", pathlib.Path(__file__).resolve().parents[2] / "App/Agents/agent-history.py")
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.workspace = str(self.root / "project ' space")
        self.homes = {provider: self.root / provider for provider in ("codex", "claude", "grok")}
        self.session_id = "11111111-1111-4111-8111-111111111111"

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, records):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        return path

    def test_codex_filters_setup_tools_and_other_workspaces(self):
        home = self.homes["codex"]
        path = home / "sessions/2026/09/14/rollout.jsonl"
        records = [{"type": "session_meta", "payload": {"id": self.session_id, "cwd": self.workspace}}]
        for role, text in [("user", "# AGENTS.md instructions for project"), ("developer", "Secret setup"), ("user", "First prompt"), ("assistant", "First answer"), ("user", "Follow-up"), ("assistant", "Last answer")]:
            records.append({"type": "response_item", "payload": {"type": "message", "role": role, "content": [{"type": "input_text", "text": text}]}})
        self.write(path, records)
        item = history.conversation("codex", path, self.workspace, home)
        self.assertEqual(item["first"]["text"], "First prompt")
        self.assertEqual([m["text"] for m in item["recent"]], ["First answer", "Follow-up", "Last answer"])
        self.assertIsNone(history.conversation("codex", path, self.workspace + "-other", home))

    def test_claude_deduplicates_messages_and_deletes_only_selected_session(self):
        home = self.homes["claude"]
        path = home / "projects/project" / (self.session_id + ".jsonl")
        prompt = {"type": "user", "sessionId": self.session_id, "cwd": self.workspace, "uuid": "one", "message": {"content": "First prompt"}}
        reply = {"type": "assistant", "uuid": "two", "message": {"content": [{"type": "text", "text": "Reply"}, {"type": "tool_use", "input": "Do not show"}]}}
        self.write(path, [prompt, reply, reply])
        item = history.conversation("claude", path, self.workspace, home)
        self.assertEqual(len(item["recent"]), 2)
        other = self.write(path.with_name("other.jsonl"), [prompt])
        with patch.object(history, "homes", return_value=self.homes):
            changed = dict(item, size=0)
            with self.assertRaisesRegex(ValueError, "changed"):
                history.delete_session(self.workspace, changed)
            self.assertTrue(path.exists())
            history.delete_session(self.workspace, item)
        self.assertFalse(path.exists())
        self.assertTrue(other.exists())

    def test_grok_uses_summary_cwd_and_skips_synthetic_context(self):
        home = self.homes["grok"]
        path = home / "sessions/project" / self.session_id / "chat_history.jsonl"
        self.write(path, [{"type": "user", "synthetic_reason": "system_reminder", "content": "Injected instructions"}, {"type": "user", "content": [{"type": "text", "text": "Actual prompt"}]}, {"type": "assistant", "content": "Answer"}])
        (path.parent / "summary.json").write_text(json.dumps({"info": {"id": self.session_id, "cwd": self.workspace}, "session_summary": "Session name"}))
        item = history.conversation("grok", path, self.workspace, home)
        self.assertEqual(item["title"], "Session name")
        self.assertEqual(item["first"]["text"], "Actual prompt")
        self.assertEqual(item["recent"][-1]["text"], "Answer")

    def test_symlinks_cannot_delete_external_files(self):
        home = self.homes["claude"]
        home.mkdir()
        outside = self.write(self.root / "external.jsonl", [{"type": "user"}])
        link = home / "link.jsonl"
        link.symlink_to(outside)
        self.assertFalse(history.safe_file(link, home))
        with patch.object(history, "homes", return_value=self.homes):
            with self.assertRaisesRegex(ValueError, "outside"):
                history.delete_session(self.workspace, {"provider": "claude", "path": str(link)})
        self.assertTrue(outside.exists())

    def test_usage_does_not_turn_missing_limits_into_zero(self):
        with patch.object(history, "codex_rpc", return_value={"rateLimits": {}}):
            value = history.provider_usage("codex")
        self.assertEqual(value["windows"], [])
        self.assertIsNotNone(value["error"])
        with patch.object(history, "codex_rpc", return_value={"rateLimits": {"primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 123}}}):
            value = history.provider_usage("codex")
        self.assertEqual(value["windows"], [{"label": "5 hours", "used": 42, "resets": 123}])

    def test_missing_codex_executable_is_not_reported_as_a_login_failure(self):
        with patch.object(history.subprocess, "Popen", side_effect=FileNotFoundError):
            value = history.provider_usage("codex")
        self.assertEqual(value["windows"], [])
        self.assertEqual(value["error"], "Codex CLI was not found in this host's PATH.")

    def test_codex_rpc_initializes_and_uses_native_deletion(self):
        executable = self.root / "codex"
        executable.write_text("#!" + os.sys.executable + "\nimport sys,json\nfor line in sys.stdin:\n request=json.loads(line)\n if 'id' not in request: continue\n result={} if request['method']=='initialize' else {'method':request['method'],'thread':request['params'].get('threadId')}\n print(json.dumps({'id':request['id'],'result':result}),flush=True)\n")
        executable.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(self.root) + os.pathsep + os.environ["PATH"]}):
            result = history.codex_rpc("thread/delete", {"threadId": self.session_id})
        self.assertEqual(result, {"method": "thread/delete", "thread": self.session_id})


class SkillTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name).resolve()
        self.project = self.root / "project with spaces"
        (self.project / ".git").mkdir(parents=True)
        self.child = self.project / "nested"
        self.child.mkdir()
        self.homes = {provider: self.root / provider for provider in ("codex", "claude", "grok")}
        self.home_patch = patch.object(history, "homes", return_value=self.homes)
        self.home_patch.start()

    def tearDown(self):
        self.home_patch.stop()
        self.temp.cleanup()

    def skill(self, root, name, metadata=None):
        path = root / name / "SKILL.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(metadata or f"---\nname: {name}\ndescription: Example skill\n---\nNever execute this body.")
        return path

    def settings(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def test_claude_current_directory_parents_and_git_boundary(self):
        self.skill(self.project / ".claude/skills", "root")
        self.skill(self.child / ".claude/skills", "nested")
        self.skill(self.project / "sibling/.claude/skills", "sibling")
        self.skill(self.root / ".claude/skills", "outside-repository")
        self.assertEqual({s["name"] for s in history.claude_skills(str(self.child), [])}, {"root", "nested"})
        self.assertEqual({s["name"] for s in history.claude_skills(str(self.project), [])}, {"root"})

    def test_claude_personal_precedence_and_local_overrides(self):
        personal = self.skill(self.homes["claude"] / "skills", "duplicate")
        self.skill(self.project / ".claude/skills", "duplicate")
        self.skill(self.project / ".claude/skills", "hidden")
        self.settings(self.homes["claude"] / "settings.json", {"skillOverrides": {"hidden": "on"}})
        self.settings(self.project / ".claude/settings.local.json", {"skillOverrides": {"hidden": "off"}})
        items = history.claude_skills(str(self.child), [])
        self.assertEqual([(s["name"], s["path"]) for s in items], [("duplicate", str(personal))])

    def test_claude_only_enabled_plugins_matching_project(self):
        plugin = self.root / "plugin"
        self.skill(plugin / "skills", "review")
        unrelated = self.root / "unrelated"
        self.skill(unrelated / "skills", "wrong-project")
        installed = {"active@market": [{"scope": "project", "projectPath": str(self.project), "installPath": str(plugin)}],
                     "disabled@market": [{"scope": "user", "installPath": str(plugin)}],
                     "other@market": [{"scope": "project", "projectPath": str(unrelated), "installPath": str(unrelated)}]}
        self.settings(self.homes["claude"] / "plugins/installed_plugins.json", {"version": 2, "plugins": installed})
        self.settings(self.project / ".claude/settings.json", {"enabledPlugins": {"active@market": True, "disabled@market": False, "other@market": True}})
        self.assertEqual([s["name"] for s in history.claude_skills(str(self.child), [])], ["active:review"])

    def test_metadata_quotes_block_scalars_and_symlinks(self):
        path = self.skill(self.project / ".claude/skills", "folder-name", "---\nname: 'it''s a skill'\ndescription: >-\n  First line\n  second line\n---\nBody")
        self.assertEqual(history.skill_metadata(path), {"name": "it's a skill", "description": "First line second line"})
        (path.parent.parent / "alias").symlink_to(path.parent, target_is_directory=True)
        with patch.object(history, "codex_rpc", return_value={"data": []}):
            result = history.list_skills(str(self.child))
        self.assertEqual(len(result["skills"]), 1)
        self.assertEqual(result["skills"][0]["path"], str(path))

    def test_codex_uses_cwd_and_omits_disabled_and_other_directory(self):
        skill = {"name": "native", "description": "Long", "path": "/skills/native/SKILL.md", "enabled": True,
                 "scope": "user", "interface": {"displayName": "Native Skill", "shortDescription": "Short"}}
        reply = {"data": [{"cwd": str(self.child), "skills": [skill, dict(skill, path="/disabled/SKILL.md", enabled=False)], "errors": []},
                          {"cwd": str(self.root), "skills": [dict(skill, path="/wrong/SKILL.md")]}]}
        with patch.object(history, "codex_rpc", return_value=reply) as rpc:
            result = history.list_skills(str(self.child))
        rpc.assert_called_once_with("skills/list", {"cwds": [str(self.child)], "forceReload": True})
        self.assertEqual(len(result["skills"]), 1)
        self.assertEqual(result["skills"][0]["description"], "Short")
        self.assertEqual(result["skills"][0]["scope"], "User")

    def test_codex_failure_keeps_claude_results_with_warning(self):
        self.skill(self.project / ".claude/skills", "works")
        with patch.object(history, "codex_rpc", side_effect=ValueError("Timed out")):
            result = history.list_skills(str(self.child))
        self.assertEqual([s["name"] for s in result["skills"]], ["works"])
        self.assertIn("Timed out", result["warnings"][0])

    def test_malformed_settings_warn_without_losing_skills(self):
        self.skill(self.project / ".claude/skills", "works")
        path = self.project / ".claude/settings.json"
        path.write_text("invalid json")
        warnings = []
        self.assertEqual(len(history.claude_skills(str(self.child), warnings)), 1)
        self.assertTrue(warnings)


if __name__ == "__main__":
    unittest.main()
