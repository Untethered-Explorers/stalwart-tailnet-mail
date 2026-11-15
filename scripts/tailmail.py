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
import io
import json
import mimetypes
import os
import re
import smtplib
import ssl
import sys
import time
from getpass import getpass
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import make_msgid
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
    cfg = configparser.ConfigParser(interpolation=None)
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
            if (
                part.get_content_type() == "text/plain"
                and not part.get_filename()
                and part.get_content_disposition() != "attachment"
            ):
                payload = part.get_payload(decode=True) or b""
                return payload.decode(part.get_content_charset() or "utf-8", "replace")
        for part in message.walk():
            if (
                part.get_content_type() == "text/html"
                and not part.get_filename()
                and part.get_content_disposition() != "attachment"
            ):
                payload = part.get_payload(decode=True) or b""
                return payload.decode(part.get_content_charset() or "utf-8", "replace")
        return ""
    if message.get_filename() or message.get_content_disposition() == "attachment":
        return ""
    payload = message.get_payload(decode=True) or b""
    return payload.decode(message.get_content_charset() or "utf-8", "replace")


def attachment_parts(message: email.message.Message):
    for part in message.walk():
        if part.is_multipart():
            continue
        filename = part.get_filename()
        if filename or part.get_content_disposition() == "attachment":
            yield part, decode(filename) or ""


def safe_attachment_name(filename: str, index: int) -> str:
    basename = filename.replace("\\", "/").rsplit("/", 1)[-1]
    basename = re.sub(r"[^A-Za-z0-9._-]+", "_", basename).strip("._-")
    if not basename:
        basename = f"attachment-{index:03d}"
    return f"{index:03d}-{basename[:120]}"


def message_data(
    message: email.message.Message,
    attachments_dir: Path | None = None,
    max_attachment_bytes: int = 10 * 1024 * 1024,
    uid: int | None = None,
) -> dict[str, object]:
    attachments: list[dict[str, object]] = []
    if attachments_dir is not None:
        attachments_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    for index, (part, filename) in enumerate(attachment_parts(message), start=1):
        payload = part.get_payload(decode=True) or b""
        if len(payload) > max_attachment_bytes:
            die(
                f"attachment {filename or index} exceeds "
                f"{max_attachment_bytes} bytes"
            )
        item: dict[str, object] = {
            "filename": filename,
            "content_type": part.get_content_type(),
            "size": len(payload),
        }
        if attachments_dir is not None:
            saved_path = attachments_dir / safe_attachment_name(filename, index)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            try:
                fd = os.open(saved_path, flags, 0o600)
                with os.fdopen(fd, "wb") as attachment_file:
                    attachment_file.write(payload)
            except FileExistsError:
                die(f"refusing to overwrite attachment: {saved_path}")
            item["saved_to"] = str(saved_path)
        attachments.append(item)

    result: dict[str, object] = {
        "message_id": decode(message.get("Message-ID")),
        "from": decode(message.get("From")),
        "to": decode(message.get("To")),
        "date": decode(message.get("Date")),
        "subject": decode(message.get("Subject")),
        "in_reply_to": decode(message.get("In-Reply-To")),
        "references": decode(message.get("References")),
        "body": body_text(message),
        "attachments": attachments,
    }
    if uid is not None:
        result["uid"] = uid
    return result


def fetch_message(imap: imaplib.IMAP4_SSL, uid: bytes) -> email.message.Message:
    status, fetched = imap.uid("fetch", uid, "(RFC822)")
    if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
        die(f"message {uid.decode(errors='replace')} not found")
    return email.message_from_bytes(fetched[0][1])


