# Read me first

This tarball installs a private mail server for a **Tailscale tailnet**:

- Stalwart (SMTP, IMAP, HTTPS)
- Bulwark Lite webmail at `https://<your-node>.<your-tailnet>.ts.net/webmail/`
- a Tailscale-issued TLS certificate
- accounts for people and for agents

Nothing is exposed to the public internet, and no internet mail is configured.

## Before you start

Read `docs/01-prerequisites.md`. In short:

- Debian 12/13 or Ubuntu 24.04/26.04, x86_64 or aarch64
- Tailscale installed and logged in
- **HTTPS Certificates enabled** for your tailnet (admin console → DNS)
- ports 25, 465, 587, 993, 443 free
- root access

## Install

```bash
tar xzf stalwart-tailnet-mail-*.tar.gz
cd stalwart-tailnet-mail-*
sudo ./setup-mail.sh
```

It asks for your hostname, domain, mailbox names and whether you want the
webmail, then prints the plan for confirmation before changing anything.

Credentials are written to `/root/mail-credentials.txt` (mode 0600). Move them
to a password manager and delete the file.

## If something fails

```bash
sudo ./setup-mail.sh --diagnose
sudo ./setup-mail.sh --check
```

The support bundle in `/root` is redacted and is what you send to whoever is
helping you.

## Map

| File | What it is |
|---|---|
| `setup-mail.sh` | the installer |
| `mail-setup.conf.example` | unattended configuration |
| `docs/00-overview.md` | architecture and design |
| `docs/02-quickstart.md` | step by step with the flags |
| `docs/03-accounts-and-agents.md` | accounts, app passwords, agent usage |
| `docs/04-operations.md` | backups, upgrades, renewal, recovery |
| `docs/05-troubleshooting.md` | symptoms, causes, fixes |
| `docs/06-security.md` | threat model and guardrails |
| `docs/07-migrating-from-dovecot.md` | moving existing mail |
| `docs/overview.html` | one-page visual overview |
| `scripts/tailmail.py` | minimal SMTP/IMAP client for agents |
