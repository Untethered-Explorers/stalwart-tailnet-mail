# Accounts and agents

## The account model

Stalwart's internal directory stores accounts, and the **username is the full
email address**:

```
alice@<host>.<tailnet>.ts.net
agent-bot@<host>.<tailnet>.ts.net
```

The local part is what the installer calls a "mailbox name". There is no
relation to Linux users: the human account exists even if no OS account has
that name, and `adduser` does not create a mailbox.

| Role | Purpose | Credentials |
|---|---|---|
| human | person, webmail + mail clients | account password |
| agent | automation, SMTP/IMAP only | account password + app password |
| admin | `/admin` management | account password |

## Passwords and app passwords

- **Account password** — used for IMAP/SMTP and webmail login. Changing it
  signs out webmail sessions ("remember me" tokens) but leaves app passwords
  working.
- **App password** — a secondary credential for one device or agent. Created
  in the webmail Account Manager (`/account`) or the admin console
  (`/admin` → Directory → Accounts → Credentials). The server shows the secret
  once.

Use an app password for every agent and every place a password is stored in a
config file. Revoking one does not disturb the mailbox password or other
devices.

## Giving an agent access

1. The installer creates one account per agent name and prints its password and
   app password in `/root/mail-credentials.txt`.
2. Put the **app password** in the agent's config, never the account password:

   ```ini
   # ~/.config/tailmail/config, mode 0600
   [default]
   host     = <host>.<tailnet>.ts.net
   username = agent-bot@<host>.<tailnet>.ts.net
   password = <app password>
   from     = agent-bot@<host>.<tailnet>.ts.net
   ```

3. Test it:

   ```bash
   python3 tailmail.py inbox --limit 5
   python3 tailmail.py send --to alice@<host>.<tailnet>.ts.net \
       --subject "Build finished" --body "All tests passed."
   ```

The script writes this file for the human account (the sudo user) pointing at
the first agent, so a local agent can send immediately.

## Sending rules

Stalwart rejects a sender that is not one of the account's addresses:

```
501 5.5.4 You are not allowed to send from this address.
```

To let an agent send as a shared address, add that address as an **alias** on
the agent's account. Do not share one account among unrelated agents: you lose
attribution and per-agent revocation.

## One account per agent

Recommended naming: `agent-<purpose>` (`agent-build`, `agent-monitor`). Each
gets:

- its own mailbox and quota
- its own app password(s), one per host or tool
- its own audit trail in Stalwart's logs

Retiring an agent is `Disable`/delete the account or revoke its app passwords;
mail already delivered stays.

## Reading mail as an agent

IMAP on 993 with the full address and app password. `tailmail.py` wraps the
common operations:

```bash
tailmail.py inbox --limit 20
tailmail.py read 42
```

For push or structured search, Stalwart also exposes JMAP at
`https://<host>/jmap/`. JMAP uses OAuth bearer tokens, not the app password;
stick to SMTP/IMAP unless you have a reason.

## Cron and `sendmail`

Stalwart does not ship `/usr/sbin/sendmail`. Scripts that pipe to `sendmail`
need one of:

- `msmtp-mta`, configured against `smtps://<host>:465` with an agent app
  password, or
- a call to `tailmail.py send` (or `smtplib` directly).

## Guardrails

- One app password per consumer; name them (`agent-bot-opencode`,
  `agent-bot-laptop`).
- Rotate by creating a new app password and deleting the old one; update the
  config in the same window.
- Stalwart bans an address after repeated failed logins (100/day by default).
  A stale credential in a retry loop can lock the agent out — rotate, don't
  retry.
- Keep agent config files at `0600`; never put the secret in a prompt or a
  repository.
