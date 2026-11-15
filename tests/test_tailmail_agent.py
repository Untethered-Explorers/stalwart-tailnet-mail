#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT_DIR / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
SPEC = importlib.util.spec_from_file_location(
    "tailmail_agent", SCRIPTS_DIR / "tailmail_agent.py"
)
assert SPEC and SPEC.loader
tailmail_agent = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tailmail_agent
SPEC.loader.exec_module(tailmail_agent)


class TailmailAgentTests(unittest.TestCase):
    def test_poll_persists_uid_cursor_and_filters_senders(self):
        messages = [
            {"uid": 12, "from": "Alice <alice@example.test>", "subject": "Task"},
            {"uid": 19, "from": "Mallory <mallory@example.test>", "subject": "No"},
        ]
        profile = {"allowed_senders": ["alice@example.test"]}

        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "state"
            with (
                patch.object(
                    tailmail_agent, "profile_state_dir", return_value=state_dir
                ),
                patch.object(
                    tailmail_agent, "fetch_mail_after", side_effect=[messages, []]
                ) as fetch,
            ):
                self.assertEqual(tailmail_agent.poll_mailbox("work", profile), 2)
                self.assertEqual(tailmail_agent.poll_mailbox("work", profile), 0)
                queue = tailmail_agent._queue_record("work", 12)
                rejected = tailmail_agent._queue_record("work", 19)
                cursor = tailmail_agent._cursor("work")

        self.assertEqual(fetch.call_args_list[0].args, (profile, 0))
        self.assertEqual(fetch.call_args_list[1].args, (profile, 19))
        self.assertEqual(queue["status"], "pending")
        self.assertEqual(rejected["status"], "rejected")
        self.assertEqual(cursor, 19)

    def test_guidance_update_is_idempotent_and_preserves_project_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            project.mkdir()
            project.chmod(0o755)
            path = project / "AGENTS.md"
            path.write_text("# Existing guidance\n\nKeep this text.\n", encoding="utf-8")

            tailmail_agent.install_agents_guidance(project, "work")
            first = path.read_text(encoding="utf-8")
            tailmail_agent.install_agents_guidance(project, "work")
            second = path.read_text(encoding="utf-8")

            self.assertEqual(first, second)
            self.assertTrue(first.startswith("# Existing guidance\n\nKeep this text.\n"))
            self.assertEqual(first.count(tailmail_agent.BEGIN_MARKER), 1)
            self.assertEqual(project.stat().st_mode & 0o777, 0o755)

    def test_permission_email_limits_approval_to_read_actions(self):
        profile = {
            "allowed_senders": ["alice@example.test"],
            "project_dir": "/tmp/project",
            "opencode_url": "http://127.0.0.1:12345",
        }
        sessions = [{"id": "session-1"}]
        requests = {
            "data": [
                {"id": "read-1", "permission": "read", "patterns": ["src/main.py"]},
                {"id": "secret-1", "permission": "read", "patterns": [".env"]},
                {
                    "id": "outside-1",
                    "permission": "read",
                    "patterns": ["/tmp/project/../outside.txt"],
                },
                {"id": "shell-1", "permission": "bash", "patterns": ["rm -rf /"]},
            ]
        }

        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "state"
            sent = []
            with (
                patch.object(
                    tailmail_agent, "profile_state_dir", return_value=state_dir
                ),
                patch.object(tailmail_agent, "_opencode_sessions", return_value=sessions),
                patch.object(tailmail_agent, "_api_request", return_value=requests),
                patch.object(
                    tailmail_agent, "_send_email", side_effect=lambda *args: sent.append(args)
                ),
            ):
                tailmail_agent._scan_opencode_permissions("work", profile)
                approvals = tailmail_agent._pending_approvals("work")

        read_approval = next(
            approval
            for approval in approvals.values()
            if approval["request_id"] == "read-1"
        )
        shell_approval = next(
            approval
            for approval in approvals.values()
            if approval["request_id"] == "shell-1"
        )
        secret_approval = next(
            approval
            for approval in approvals.values()
            if approval["request_id"] == "secret-1"
        )
        outside_approval = next(
            approval
            for approval in approvals.values()
            if approval["request_id"] == "outside-1"
        )
        self.assertEqual(read_approval["state"], "pending")
        self.assertTrue(read_approval["token"])
        self.assertEqual(shell_approval["state"], "local-required")
        self.assertEqual(shell_approval["token"], "")
        self.assertEqual(secret_approval["state"], "local-required")
        self.assertEqual(secret_approval["token"], "")
        self.assertEqual(outside_approval["state"], "local-required")
        self.assertEqual(outside_approval["token"], "")
        self.assertEqual(len(sent), 4)
        self.assertTrue(all("cannot approve" in message[3] for message in sent[1:]))

    def test_active_opencode_session_accepts_list_response(self):
        profile = {"project_dir": "/tmp/project"}
        with (
            patch.object(
                tailmail_agent,
                "_api_request",
                return_value={"data": [{"id": "session-1"}]},
            ),
            patch.object(
                tailmail_agent,
                "_project_sessions",
                return_value=[{"id": "session-1"}],
            ),
        ):
            active = tailmail_agent._active_opencode_session(profile)

        self.assertEqual(active, "session-1")

    def test_opencode_retry_reuses_a_session_created_before_delivery(self):
        profile = {"project_dir": "/tmp/project"}
        record = {
            "uid": 12,
            "status": "pending",
            "message": {"subject": "Task", "body": "Please inspect."},
        }
        with tempfile.TemporaryDirectory() as temporary:
            sends = []
            with (
                patch.object(
                    tailmail_agent,
                    "profile_state_dir",
                    return_value=Path(temporary) / "state",
                ),
                patch.object(
                    tailmail_agent, "_active_opencode_session", return_value=None
                ),
                patch.object(
                    tailmail_agent, "_new_opencode_session", return_value="session-1"
                ) as new_session,
                patch.object(
                    tailmail_agent,
                    "_send_opencode_message",
                    side_effect=[
                        tailmail_agent.AgentError("temporary API failure"),
                        None,
                    ],
                ) as send_message,
            ):
                with self.assertRaises(tailmail_agent.AgentError):
                    tailmail_agent._dispatch_opencode("work", profile, record)
                tailmail_agent._dispatch_opencode("work", profile, record)
                saved = tailmail_agent._queue_record("work", 12)

        self.assertEqual(new_session.call_count, 1)
        self.assertEqual(send_message.call_count, 2)
        self.assertEqual(saved["status"], "dispatched")
        self.assertEqual(saved["session_id"], "session-1")

    def test_unknown_approval_token_is_consumed_not_routed_as_a_task(self):
        profile = {"allowed_senders": ["alice@example.test"]}
        message = {
            "from": "alice@example.test",
            "body": "APPROVE 0123456789abcdef0123456789abcdef",
        }
        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    tailmail_agent,
                    "profile_state_dir",
                    return_value=Path(temporary) / "state",
                ),
                patch.object(tailmail_agent, "_api_request") as api_request,
            ):
                handled = tailmail_agent._handle_approval_reply(
                    "work", profile, message
                )

        self.assertTrue(handled)
        api_request.assert_not_called()

    def test_opencode_server_is_stopped_when_startup_times_out(self):
        class FakeProcess:
            returncode = None
            terminated = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                return 0

        process = FakeProcess()
        profile = {
            "opencode_url": "http://127.0.0.1:12345",
            "harness": "opencode",
            "harness_executable": "/usr/bin/opencode",
            "project_dir": "/tmp/project",
            "opencode_port": 12345,
        }

        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(tailmail_agent, "_api_request", side_effect=tailmail_agent.AgentError("not ready")),
                patch.object(tailmail_agent, "_harness_command", return_value=["opencode"]),
                patch.object(tailmail_agent.subprocess, "Popen", return_value=process),
                patch.object(tailmail_agent.time, "sleep"),
                self.assertRaisesRegex(tailmail_agent.AgentError, "did not become ready"),
            ):
                tailmail_agent._ensure_opencode_server(profile, Path(temporary))

        self.assertTrue(process.terminated)

    def test_install_copies_skill_and_appends_managed_guidance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project"
            project.mkdir()
            project.chmod(0o755)
            (project / "AGENTS.md").write_text("# Existing\n", encoding="utf-8")
            config_root = root / "config"
            state_root = root / "state"
            app_root = root / "app"
            mail_config = root / "tailmail-config"
            mail_config.write_text("credentials are not read by this test")
            launcher = root / "bin" / "tailmail-agent"
            output = io.StringIO()

            with (
                patch.object(tailmail_agent, "config_root", return_value=config_root),
                patch.object(tailmail_agent, "state_root", return_value=state_root),
                patch.object(tailmail_agent, "app_root", return_value=app_root),
                patch.object(
                    tailmail_agent.tailmail, "CONFIG_PATH", mail_config
                ),
                patch.object(
                    tailmail_agent.tailmail,
                    "load_settings",
                    return_value={"username": "agent@example.test"},
                ),
                patch.object(tailmail_agent.shutil, "which", return_value="/usr/bin/copilot"),
                patch.object(tailmail_agent, "latest_mail_uid", return_value=4),
                patch.object(tailmail_agent, "_write_launcher", return_value=launcher),
                patch.object(tailmail_agent, "_install_service"),
                redirect_stdout(output),
            ):
                tailmail_agent.install_profile(
                    "work",
                    project,
                    "copilot",
                    ["alice@example.test"],
                    ROOT_DIR,
                )
                first_guidance = (project / "AGENTS.md").read_text(encoding="utf-8")
                tailmail_agent.install_profile(
                    "work",
                    project,
                    "copilot",
                    ["alice@example.test"],
                    ROOT_DIR,
                )
                second_guidance = (project / "AGENTS.md").read_text(encoding="utf-8")
                initial_cursor = tailmail_agent._cursor("work")

            installed_skill = (
                project / ".agents" / "skills" / "tailmail-mail" / "SKILL.md"
            )
            profile_path = config_root / "tailmail" / "watchers" / "work.json"
            profile = json.loads(profile_path.read_text(encoding="utf-8"))

            self.assertTrue(installed_skill.is_file())
            self.assertEqual(first_guidance, second_guidance)
            self.assertIn("# Existing\n", second_guidance)
            self.assertIn(str(launcher), second_guidance)
            self.assertIn("email the user", second_guidance)
            self.assertEqual(profile["harness_executable"], "/usr/bin/copilot")
            self.assertEqual(initial_cursor, 4)
            self.assertEqual(project.stat().st_mode & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
