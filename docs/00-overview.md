# Private mail on a Tailscale tailnet

This guide installs a small, private mail server for a tailnet: real SMTP and
IMAP, a browser client, and no exposure to the public internet. A single
script does the whole install; the rest of these pages explain how it works and
how to run it.

## What you get

| | |
|---|---|
| Mail server | **Stalwart**: SMTP, IMAP4, HTTPS, one Rust binary |
| Webmail | **Bulwark Lite**: served by Stalwart at `/webmail/` |
| TLS | a **Tailscale-issued certificate** for the node's MagicDNS name |
| Accounts | internal Stalwart accounts, username = full email address |
| Exposure | loopback + the node's `100.x` address only |
| Internet mail | none, by design |

## How it fits together

```
 browser (phone, laptop)                agent / script
        │                                   │
        │ https://<host>.<tailnet>.ts.net    │ smtps :465 / imaps :993
        ▼                                   ▼
 ┌─────────────────────────────────────────────────────┐
 │ Stalwart                                            │
 │   :443  webmail + admin + JMAP                      │
 │   :465  submission (implicit TLS)                   │
 │   :587  submission (STARTTLS)                       │
 │   :993  IMAP (implicit TLS)                         │
 │   :25   server-to-server SMTP                       │
 │                                                     │
 │   data: /var/lib/stalwart (RocksDB, mail, settings) │
 │   cert: Certificate object in the data store        │
 └─────────────────────────────────────────────────────┘
             bound to 127.0.0.1 and 100.x.y.z only
```

Bulwark Lite is static files served by Stalwart from the same origin as JMAP.
There is no Node process, no nginx and no CORS configuration.

## Why this shape

- **One process to run, patch and back up.** Stalwart covers SMTP, IMAP, JMAP,
  TLS and the web app host. Fewer moving parts than a Postfix/Dovecot/webmail
  stack.
- **The certificate is free and automatic.** Tailscale issues a publicly
  trusted certificate for the MagicDNS name; clients get no warnings and no
  self-signed trust dance.
- **No public attack surface.** Every listener binds to loopback and the
  tailnet address. There is no port forwarding, no MX record and no internet
  mail to secure.
- **Agents are first-class.** Each agent gets its own account and app
  password, and speaks SMTP/IMAP directly. No browser required.

## What this is not

- Not a public mail server. It does not accept mail from the internet, does not
  sign with DKIM for public receivers, and has no spam filtering.
- Not a groupware suite. Calendars, contacts and files are available in
  Bulwark, but the guide does not wire them into anything else.
- Not zero-maintenance. Stalwart upgrades are manual, and the certificate is
  renewed by a timer that must keep working.

## Requirements at a glance

- Debian 12/13 or Ubuntu 24.04/26.04, x86_64 or aarch64
- Tailscale installed, logged in, MagicDNS and **HTTPS certificates** enabled
- Ports 25, 465, 587, 993 and 443 free on the host
- Root access
- 2 GB free on `/var`; about 1 GB of RAM recommended

Details: [01-prerequisites.md](01-prerequisites.md).

## Read next

1. [Prerequisites](01-prerequisites.md)
2. [Quick start](02-quickstart.md)
3. [Accounts and agents](03-accounts-and-agents.md)
4. [Email as a coding-agent harness channel](09-agent-harness.md)
5. [Operations](04-operations.md)
6. [Troubleshooting](05-troubleshooting.md)
7. [User guide](user-guide.md)
8. [Administrator guide](admin-guide.md)
9. [Architecture decisions](adr/README.md)

## Repository layout

```
setup-mail.sh              the installer
mail-setup.conf.example    unattended configuration sample
make-dist.sh               builds the hand-off tarball
scripts/tailmail.py        minimal SMTP/IMAP client for agents
scripts/install-tailmail-harness.sh  optional per-user CLI setup
docs/                      these pages
LICENSE                    MIT license for the project's code and docs
THIRD-PARTY-NOTICES.md     upstream licenses and the distribution boundary
```
