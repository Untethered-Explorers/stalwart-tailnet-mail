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

### Mail accounts are not Linux accounts

Do not create a Linux user for each mailbox. The two are independent:

- `alice@<domain>` lives entirely inside Stalwart. No OS account is needed to
  receive mail, use webmail or connect an IMAP/SMTP client.
- `adduser alice` creates no mailbox, and creating a mailbox creates no OS
  account.
- Mail data lives in `/var/lib/stalwart` and belongs to the `stalwart` service
  user; a normal Linux account could not read it without root anyway.

Only the administrator who runs and updates the server needs a Linux account,
with SSH key authentication and `sudo`. Everyone else reaches mail from their
own devices over the tailnet. If someone must run `tailmail.py` or a cron job
**on the server**, give them a dedicated non-sudo Linux account and an app
password, never their mailbox password.

| Role | Purpose | Credentials |
|---|---|---|
| human | person, webmail + mail clients | account password |
| agent | automation, SMTP/IMAP only | account password + app password |
| admin | `/admin` management | account password |

## Passwords and app passwords

- **Account password**: used for IMAP/SMTP and webmail login. Changing it
  signs out webmail sessions and connected applications, but leaves app
  passwords working.
- **App password**: a secondary credential for one device or agent. Created
  in the webmail Account Manager (`/account`) or the admin console
  (**Management → Directory → Accounts → Credentials**). The server shows the
  secret once.

Use an app password for every agent and every place a password is stored in a
config file. Revoking one does not disturb the mailbox password or other
devices.

### Changing your own password

Sign in at `https://<host>/account` (or the webmail, then **Account**), open
**Credentials → Password**, and enter the current password and the new one. The
same screen manages passkeys, two-factor authentication and app passwords.

A password change signs out connected applications and webmail sessions; app
passwords keep working. Update any mail client that stores the account
password. Clients configured with an app password need no change.

### Resetting a password as an administrator

1. Sign in at `https://<host>/admin` as `admin@<domain>`.
2. Open **Management → Directory → Accounts**, select the account and open its
   **Credentials → Password** section.
3. Set a new password and give it to the user over a safe channel.

There is no email-based "forgot password" flow: the Account Manager requires
the current password, so a locked-out user asks an administrator. If the
administrator is locked out, use
[recovery mode](04-operations.md#recovering-access).

## Adding accounts after install

Use the admin console, not the installer:

1. Sign in at `https://<host>/admin` as `admin@<domain>`.
2. Open **Management → Directory → Accounts → Create**.
3. Choose a **User** account. `name` is the local part (`bob`); the login is
   the full `bob@<domain>`.
4. Set a display name and initial password, and leave the role as **User**
   unless the person should manage the server. Add aliases or a quota if
   needed.

The user can change the initial password at `/account` after signing in. Agent
accounts are created the same way; their app passwords are made under the
account's credentials.

To retire an account, delete it in the same list (its data is removed in the
background). To suspend one without deleting it, open its **Permissions** and
disable `authenticate`: sign-in stops, but mail keeps arriving. Back up first
if the mailbox may still be needed.

Do not re-run `setup-mail.sh` to add a user: it resets the existing human,
agent and admin passwords and issues new agent app passwords.

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

Retiring an agent is deleting the account, disabling its `authenticate`
permission, or revoking its app passwords; mail already delivered stays.

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
  A stale credential in a retry loop can lock the agent out. Rotate, don't
  retry.
- Keep agent config files at `0600`; never put the secret in a prompt or a
  repository.
