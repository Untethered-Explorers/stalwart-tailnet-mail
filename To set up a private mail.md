To set up a private mail server for users and AI agents over Tailscale, pair OpenSMTPD (for sending and routing mail) with Dovecot Community Edition (CE) (for IMAP storage and retrieval). Using Tailscale HTTPS certificates avoids self-signed TLS warnings in mail clients and agent libraries while binding services strictly to your private tailnet IP (100.x.y.z).

1. Prerequisites & TLS Certificates

Before installing the mail daemons, generate a valid TLS certificate for your machine's MagicDNS name so clients and agents can connect over TLS without certificate errors.
• Enable HTTPS in Tailscale: Turn on MagicDNS and HTTPS Certificates in your Tailscale Admin Console.
• Generate the certificate: Run the following on your Ubuntu server, replacing <node>.<tailnet>.ts.net with your server's Tailscale domain: [1] (/goto?url=CAESYQHEIkXXl5if4QiusopCOXSvxYl_OxrCuWimKGdQpvvwIUdDxLy6niAQ3x9uY5r1kV3HDsNRErj72snrthRKpAJFqSjvxm6a494DbAQn5-ibphYQ8OSJ2M4M3NCW03cNkdg)
bash
sudo mkdir -p /etc/ssl/tailscale
sudo tailscale cert \
  --cert-file /etc/ssl/tailscale/mail.crt \
  --key-file /etc/ssl/tailscale/mail.key \
  <node>.<tailnet>.ts.net
sudo chmod 640 /etc/ssl/tailscale/mail.key
sudo chown root:root /etc/ssl/tailscale/mail.*
Use code with caution.
• Identify your Tailscale IP: Run tailscale ip -4 to get your server's 100.x.y.z address.

2. Install OpenSMTPD and Dovecot CE

Ubuntu's default repositories include OpenSMTPD and Dovecot packages. If you want the latest Dovecot CE 2.4+ builds directly from upstream, you can also add the official Dovecot CE Repositories. [1] (/goto?url=CAESgQEBxCJF1xDTIQUkBYStbt1iTcprufUFAVMQEjXm0iHq2Yffo2YO4LjFgITAZA47tsKBOLm_hgvhQqGGTgPD-uiKP5bKvUs3poS_sFiRaDedUZ5EH3bNuZG4rOakcUZSxmmUjjgmSiv9rsZSILLDXHW_EYAfmwpxof_VBOn5Y0k9XSs), [2] (/goto?url=CAEScwHEIkXXAzAkpQGqzwFowaf-NDdaQa7LS5m-Tx8Pa8nrYgLqFhTIEtWt0BdkvfNe20b19YnYApH0JSMB6bDsZdxbl4qBMwRf4Tz1a98ArHNnQ1_RMsEdHkSZtoUh1fVndHsiQD8K10Ya43A-ULHgO5UnjfM), [3] (/goto?url=CAESbQHEIkXXyzWgSWbMIPfWAFCiT1T0uK7NROaQxgOTwwCwFAuQPnTM7AyiC_izzXXWaWMhUPHlMC4Stq6M6wFW6KWTJUiERfq_lXl8vRHS4C_xr_CMHAYCd4G5lL8I-WTY6qpjiGO8teCIb2b2IjE), [4] (/goto?url=CAESeAHEIkXX-DJW3yd6F8MzRK3qNVHdL9SqsCTKXhcUjsavctwInoYpwR-Y45qApAVLrqu-XQsMK4bFyeR9E5UDN_r7Gli6cPPRDmdH4IIyMp7JnmXQa_Fjae_G3y9RCqgGR3q0RpBcELgYk5KxJjBs7e63MjH9v0OXEw)
bash
sudo apt update
sudo apt install -y opensmtpd dovecot-core dovecot-imapd dovecot-lmtpd mailutils
Use code with caution.

3. Create Accounts for Users and Agents

Using standard Linux system accounts keeps authentication simple—both human users and automated agents authenticate with their system username and password (or app-specific credentials via PAM).
bash
# Example human user and agent accounts
sudo useradd -m -s /usr/sbin/nologin alice
sudo passwd alice

sudo useradd -m -s /usr/sbin/nologin agent-bot
sudo passwd agent-bot
Use code with caution.
(Setting the shell to /usr/sbin/nologin prevents SSH login while still allowing SMTP/IMAP authentication via PAM.)

4. Configure Dovecot CE (IMAP & LMTP)

