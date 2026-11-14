# Migration: OpenSMTPD + Dovecot → Stalwart + Bulwark Lite

Target state:

- **Stalwart 1.1** (Rust, single binary) serves SMTP 25, submission 465, IMAP 993
  and HTTPS 443, bound only to `127.0.0.1` and `100.112.57.64`.
- **Bulwark Lite** is mounted at `https://mcsquirrel.tailc7d454.ts.net/webmail/`
  by Stalwart itself — no Node process, no nginx, no CORS.
- The Tailscale certificate is used as a **Certificate object** (manual TLS).
- Accounts are Stalwart-internal and log in with the full address:
  `mcsquirrel@mcsquirrel.tailc7d454.ts.net`, `agent-bot@…`.
- The old stack stays **installed but disabled** until you are confident.

## Safety rules

1. Run `00-backup.sh` first and keep the archive until the migration has been
   stable for a while.
2. Do not purge Dovecot/OpenSMTPD until then. Rollback is a script.
3. Expect ~10 seconds of mail downtime at cutover; nothing before that.
4. Recovery mode (step 3) has no brute-force protection. Keep it on loopback
   and use an SSH tunnel.

## Phases

| Step | Script | Downtime | What it changes |
|---|---|---|---|
| 0 | `00-backup.sh` | none | Writes `/root/mail-migration-<ts>/` |
| 1 | `05-install-cli.sh` | none | Downloads `stalwart-cli` into `migrate/bin/` |
| 2 | `10-install-stalwart.sh` | none | Installs Stalwart; starts bootstrap wizard on :8080 |
| 2b | `15-pin-bootstrap-admin.sh` | none | Pins a known bootstrap admin password |
| — | wizard | none | Writes `/etc/stalwart/config.json` and the admin account |
| 3 | `20-recovery-on.sh` | none | Management API on :8080, mail listeners off |
| 4 | `30-configure.sh` | none | Certificate, listener binds, accounts, Bulwark |
| 5 | `40-activate.sh` | ~10 s | Stops old services, starts Stalwart on the real ports |
| 6 | `60-verify.sh` | none | End-to-end verification of the new stack |
| 7 | `70-import-maildir.sh` | none | Imports `~/Maildir` with Vandelay |
| 8 | `80-agent-config.sh` | none | Writes the agent's `tailmail` config |
| 9 | `85-cert-renewal.sh` | none | Admin API key + Stalwart-aware renewal |

## Step 0 — backup

```bash
sudo bash migrate/00-backup.sh
```

It archives every `/home/*/Maildir`, all mail configuration, both PAM files,
the TLS key, the renewal units and a state dump. Keep the path it prints.

## Step 1 — CLI

```bash
bash migrate/05-install-cli.sh          # no sudo
```

Pinned to `stalwart-cli 1.0.14`, checksum-verified, installed in `migrate/bin/`.

## Step 2 — install Stalwart

```bash
sudo bash migrate/10-install-stalwart.sh
```

The official installer runs in bootstrap mode: no mail ports, only
`http://<host>:8080/admin`. It prints the temporary admin password; the script
reprints it from the journal.

Open the wizard through a tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 mcsquirrel@100.112.57.64
# then browse http://localhost:8080/admin
```

Wizard answers:

| Screen | Value |
|---|---|
| Server hostname | `mcsquirrel.tailc7d454.ts.net` |
| Default email domain | `mcsquirrel.tailc7d454.ts.net` |
| Automatically obtain TLS certificate | **OFF** — the Tailscale cert is installed next |
| Generate email signing keys | leave default |
| Storage | RocksDB, `/var/lib/stalwart/` |
| Directory | Use the internal directory |
| Logging | Log file, ANSI colours off |
| DNS management | Manual |

Save the `admin@…` password the last screen shows.

## Step 3 — recovery mode

```bash
sudo bash migrate/20-recovery-on.sh
```

Restarts Stalwart with **no mail listeners** and the management API on `:8080`.
The generated recovery password lands in `/root/stalwart-recovery-password`.
Because recovery mode disables auto-ban and access control, keep `:8080`
loopback-only (SSH tunnel) and finish steps 4 and 5 promptly.

## Step 4 — configure

```bash
sudo bash migrate/30-configure.sh            # dry run, prints the plan
sudo APPLY=1 bash migrate/30-configure.sh    # execute
```

It:

- installs the Tailscale certificate as a `Certificate` object;
- binds `smtp`, `submissions`, `imaps`, `https` to `127.0.0.1` + tailnet;
- deletes `pop3s`, `sieve` and the plain-HTTP `http` listener;
- creates `mcsquirrel` and `agent-bot` with generated passwords;
- creates an app password for `agent-bot`;
- mounts Bulwark Lite at `/webmail` and triggers its download;
- writes `/root/mail-credentials.txt`.

The dry run is safe: it only queries.

## Step 5 — activate

```bash
sudo bash migrate/40-activate.sh
```

Comments out the recovery variables, disables Dovecot + OpenSMTPD, restarts
Stalwart, verifies the four listeners and checks `https://…/webmail/` and
`/admin`.

If it fails: `sudo bash migrate/50-rollback.sh`.

## Step 6 — import the old mail

Vandelay reads the Maildir tree directly; Dovecot does not need to run.

```bash
npm install -g @stalwartlabs/vandelay

vandelay import maildir /home/mcsquirrel/Maildir /root/import-mcsquirrel.vandelay
vandelay export --url https://mcsquirrel.tailc7d454.ts.net \
    --auth-basic mcsquirrel@mcsquirrel.tailc7d454.ts.net \
    --auth-password '<password from /root/mail-credentials.txt>' \
    --account-name mcsquirrel@mcsquirrel.tailc7d454.ts.net \
    /root/import-mcsquirrel.vandelay
```

Repeat for `agent-bot`. The Maildirs stay untouched, so a failed import costs
nothing.

## Step 7 — clients and agents

- Clients log in with the **full address**, not the bare username.
- `tailmail.py`: set `username`/`from` to `agent-bot@…` and the app password.
- Cron/`sendmail`: install `msmtp-mta` and point it at 465 with the same app
  password, or call `tailmail.py send`.
- `verify-mail.sh` still targets the old stack; rewrite its delivery check to
  send via SMTP AUTH and read back over IMAP.

## Known follow-ups

- **Certificate renewal.** Stalwart stores certificates in its database, not as
  file paths, so the existing `mail-cert-renew` (which only restarts services)
  will not update Stalwart when the Tailscale cert rotates. The current cert is
  valid until February 2027. Before then, create an API key for the admin and
  extend the timer to update the `Certificate` object and restart Stalwart.
- **Firewall.** `ufw` is active. Tailnet-only binds mean no new rules should be
  needed; confirm with `sudo ufw status verbose` after activation.
- **Package upgrades.** Stalwart is upgraded with its installer, not apt. Take a
  backup (`stalwart-cli snapshot`, or copy `/var/lib/stalwart`) before upgrading.

## Rollback

```bash
sudo bash migrate/50-rollback.sh
```

Stops and disables Stalwart, re-enables Dovecot + OpenSMTPD. Mail delivered into
Stalwart after activation stays in `/var/lib/stalwart`; the pre-migration mail is
in `~/Maildir` and in the backup archive.

## Why not Bulwark (full)?

Full Bulwark adds a Node process, an admin console, plugins, settings sync and
web push. Bulwark Lite is the same client as static files served by Stalwart on
the same origin: fewer services, no CORS, one update action. Switching later is
a deployment change, not a data migration.
