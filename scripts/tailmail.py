#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
"""Minimal IMAP/SMTP client for the private tailnet mail server.

Standard library only, TLS verified against the system CA store, so the
Tailscale-issued certificate validates without any special flags.

Configuration is read from ~/.config/tailmail/config (INI) or the environment:

    [default]
    host = <host>.<tailnet>.ts.net
    username = agent-bot@<host>.<tailnet>.ts.net
    password = <secret>
    from = agent-bot@<host>.<tailnet>.ts.net

Environment overrides: TAILMAIL_HOST, TAILMAIL_USER, TAILMAIL_PASSWORD,
TAILMAIL_FROM, TAILMAIL_CONFIG.

Usage:
    tailmail.py send --to alice@HOST --subject "Task done" --body "All good."
    echo "piped body" | tailmail.py send --to alice@HOST --subject "Report"
    tailmail.py inbox --limit 10
    tailmail.py read 42
"""

from __future__ import annotations

import argparse
import configparser
import email
import imaplib
import os
import smtplib
import ssl
import sys
from email.header import decode_header, make_header
from email.message import EmailMessage
from pathlib import Path

CONFIG_PATH = Path(
    os.environ.get("TAILMAIL_CONFIG", "~/.config/tailmail/config")
).expanduser()

IMAP_PORT = 993
SMTP_PORT = 465


def die(message: str, code: int = 1) -> "None":
    print(f"tailmail: {message}", file=sys.stderr)
    raise SystemExit(code)


def load_settings() -> dict[str, str]:
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_PATH)

    def get(key: str, env: str, default: str = "") -> str:
        return (
            os.environ.get(env)
            or cfg.get("default", key, fallback="")
            or default
        )

    host = get("host", "TAILMAIL_HOST")
    if not host:
        die(f"no host configured in {CONFIG_PATH} or TAILMAIL_HOST")

    settings = {
        "host": host,
        "username": get("username", "TAILMAIL_USER"),
        "password": get("password", "TAILMAIL_PASSWORD"),
        "from": get("from", "TAILMAIL_FROM", f"{get('username', 'TAILMAIL_USER')}@{host}"),
    }
    if not settings["username"] or not settings["password"]:
        die("username and password are required")
    return settings


def tls_context() -> ssl.SSLContext:
    return ssl.create_default_context()


def decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def body_text(message: email.message.Message) -> str:
    if message.is_multipart():
        for part in message.walk():
            if part.get_content_type() == "text/plain" and not part.get_filename():
                payload = part.get_payload(decode=True) or b""
                return payload.decode(part.get_content_charset() or "utf-8", "replace")
        for part in message.walk():
            if part.get_content_type() == "text/html" and not part.get_filename():
                payload = part.get_payload(decode=True) or b""
                return payload.decode(part.get_content_charset() or "utf-8", "replace")
        return ""
    payload = message.get_payload(decode=True) or b""
    return payload.decode(message.get_content_charset() or "utf-8", "replace")


def cmd_send(args: argparse.Namespace) -> int:
    settings = load_settings()
    body = args.body if args.body is not None else sys.stdin.read()
    if not body:
        die("empty body (pass --body or pipe text on stdin)")

    message = EmailMessage()
    message["From"] = settings["from"]
    message["To"] = ", ".join(args.to)
    message["Subject"] = args.subject
    message.set_content(body)

    try:
        with smtplib.SMTP_SSL(
            settings["host"], SMTP_PORT, context=tls_context(), timeout=30
        ) as smtp:
            smtp.login(settings["username"], settings["password"])
            refused = smtp.send_message(message)
    except (smtplib.SMTPException, OSError) as exc:
        die(f"send failed: {exc}")

    if refused:
        die(f"recipients refused: {', '.join(refused)}")
    print(f"sent to {', '.join(args.to)}")
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    settings = load_settings()
    try:
        with imaplib.IMAP4_SSL(
            settings["host"], IMAP_PORT, ssl_context=tls_context(), timeout=30
        ) as imap:
            imap.login(settings["username"], settings["password"])
            imap.select(args.folder, readonly=True)
            status, data = imap.uid("search", None, "ALL")
            if status != "OK":
                die("IMAP search failed")
            uids = data[0].split()[-args.limit :]
            if not uids:
                print("(no messages)")
                return 0
            for uid in uids:
                status, fetched = imap.uid(
                    "fetch",
                    uid,
                    "(FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])",
                )
                if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
                    continue
                header = email.message_from_bytes(fetched[0][1])
                unseen = b"\\Seen" not in fetched[0][0]
                print(
                    f"{uid.decode():>5}  {'*' if unseen else ' '}  "
                    f"{decode(header.get('Date')):<31.31}  "
                    f"{decode(header.get('From')):<28.28}  "
                    f"{decode(header.get('Subject'))}"
                )
    except (imaplib.IMAP4.error, OSError) as exc:
        die(f"IMAP error: {exc}")
    return 0


def cmd_read(args: argparse.Namespace) -> int:
    settings = load_settings()
    try:
        with imaplib.IMAP4_SSL(
            settings["host"], IMAP_PORT, ssl_context=tls_context(), timeout=30
        ) as imap:
            imap.login(settings["username"], settings["password"])
            imap.select(args.folder, readonly=True)
            status, fetched = imap.uid("fetch", str(args.uid), "(RFC822)")
            if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
                die(f"message {args.uid} not found")
            message = email.message_from_bytes(fetched[0][1])
    except (imaplib.IMAP4.error, OSError) as exc:
        die(f"IMAP error: {exc}")

    print(f"From:    {decode(message.get('From'))}")
    print(f"To:      {decode(message.get('To'))}")
    print(f"Date:    {decode(message.get('Date'))}")
    print(f"Subject: {decode(message.get('Subject'))}")
    print()
    print(body_text(message))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send and read mail on the tailnet mail server."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_send = sub.add_parser("send", help="send a message")
    p_send.add_argument("--to", nargs="+", required=True, metavar="ADDRESS")
    p_send.add_argument("--subject", required=True)
    p_send.add_argument("--body", help="message body (default: read stdin)")
    p_send.set_defaults(func=cmd_send)

    p_inbox = sub.add_parser("inbox", help="list recent messages")
    p_inbox.add_argument("--limit", type=int, default=20)
    p_inbox.add_argument("--folder", default="INBOX")
    p_inbox.set_defaults(func=cmd_inbox)

    p_read = sub.add_parser("read", help="print one message by UID")
    p_read.add_argument("uid", type=int)
    p_read.add_argument("--folder", default="INBOX")
    p_read.set_defaults(func=cmd_read)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