def output_message(
    message: email.message.Message,
    as_json: bool,
    attachments_dir: Path | None = None,
    max_attachment_bytes: int = 10 * 1024 * 1024,
    uid: int | None = None,
) -> None:
    data = message_data(message, attachments_dir, max_attachment_bytes, uid)
    if as_json:
        print(json.dumps(data, ensure_ascii=True))
        return
    print(f"From:    {data['from']}")
    print(f"To:      {data['to']}")
    print(f"Date:    {data['date']}")
    print(f"Subject: {data['subject']}")
    print()
    print(data["body"])
    for attachment in data["attachments"]:
        saved = attachment.get("saved_to", "not saved")
        print(f"\nAttachment: {attachment['filename']} ({saved})")


def cmd_configure(_args: argparse.Namespace) -> int:
    if CONFIG_PATH.is_symlink():
        die(f"refusing to write through symlink: {CONFIG_PATH}")
    if CONFIG_PATH.exists():
        answer = input(f"Overwrite {CONFIG_PATH}? [y/N] ").strip().lower()
        if answer not in {"y", "yes"}:
            print("Configuration unchanged.")
            return 0

    host = input("Mail server hostname: ").strip()
    username = input("Full mailbox address: ").strip()
    if not host or not username:
        die("host and mailbox address are required")
    sender = input(f"From address [{username}]: ").strip() or username
    password = getpass("App password: ")
    if not password:
        die("app password is required")

    cfg = configparser.ConfigParser(interpolation=None)
    cfg["default"] = {
        "host": host,
        "username": username,
        "password": password,
        "from": sender,
    }
    buffer = io.StringIO()
    cfg.write(buffer)
    CONFIG_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT
    flags |= os.O_TRUNC if CONFIG_PATH.exists() else os.O_EXCL
    fd = os.open(CONFIG_PATH, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as config_file:
            config_file.write(buffer.getvalue())
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    print(f"Saved credentials to {CONFIG_PATH} (mode 0600).")
    return 0


def cmd_send(args: argparse.Namespace) -> int:
    settings = load_settings()
    body = args.body if args.body is not None else sys.stdin.read()
    if not body:
        die("empty body (pass --body or pipe text on stdin)")

    message = EmailMessage()
    message["From"] = settings["from"]
    message["To"] = ", ".join(args.to)
    message["Subject"] = args.subject
    message["Message-ID"] = make_msgid(domain=settings["host"])
    if args.in_reply_to:
        message["In-Reply-To"] = args.in_reply_to
        references = " ".join(
            value for value in (args.references, args.in_reply_to) if value
        )
        message["References"] = references
    message.set_content(body)
    for attachment_path in args.attach:
        path = Path(attachment_path)
        if not path.is_file():
            die(f"attachment is not a file: {path}")
        content_type, _encoding = mimetypes.guess_type(path.name)
        maintype, subtype = (content_type or "application/octet-stream").split("/", 1)
        message.add_attachment(
            path.read_bytes(),
            maintype=maintype,
            subtype=subtype,
            filename=path.name,
        )

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
    if args.json:
        print(
            json.dumps(
                {"sent_to": args.to, "message_id": message["Message-ID"]},
                ensure_ascii=True,
            )
        )
    else:
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
                print("[]" if args.json else "(no messages)")
                return 0
            messages = []
            for uid in uids:
                status, fetched = imap.uid(
                    "fetch",
                    uid,
                    "(FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])",
                )
                if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
                    continue
                header = email.message_from_bytes(fetched[0][1])
                unseen = b"\\Seen" not in fetched[0][0]
                item = {
                    "uid": int(uid),
                    "unseen": unseen,
                    "date": decode(header.get("Date")),
                    "from": decode(header.get("From")),
                    "subject": decode(header.get("Subject")),
                    "message_id": decode(header.get("Message-ID")),
                }
                messages.append(item)
                if not args.json:
                    print(
                        f"{item['uid']:>5}  {'*' if unseen else ' '}  "
                        f"{item['date']:<31.31}  "
                        f"{item['from']:<28.28}  {item['subject']}"
                    )
            if args.json:
                print(json.dumps(messages, ensure_ascii=True))
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
            message = fetch_message(imap, str(args.uid).encode())
    except (imaplib.IMAP4.error, OSError) as exc:
        die(f"IMAP error: {exc}")

    output_message(
        message,
        args.json,
        Path(args.attachments_dir) if args.attachments_dir else None,
        args.max_attachment_bytes,
        args.uid,
    )
    return 0


def cmd_wait(args: argparse.Namespace) -> int:
    settings = load_settings()
    deadline = time.monotonic() + args.timeout
    try:
        with imaplib.IMAP4_SSL(
            settings["host"], IMAP_PORT, ssl_context=tls_context(), timeout=30
        ) as imap:
            imap.login(settings["username"], settings["password"])
            imap.select(args.folder, readonly=True)
            while True:
                status, data = imap.uid(
                    "search", None, "UID", f"{args.after + 1}:*"
                )
                if status != "OK":
                    die("IMAP search failed")
                uids = [
                    uid for uid in data[0].split() if int(uid) > args.after
                ]
                if uids:
                    uid = min(uids, key=int)
                    message = fetch_message(imap, uid)
                    output_message(
                        message,
                        args.json,
                        Path(args.attachments_dir) if args.attachments_dir else None,
                        args.max_attachment_bytes,
                        int(uid),
                    )
                    return 0
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    if args.json:
                        print(json.dumps({"timed_out": True, "after_uid": args.after}))
                    else:
                        print("No new message before timeout.")
                    return 3
                time.sleep(min(args.poll_interval, remaining))
    except (imaplib.IMAP4.error, OSError) as exc:
        die(f"IMAP error: {exc}")
    return 0


def nonnegative_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer")
    if result < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return result


def positive_int(value: str) -> int:
    result = nonnegative_int(value)
    if result == 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send and read mail on the tailnet mail server."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_configure = sub.add_parser("configure", help="create a private local config")
    p_configure.set_defaults(func=cmd_configure)

    p_send = sub.add_parser("send", help="send a message")
    p_send.add_argument("--to", nargs="+", required=True, metavar="ADDRESS")
    p_send.add_argument("--subject", required=True)
    p_send.add_argument("--body", help="message body (default: read stdin)")
    p_send.add_argument("--attach", action="append", default=[], metavar="PATH")
    p_send.add_argument("--in-reply-to", metavar="MESSAGE_ID")
    p_send.add_argument("--references", metavar="MESSAGE_IDS")
    p_send.add_argument("--json", action="store_true")
    p_send.set_defaults(func=cmd_send)

    p_inbox = sub.add_parser("inbox", help="list recent messages")
    p_inbox.add_argument("--limit", type=positive_int, default=20)
    p_inbox.add_argument("--folder", default="INBOX")
    p_inbox.add_argument("--json", action="store_true")
    p_inbox.set_defaults(func=cmd_inbox)

    p_read = sub.add_parser("read", help="print one message by UID")
    p_read.add_argument("uid", type=positive_int)
    p_read.add_argument("--folder", default="INBOX")
    p_read.add_argument("--json", action="store_true")
    p_read.add_argument("--attachments-dir")
    p_read.add_argument(
        "--max-attachment-bytes", type=positive_int, default=10 * 1024 * 1024
    )
    p_read.set_defaults(func=cmd_read)

    p_wait = sub.add_parser("wait", help="wait for a message after a known UID")
    p_wait.add_argument("--after", type=nonnegative_int, required=True, metavar="UID")
    p_wait.add_argument("--timeout", type=nonnegative_int, default=60, metavar="SECONDS")
    p_wait.add_argument(
        "--poll-interval", type=positive_int, default=5, metavar="SECONDS"
    )
    p_wait.add_argument("--folder", default="INBOX")
    p_wait.add_argument("--json", action="store_true")
    p_wait.add_argument("--attachments-dir")
    p_wait.add_argument(
        "--max-attachment-bytes", type=positive_int, default=10 * 1024 * 1024
    )
    p_wait.set_defaults(func=cmd_wait)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
