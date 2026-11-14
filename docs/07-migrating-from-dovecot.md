# Migrating from Dovecot or another IMAP server

The installer targets a fresh host. Moving existing mail is a separate task:
copy the messages while the old server still runs, then cut over.

## Shape of the move

```
old server                     new host
──────────                     ────────
Dovecot Maildir  ── Vandelay ──► Stalwart account
OpenSMTPD/Postfix ── (retire) ──► Stalwart SMTP
```

Accounts are recreated in Stalwart: usernames become full addresses, and
passwords are new. The old server keeps running until the copy succeeds.

## 1. Set up the new host

Run `setup-mail.sh` on the new host and create the same mailbox names
(`alice`, `agent-bot`). Note the passwords from
`/root/mail-credentials.txt`.

## 2. Copy the mail

Vandelay reads a Maildir tree directly, or an IMAP server over the network, and
writes through JMAP.

```bash
# maildir already on the new host (mounted copy or rsync)
vandelay import maildir /srv/old-mail/alice /root/vandelay-alice
vandelay export \
  --url https://<new-host>.<tailnet>.ts.net \
  --auth-basic alice@<new-host>.<tailnet>.ts.net \
  --auth-password '<new account password>' \
  --account-name alice@<new-host>.<tailnet>.ts.net \
  /root/vandelay-alice
```

Or read the old server over IMAP (no local copy):

```bash
vandelay import imap --url imaps://<old-host>:993 \
  --auth-basic alice --auth-password '<old password>' \
  /root/vandelay-alice
vandelay export ... /root/vandelay-alice
```

Repeat per account. Vandelay carries mailboxes, flags, identities and Sieve
scripts where the source supports them. It does **not** copy contacts or
calendars unless the source protocol provides them.

Check the result over IMAP or in the webmail before cutting over.

## 3. Update clients

For every client (phone, laptop, agents):

| Old | New |
|---|---|
| username `alice` | username `alice@<domain>` |
| password | the new account or app password |
| server name/IP | `<host>.<tailnet>.ts.net` |
| SMTP 587 | 465 (implicit) or 587 (STARTTLS) |

`tailmail.py` configs change the same way; the app password goes in the
`password` field.

## 4. Retire the old server

Once clients and agents work:

```bash
# on the old host
sudo systemctl disable --now dovecot opensmtpd postfix
```

Keep the old data for a week or two. Then remove the packages and the Maildirs
after one final backup.

If you migrated on the same host, the `migrate/` directory in this repository
records the exact commands used for an OpenSMTPD + Dovecot → Stalwart move,
including the rollback path.

## 5. Rollback plan

The old stack is the rollback. Before removing it:

- keep the old Maildirs and configuration,
- keep the old server able to start on the same ports,
- do not delete its TLS certificate or DNS name.

Rolling back after new mail has arrived on Stalwart means copying that mail
back; plan the cutover for a quiet window.

## Common surprises

- **Usernames change.** Bare `alice` no longer authenticates; the full address
  is required.
- **No `sendmail` binary.** Cron jobs that piped to `sendmail` need `msmtp-mta`
  or `tailmail.py`.
- **Folder separators.** Vandelay maps Maildir++ folders; check nested folders
  in the webmail after import.
- **Duplicates on re-import.** Vandelay change detection helps but is not a
  merge tool; run it once per account, or use `--prune` deliberately.
- **Old Sent/Drafts.** They import as ordinary folders; Stalwart's special-use
  flags may need to be set on them afterwards.
