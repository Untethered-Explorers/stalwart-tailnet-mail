# User Guide

This guide is for people with a mailbox on the server. It covers signing in,
sending and reading mail, passwords, and client settings. Server installation
and operation are in the [Administrator Guide](admin-guide.md).

## Who This Is For

Use this guide if you have an address like `alice@<host>.<tailnet>.ts.net` and
you connect from a device on the tailnet. You do not need a Linux account on the
server.

## Before You Begin

- Your full email address. It is also your username.
- Your account password, or an app password if you are configuring a device or
  an agent.
- A device on the tailnet. The server does not accept connections from the
  public internet.
- The server name: `<host>.<tailnet>.ts.net`.

Mail client settings:

| Setting | Value |
|---|---|
| IMAP | port 993, implicit TLS |
| SMTP | port 465, implicit TLS, or port 587 with STARTTLS |
| Username | your full address |
| Password | your account password or an app password |

## Sign In and First Use

Open `https://<host>.<tailnet>.ts.net/webmail/` and sign in with the full
address. After the first sign-in, open `/account` to change the initial password
and create app passwords.

The administrator controls the initial password. There is no email-based
password reset.

## Main Workflows

### Send and read mail

Use the webmail or any IMAP/SMTP client. The server rejects a sender that is not
one of the account's addresses:

```
501 5.5.4 You are not allowed to send from this address.
```

Send as the account address, or ask the administrator to add a shared address as
an alias on the account.

### Use a mail client

Enter the server name, full address, and password from the table above. Use
implicit TLS on 993 and 465, or STARTTLS on 587. The certificate is issued for
the server name, so connect by name rather than by `100.x` address.

### Change your password

Open `https://<host>/account` and go to **Credentials → Password**. Enter the
current password and the new one.

A password change signs out webmail sessions and connected applications that
store the account password. App passwords keep working. Update any client that
stores the account password; clients configured with an app password need no
change.

### Manage app passwords

Open `/account` and go to **Credentials**. The same screen manages passkeys,
two-factor authentication, and app passwords. The server shows an app password
secret once, so store it before leaving the page.

Use one app password per device or agent. Revoke it when the device is lost or
the agent is retired.

### Use an agent account

Agents use SMTP/IMAP with their own account and app password. See
[03-accounts-and-agents](03-accounts-and-agents.md) for the account model,
`tailmail.py` configuration, and rotation guidance.

## Offline and Reconnect Behavior

The webmail is a web application and needs a live connection to the server. This
repository does not document an offline mode. Desktop and mobile mail clients
may cache messages locally depending on the client; that cache is outside the
server's control.

## Statuses and Notifications

The webmail does not send push notifications. Messages you may see:

| Symptom | What it means | What to do |
|---|---|---|
| Login fails | A common cause is a username that is not the full address | Use `user@<host>.<tailnet>.ts.net` |
| `501 You are not allowed to send from this address` | The From address is not on the account | Send as the account address or ask for an alias |
| `535 credentials invalid` | Wrong password, or the account password changed | Check `/account`; use the app password in configs |
| Webmail returns 404 | The webmail bundle has not downloaded | Tell the administrator |
| Locked out | Auto-ban after repeated failed logins | Wait, or ask the administrator to clear the ban |

## Attachments or Other Data

Attachments are carried by SMTP and IMAP and are handled by Stalwart and your
client. This repository does not document a maximum message size; ask the
administrator if you need one.

Bulwark Lite also exposes calendars, contacts, and files. This project does not
wire them into anything else.

## Accessibility and Mobile Use

The webmail runs in a browser and works on mobile browsers; native mail clients
are an alternative. This repository does not include an accessibility audit or a
documented WCAG conformance level, so test with the assistive technology you
rely on before making it your primary client.

## Privacy and Data Handling

Mail is stored unencrypted in `/var/lib/stalwart`; anyone with root on the host
can read it. The server is reachable only over the tailnet, accepts only
addresses at the configured domain, and does not filter spam or malware.
Backups contain the full mail store and must be protected like the server.

App passwords limit the blast radius of a lost device. Revoke one when a device
is lost.

## Troubleshooting

Start with the symptom table above. The detailed symptom, cause, and fix table
is in [05-troubleshooting](05-troubleshooting.md). If you administer the server,
run `sudo ./setup-mail.sh --check` and `sudo ./setup-mail.sh --diagnose`.

## Getting Help

Ask the administrator who runs the server. For a problem that needs the
maintainer, the administrator can attach the redacted support bundle from
`--diagnose`. Do not send passwords or app passwords in a support request.
