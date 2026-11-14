---
id: ADR-0005
applies_to:
  - "setup-mail.sh"
  - "scripts/tailmail.py"
  - "docs/03-accounts-and-agents.md"
  - "docs/08-faq.md"
status: Accepted
---

# ADR-0005: Use internal Stalwart accounts, full-address usernames, and per-agent app passwords

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Give people and agents separate mail identities without
coupling mailboxes to Linux accounts.

## Agent Rules

- **MUST:** Create mail accounts as Stalwart internal `Account/User` objects.
- **MUST:** Use the full email address as the login name.
- **MUST:** Give each agent its own account and app password.
- **MUST NOT:** Create Linux users for mailboxes.
- **MUST NOT:** Write an account password into an agent configuration file.

## Verify

- **Check:** `grep -n 'Account/User\|AppPassword' setup-mail.sh`,
  `grep -n 'adduser\|useradd' setup-mail.sh`,
  `sudo ./setup-mail.sh --check`, and a manual review of
  `/root/mail-credentials.txt`
- **Expected:** The installer creates `Account/User` objects and app passwords
  and does not create Linux users; the check logs in over IMAP with the full
  address; the credentials file shows one account and one app password per
  agent. Do not share the file.

## Context and Problem Statement

People and automation both need mailboxes, but only the operator needs a Linux
account on the host. Should mailboxes be tied to OS users, and how should agents
authenticate and be revoked independently?

## Decision Drivers

- Mail users should not need shell access to the server.
- Each agent needs revocation without disturbing other agents or the human.
- Client configuration should be predictable.
- The administrator needs a single management surface.
- Password changes should not break every configured device.

## Considered Options

- Linux system users with a traditional Maildir setup.
- Stalwart internal accounts with local-part usernames.
- Stalwart internal accounts with full-address usernames and app passwords.

## Decision Outcome

Chosen option: "Stalwart internal accounts with full-address usernames and app
passwords", because it keeps mailboxes independent of Linux accounts, makes the
login unambiguous across domains, and lets each agent carry a revocable
credential.

### Positive Consequences

- Mail users need no Linux account.
- Each agent has its own mailbox, app password, and audit trail.
- Revoking an app password does not disturb other devices.
- The full address works as the username in every client.

### Negative Consequences

- There is no email-based password reset; an administrator must reset passwords.
- Clients must use the full address, not a bare local part.
- App passwords add a credential to manage and rotate.
- Account creation happens in `/admin`, not in the installer.

## Pros and Cons of the Options

### Linux users with Maildir

- Good, because it follows a familiar Unix mail model.
- Bad, because it couples mailboxes to shell accounts and complicates
  per-agent isolation.

### Internal accounts with local-part usernames

- Good, because the login is short.
- Bad, because it is ambiguous with multiple domains and differs from the
  address users see.

### Internal accounts with full-address usernames and app passwords

- Good, because it is unambiguous and supports per-device revocation.
- Bad, because it requires users to type the full address and adds credential
  management.

## Links

- Implemented by [setup-mail.sh](../../setup-mail.sh) and
  [tailmail.py](../../scripts/tailmail.py).
- Guidance: [03-accounts-and-agents.md](../03-accounts-and-agents.md),
  [08-faq.md](../08-faq.md).