OpenSMTPD will hand incoming mail to Dovecot over LMTP (Local Mail Transfer Protocol) so Dovecot indexes messages immediately and stores them in Maildir format. [1] (/goto?url=CAEScgHEIkXXxt8-rn_fZhqcELls0o3QsGH1sI8fJ5Y9yxUoS24tyaKVCoee8Wqn7XC41sXwNkHAZzj_RmWycc_Hyj7QMGciQVf_KeOi-h7mXaJf_13AiwIhIFu8IC4CS99uonJ5nSTeAop3lwxaK_JzOa1nZg)
Version Note: Ubuntu 26.04 and upstream Dovecot CE repositories ship Dovecot 2.4+, which uses a new flat configuration syntax. If you are on Ubuntu 24.04 (Dovecot 2.3), see the syntax note below. [1] (/goto?url=CAESfgHEIkXXlzWfidlQkdeGNBnn6efoUKddJ4V51R1B3wae23HmnO9a2c9QjhhmmHgk09G9FgXQLZhZUu07pRF98vCCp7LjPdFC-v4MVsxltWcTFdqArEFznWxY3_5EWyUIuBT02HEUQ_jyuyofQ_uTBod1xQsPGMMzbFQHQpATfA), [2] (/goto?url=CAESbQHEIkXXyzWgSWbMIPfWAFCiT1T0uK7NROaQxgOTwwCwFAuQPnTM7AyiC_izzXXWaWMhUPHlMC4Stq6M6wFW6KWTJUiERfq_lXl8vRHS4C_xr_CMHAYCd4G5lL8I-WTY6qpjiGO8teCIb2b2IjE)

Option A: Dovecot 2.4+ Configuration (/etc/dovecot/dovecot.conf)

Back up the default config (sudo mv /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak) and create a clean configuration: [1] (/goto?url=CAESkQEBxCJF1011zR1ggnqAVQNpCmWfOVG5mveFZMl-00pHrq1QEnPj6ADqE6yxbb2o7Y44_aV4h_mpsQRYh2i7idjFbPM5xZwKLSh7ZK2bFAUvT0V84xxastDnoVqvt8ltrLcIQ01KVdwekJuh3ewiFqdAw5sjZ4QGX8QkP60m-ettYkFSwj66blVfpOiTiXJHWfDi), [2] (/goto?url=CAESbQHEIkXXAjrHm2JRl8oD_eyjxp99EXgO58vuSmaqQng4uDdALVCJgID2JO5nMPf7NtorwbmeGMBElaHW58uKx_9OjOxKqAMRyVPftYVdtvLiJX2FaH4lzMUkfpqkT7WU6xgqeH1UhpNxbJOGHBY), [3] (/goto?url=CAESeQHEIkXXDJlgcRnns7-kAstE8hsq8356fw24Jr5p_BlV_vziegyNY9VmNOzAc1xm9dAyMVdeyp40YtxvEd6o3i6K_DAuQjMNhgaQMBC2q8qP0qgv40nwfJm0CbT937igDcPt9sJx5N5BYDoLgbqq-89GJnAbkiuHmFs)
hcl
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0

protocols = imap lmtp

# Bind IMAP only to localhost and your Tailscale IP (replace 100.x.y.z)
listen = 127.0.0.1, 100.x.y.z

# TLS Configuration
ssl = required
ssl_server_cert_file = /etc/ssl/tailscale/mail.crt
ssl_server_key_file = /etc/ssl/tailscale/mail.key

# Maildir storage in each user's home directory
mail_driver = maildir
mail_path = ~/Maildir

namespace inbox {
  inbox = yes
  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
}

# System user authentication via PAM
passdb pam {
}
userdb passwd {
}

# Expose LMTP socket for OpenSMTPD
service lmtp {
  unix_listener /var/run/dovecot/lmtp {
    mode = 0660
    user = opensmtpd
    group = opensmtpd
  }
}

