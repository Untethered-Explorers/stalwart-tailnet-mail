# A private mail server for your tailnet, installed by one script {#tailnet-mail}

One command installs a real mail server that only your Tailscale devices can reach. Stalwart serves SMTP, IMAP and HTTPS, Bulwark Lite provides the webmail, and Tailscale issues a certificate clients already trust.

- Stalwart runs the mail protocols and serves the webmail from the same origin, so there is no second web server to run.
- Tailscale issues the certificate and a weekly timer renews it through Stalwart's API.
- Every listener binds to loopback and the `100.x` address; there is no public exposure.
- Accounts log in with the full address, and each agent gets its own account plus app password.

@answer scope="Debian or Ubuntu host · Tailscale tailnet with HTTPS certificates · no internet mail"
@meta locale=en
@source tailscale-serve title="Tailscale: serve and certificates" url=https://tailscale.com/kb/1247/funnel-serve-use-cases
@source stalwart-docs title="Stalwart documentation" url=https://stalw.art/docs/
@source bulwark-stalwart title="Bulwark Lite on Stalwart" url=https://bulwarkmail.org/docs/deployment/stalwart-app

## What talks to what? {#stack}

The browser never touches IMAP. It loads the webmail from Stalwart on 443, and the webmail talks JMAP to the same origin. Agents skip the browser and speak SMTP and IMAP directly.

@architecture id=mail-stack title="Mail services on one tailnet node"
| browser | Browser | frontend |
| agent | Agent script | frontend |
| stalwart | Stalwart | backend |
| store | Data store | database |
| browser > stalwart | https 443 | |
| agent > stalwart | smtp 465, imap 993 | |
| stalwart > store | mail and settings | |

The data store holds messages, accounts, certificates and settings. It is the only thing to back up.

## Which ports are open, and to whom? {#ports}

| Port | Protocol | TLS | Authentication | Reachable from |
| --- | --- | --- | --- | --- |
| 25 | SMTP | STARTTLS | server-to-server | tailnet only |
| 465 | submission | implicit | required | tailnet only |
| 587 | submission | STARTTLS | required | tailnet only |
| 993 | IMAP | implicit | required | tailnet only |
| 443 | HTTPS | implicit | web login | tailnet only |

Nothing binds `0.0.0.0`. Clients must connect by the MagicDNS name, because that is the name on the certificate.

## What does the installer do? {#install}

It confirms the tailnet first, installs Stalwart, and only then touches the ports.

@workflow id=install-flow title="setup-mail.sh phases"
| pre | Check tailnet | security |
| pkg | Install Stalwart | backend |
| boot | Bootstrap config | backend |
| rec | Recovery mode | security |
| cert | Install certificate | security |
| lis | Create listeners | backend |
| acc | Create accounts | backend |
| web | Mount webmail | backend |
| act | Activate services | backend |
| chk | Verify | backend |
| pre > pkg | |
| pkg > boot | |
| boot > rec | |
| rec > cert | |
| cert > lis | |
| lis > acc | |
| acc > web | |
| web > act | |
| act > chk | |

@steps id=install-steps
| preflight | Check tailnet | Confirms MagicDNS, the HTTPS certificate capability and free ports; stops with the exact fix otherwise. | install-flow | pre |
| packages | Install Stalwart | Downloads the official release and the matching CLI; records the version. | install-flow | pkg |
| bootstrap | Bootstrap config | Pins an administrator, then writes hostname, domain and storage through the Bootstrap API. No wizard needed. | install-flow | boot |
| recovery | Recovery mode | Runs the management API on loopback with mail listeners stopped, so configuration cannot collide with a running server. | install-flow | rec |
| certificate | Install certificate | Fetches the Tailscale certificate and stores it as a Stalwart `Certificate` object. | install-flow | cert |
| listeners | Create listeners | Creates 25/465/587/993/443 bound to loopback and the tailnet address. | install-flow | lis |
| accounts | Create accounts | Creates the human and agent accounts with generated passwords, saved before anything else can fail. | install-flow | acc |
| webmail | Mount webmail | Adds Bulwark Lite as an Application and triggers its download. | install-flow | web |
| activate | Activate services | Leaves recovery mode, stops any old MTA, starts Stalwart on the real ports. | install-flow | act |
| verify | Verify | Checks listeners, TLS, IMAP login and the webmail endpoint. | install-flow | chk |

## What must be true before it runs? {#requirements}

| Requirement | Why it stops the install |
| --- | --- |
| Tailscale logged in with MagicDNS | the hostname becomes the mail domain |
| HTTPS certificates enabled for the tailnet | `tailscale cert` has nothing to issue |
| Ports 25, 465, 587, 993, 443 free | an old mail server owns them |
| Debian or Ubuntu, x86_64 or aarch64 | the release binaries are built for those |
| Root access | service accounts, ports under 1024, package installs |

## What surprises people afterwards? {#gotchas}

| Symptom | Cause | Fix |
| --- | --- | --- |
| Login fails with the right password | username is not the full address | use `user@<host>.<tailnet>.ts.net` |
| Sending rejected | sender is not one of the account's addresses | send as the account, or add an alias |
| Certificate warning months later | renewal timer failed to update the object | run the renewal script, check the API key |
| Webmail 404 right after install | bundle still downloading | wait, or trigger the update action |
| Cron script cannot find `sendmail` | Stalwart has no sendmail binary | use `msmtp-mta` or the provided client |

## What to check once it is running {#next}

- [ ] Sign in at `https://<host>.<tailnet>.ts.net/webmail/` with the full address.
- [ ] Run `sudo ./setup-mail.sh --check`; every check passes.
- [ ] Move `/root/mail-credentials.txt` into a password manager and delete the file.
- [ ] Give each agent its own app password, never the account password.
- [ ] Confirm `mail-cert-renew.timer` is enabled.
- [ ] Tighten tailnet grants so only your devices reach the mail ports.
