#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
import contextlib
import email
import io
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from email.message import EmailMessage
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "tailmail", ROOT_DIR / "scripts" / "tailmail.py"
)
assert SPEC and SPEC.loader
tailmail = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tailmail
SPEC.loader.exec_module(tailmail)


class TailmailTests(unittest.TestCase):
    def test_attachment_save_uses_safe_name_and_returns_uid(self):
        source = EmailMessage()
        source["From"] = "alice@example.test"
        source["To"] = "agent@example.test"
        source["Subject"] = "Please inspect"
        source["Message-ID"] = "<request@example.test>"
        source.set_content("Review this file.")
        source.add_attachment(
            b"sample contents",
            maintype="text",
            subtype="plain",
            filename="../../unsafe name.txt",
        )
        parsed = email.message_from_bytes(source.as_bytes())

        with tempfile.TemporaryDirectory() as temporary:
            data = tailmail.message_data(
                parsed, Path(temporary), max_attachment_bytes=100, uid=27
            )
            saved = Path(data["attachments"][0]["saved_to"])
            self.assertEqual(data["uid"], 27)
            self.assertEqual(data["body"], "Review this file.\n")
            self.assertEqual(saved.parent, Path(temporary))
            self.assertEqual(saved.read_bytes(), b"sample contents")
            self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("..", saved.name)

    def test_configure_writes_private_config_without_interpolating_password(self):
        with tempfile.TemporaryDirectory() as temporary:
            config_path = Path(temporary) / "tailmail" / "config"
            with (
                patch.object(tailmail, "CONFIG_PATH", config_path),
                patch("builtins.input", side_effect=["mail.example.test", "agent@example.test", ""]),
                patch.object(tailmail, "getpass", return_value="secret%with#symbols"),
                patch.dict(
                    os.environ,
                    {
                        "TAILMAIL_HOST": "",
                        "TAILMAIL_USER": "",
                        "TAILMAIL_PASSWORD": "",
                        "TAILMAIL_FROM": "",
                    },
                ),
            ):
                self.assertEqual(tailmail.cmd_configure(None), 0)
                settings = tailmail.load_settings()

            self.assertEqual(settings["password"], "secret%with#symbols")
            self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)

    def test_wait_returns_first_new_uid_as_json(self):
        source = EmailMessage()
        source["From"] = "alice@example.test"
        source["To"] = "agent@example.test"
        source["Subject"] = "Continue job"
        source["Message-ID"] = "<reply@example.test>"
        source["In-Reply-To"] = "<question@example.test>"
        source["References"] = "<question@example.test>"
        source.set_content("Use the first option.")
        raw_message = source.as_bytes()

        class FakeImap:
            requested_uid = None

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def login(self, *_args):
                return "OK", []

            def select(self, *_args, **_kwargs):
                return "OK", []

            def uid(self, command, *_args):
                if command == "search":
                    return "OK", [b"8 12"]
                if command == "fetch":
                    self.requested_uid = _args[0]
                    return "OK", [(b"12 (RFC822)", raw_message), b")"]
                raise AssertionError(f"unexpected IMAP command: {command}")

        fake_imap = FakeImap()
        args = SimpleNamespace(
            after=7,
            timeout=0,
            poll_interval=1,
            folder="INBOX",
            json=True,
            attachments_dir=None,
            max_attachment_bytes=1024,
        )
        output = io.StringIO()
        with (
            patch.object(
                tailmail,
                "load_settings",
                return_value={
                    "host": "mail.example.test",
                    "username": "agent@example.test",
                    "password": "app-password",
                },
            ),
            patch.object(tailmail, "tls_context", return_value=None),
            patch.object(tailmail.imaplib, "IMAP4_SSL", return_value=fake_imap),
            contextlib.redirect_stdout(output),
        ):
            result = tailmail.cmd_wait(args)

        data = json.loads(output.getvalue())
        self.assertEqual(result, 0)
        self.assertEqual(fake_imap.requested_uid, b"8")
        self.assertEqual(data["uid"], 8)
        self.assertEqual(data["body"], "Use the first option.\n")
        self.assertEqual(data["in_reply_to"], "<question@example.test>")
        self.assertEqual(data["references"], "<question@example.test>")


if __name__ == "__main__":
    unittest.main()