service imap-login {
  inet_listener imap {
    port = 0
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
Use code with caution.

Option B: If running Dovecot 2.3 (Ubuntu 24.04)

If dovecot --version outputs 2.3.x, replace the top version lines, TLS keys, and mail path with the legacy syntax: [1] (/goto?url=CAEShAEBxCJF1xki6RLqvsyF80xjkLwYX2zHCvGDB6zOH5qKAogTdj6WJMFAqUrjT4sChFPBAfbpWXkpmCZwAlZGlTffmwsRVRdC9fguv2WGELyXd0rLy10VYwcvAyyFTi4-9MrqvO6fMwa_Lx-V3WI6EVpgI8NGYwn_eQNdwOAbzQgGZFt-FB4), [2] (/goto?url=CAESiAEBxCJF1yRktAEB6ll_UoqYii2dxVNk-HpOS7qfS9LqFZlBS8PwgGas9PrNTz5miGh6ibf1zoYv_LsiFyUL355i6jRxycHN63q2bMfeYfHAFgHZyrMUN3t3kVC_expE_TTnKbFnbxQ9pivJw4-hwrUN87mL3EWUsk5kfZ8aMVJRwlswGuTJCGB8)
• Replace dovecot_config_version / dovecot_storage_version with nothing.
• Replace ssl_server_cert_file / ssl_server_key_file with ssl_cert = </etc/ssl/tailscale/mail.crt and ssl_key = </etc/ssl/tailscale/mail.key.
• Replace mail_driver / mail_path with mail_location = maildir:~/Maildir.
Test and restart Dovecot:
bash
sudo doveconf -n
sudo systemctl enable --now dovecot
sudo systemctl restart dovecot
Use code with caution.

5. Configure OpenSMTPD

Edit /etc/smtpd.conf so OpenSMTPD listens on localhost (for local scripts/agents on the same machine) and your Tailscale interface (for remote users and agents on your tailnet).
hcl
# Certificates
pki mail.ts cert "/etc/ssl/tailscale/mail.crt"
pki mail.ts key "/etc/ssl/tailscale/mail.key"

# Tables
table aliases file:/etc/aliases

# Listen on localhost (unencrypted for local scripts) and Tailscale IP (TLS/AUTH)
listen on lo
listen on 100.x.y.z port 465 smtps pki mail.ts auth
listen on 100.x.y.z port 587 tls-require pki mail.ts auth

# Deliver all local/tailnet mail to Dovecot via LMTP
action "local_lmtp" lmtp "/var/run/dovecot/lmtp" alias <aliases>

# Routing rules (replace <node>.<tailnet>.ts.net with your MagicDNS hostname)
match from local for local action "local_lmtp"
match from local for domain "<node>.<tailnet>.ts.net" action "local_lmtp"
match auth from any for local action "local_lmtp"
match auth from any for domain "<node>.<tailnet>.ts.net" action "local_lmtp"
Use code with caution.
Verify the syntax and start OpenSMTPD: [1] (/goto?url=CAESZwHEIkXXHZa_bIdhwkdyclWw1I00wYIc1sXmfBRSVIDG2pnNwNU10LUpcOeh62pzSqR_OsldSVSH3GWcapzg5n8jX-_fybjc8rslnQcdq1Gc16OuP1zXhuTOsBC9MxXLbx9pkZv2eVw), [2] (/goto?url=CAESZAHEIkXXi6dG3ydjh1hnBy0yPnQXGTPuYjj_LBbdo54NaxZLyOQys8es3xSbmgK42oJ91aHOG4vbr8RtgDmrVeIoFnSr_C_97y4Pj7wYqqLmN3dak3EJV4eMJM-a3HU9i_24eiI)
bash
sudo smtpd -n
sudo systemctl enable --now opensmtpd
sudo systemctl restart opensmtpd
Use code with caution.

6. Connecting Users & Agents

Because everything is bound to 100.x.y.z, your mail server is completely unreachable from the public internet while remaining accessible to any node on your tailnet.

Protocol	Host	Port	Security	Auth
IMAP (Receive)	<node>.<tailnet>.ts.net	993	SSL/TLS	Normal Password (alice / agent-bot)
SMTP (Send)	<node>.<tailnet>.ts.net	465 (or 587)	SSL/TLS (or STARTTLS)	Normal Password (alice / agent-bot)


Quick Verification Test

Send a test email from agent-bot to alice directly on the server:
bash
echo "Task complete." | mail -s "Agent Status" -r agent-bot@<node>.<tailnet>.ts.net alice@<node>.<tailnet>.ts.net
Use code with caution.
Check /var/log/mail.log to confirm OpenSMTPD accepted the message and delivered it via /var/run/dovecot/lmtp. [1] (/goto?url=CAESeAHEIkXX-DJW3yd6F8MzRK3qNVHdL9SqsCTKXhcUjsavctwInoYpwR-Y45qApAVLrqu-XQsMK4bFyeR9E5UDN_r7Gli6cPPRDmdH4IIyMp7JnmXQa_Fjae_G3y9RCqgGR3q0RpBcELgYk5KxJjBs7e63MjH9v0OXEw)
Would you like help configuring a Python script for your AI agents to poll and send messages over IMAP/SMTP?

