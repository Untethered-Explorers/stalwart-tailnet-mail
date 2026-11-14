# A private mail server for this tailnet, installed by one script {#tailnet-mail}

Everything is prepared in `~/projects/email`; one command installs, configures and verifies it: `sudo bash install-mail.sh`.

- The installer keeps OpenSMTPD and Dovecot bound to `127.0.0.1` and the Tailscale address, never to a public interface.
- Both daemons authenticate system accounts through PAM, so the installer ships the two PAM service files Ubuntu omits.
- Tailscale issues the TLS certificate and a weekly timer renews it before the 90-day expiry.
- The run ends with live checks: local delivery, TLS on three ports, SMTP AUTH and an IMAP login.

@answer scope="Ubuntu 26.04 · Dovecot 2.4.2 · OpenSMTPD 7.8 · tailnet-only"
@meta locale=en
@source dovecot-ssl title="Dovecot 2.4: SSL/TLS configuration" url=https://doc.dovecot.org/2.4.1/core/config/ssl.html
@source smtpd-conf title="smtpd.conf(5), OpenSMTPD 7.8" url=https://manpages.debian.org/experimental/opensmtpd/smtpd.conf.5

## What carries a message from an agent to a mailbox? {#path}

Two paths share one store: clients submit through OpenSMTPD, and read directly from Dovecot.

@architecture id=mail-path title="Mail paths over the tailnet"
| human | Mail client | frontend |
| agent | Agent client | frontend |
| smtpd | OpenSMTPD | backend |
| dovecot | Dovecot | backend |
| maildir | Maildir | database |
| human > smtpd | submit, 465/587 | |
| human > dovecot | read, 993 | |
| agent > smtpd | submit, 465/587 | |
| agent > dovecot | read, 993 | |
| smtpd > dovecot | LMTP | emphasis |
| dovecot > maildir | store | |

Delivery is Dovecot's job even though OpenSMTPD receives the message: OpenSMTPD hands each envelope to Dovecot over the LMTP socket, so the Maildir is indexed on arrival.

## Which ports open, and to whom? {#ports}

| Purpose | Port | TLS | Auth | Bound to |
| --- | --- | --- | --- | --- |
| IMAP | 993 | implicit | password via PAM | `127.0.0.1` and `100.112.57.64` |
| SMTP submission, implicit TLS | 465 | implicit | required via PAM | `100.112.57.64` |
| SMTP submission, STARTTLS | 587 | STARTTLS | required via PAM | `100.112.57.64` |
| Local scripts | 25 | none | none | `127.0.0.1` |

The certificate is issued for `mcsquirrel.tailc7d454.ts.net`, so clients must connect by that name; connecting to the `100.x` address fails hostname verification.

## What does the installer do, in order? {#install}

It validates before it restarts anything: `smtpd -n` and `doveconf -n` run first, so a bad config never reaches a running service.

@workflow id=install-flow title="install-mail.sh"
| pre | Check tailnet | security |
| pkg | Install daemons | backend |
| cert | Issue certificate | security |
| users | Create agent account | backend |
| conf | Render configs | backend |
| check | Validate syntax | backend |
| start | Start services | backend |
| verify | Verify end to end | backend |
| pre > pkg | |
| pkg > cert | |
| cert > users | |
| users > conf | |
| conf > check | |
| check > start | valid |
| start > verify | |

@steps id=install-steps
| preflight | Check tailnet | Confirms MagicDNS, the HTTPS certificate capability and the `100.x` address; stops with a fix if HTTPS certs are off. | install-flow | pre |
| packages | Install daemons | Installs OpenSMTPD, Dovecot core, IMAP and LMTP packages. | install-flow | pkg |
| certificate | Issue certificate | Writes `mail.crt` and `mail.key` under `/etc/ssl/tailscale`, key mode `0600`. | install-flow | cert |
| account | Create agent account | Creates `agent-bot` with a `nologin` shell and a generated password in `/root/mail-credentials.txt`. | install-flow | users |
| configure | Render configs | Renders `/etc/smtpd.conf`, `/etc/dovecot/dovecot.conf`, both PAM files and the renewal timer. | install-flow | conf |
| validate | Validate syntax | Runs both daemons' own config parsers before touching the running services. | install-flow | check |
| start | Start services | Enables and restarts Dovecot first, then OpenSMTPD, after `tailscaled`. | install-flow | start |
| verify | Verify end to end | Sends a real message and checks TLS, SMTP AUTH and IMAP login. | install-flow | verify |

## What was missing from the original plan? {#gaps}

| Gap | What the reader would see | Fix in this setup |
| --- | --- | --- |
| No `/etc/pam.d/dovecot` | IMAP login fails although the password is right | Installer writes the PAM service file |
| No `/etc/pam.d/smtpd` | SMTP AUTH fails; OpenSMTPD calls `pam_start("smtpd")` | Installer writes the PAM service file |
| LMTP socket owned by `opensmtpd` | Every delivery fails: `mail.lmtp: connect: Permission denied` | Socket mode `0666`; OpenSMTPD connects as the recipient uid, so owner-based limits cannot work |
| No certificate renewal | TLS breaks about 90 days after setup | Weekly timer, restarts only when the cert changed |
| `listen on lo` | Interface name is not portable | Explicit `127.0.0.1` bind |

## What should you do now? {#next}

- [ ] Run `sudo bash install-mail.sh` in `~/projects/email`.
- [ ] Move the agent password from `/root/mail-credentials.txt` into your password manager, then delete that file.
- [ ] Confirm the final report ends with `0 failed`.
- [ ] Add the IMAP account using host `mcsquirrel.tailc7d454.ts.net`, port 993, SSL/TLS.
- [ ] From another tailnet node, confirm ports 465, 587 and 993 respond.
