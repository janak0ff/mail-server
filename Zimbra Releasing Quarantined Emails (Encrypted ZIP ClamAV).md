# Zimbra: Releasing Quarantined Emails (Encrypted ZIP / ClamAV)

Reusable runbook for the common alert `Heuristics.Encrypted.Zip` and the subject prefixes `[WARNING: ATTACHMENT UNSCANNED][WARNING: MESSAGE ENCRYPTED]`.

## Summary

- **Cause:** a password-protected attachment (usually a ZIP) that ClamAV cannot open. Amavis quarantines the mail as a precaution.
- **Meaning:** the mail is *unscanned*, not proven clean. Verify before releasing.
- **Fix:** re-inject the raw message with `zmlmtpinject` over LMTP.
- **Do not** use Forward or Redirect from the quarantine mailbox in webmail. The message is scanned again and re-quarantined.

## Prerequisites

- Shell access to the mailbox store server as root, then `su - zimbra`.
- The **Message-ID** from the virus alert email sent to the user (best identifier).
- Recipient and sender addresses (read from the quarantined file, see Step 4).

## Step 1: Get the Message-ID from the alert

Open the virus alert the user received and copy the `Message-ID`, for example `20260914101453.648958109C8C@proxy.example.org.np`. Sender and subject often match several quarantined files, so the Message-ID is the safest key.

## Step 2: Find the quarantine account and mailbox ID

```bash
su - zimbra
zmprov gcf zimbraAmavisQuarantineAccount
zmprov gmi <quarantine-account>
```

Example: account `virus-quarantine.kxvuex5f@ldapexample.com`, `mailboxId: 3`. The mailbox ID differs per server, so always re-check.

Message store path: `/opt/zimbra/store/0/<mailboxId>/msg/0/`

## Step 3: Narrow down candidate files

```bash
cd /opt/zimbra/store/0/<mailboxId>/msg/0
grep -l "sender@example.com" *
grep -l "subject keyword" *
```

Use `-l` (list names only). Never `cat` quarantined files; they can be large and may be malicious.

## Step 4: Identify the exact file

Best method, match by Message-ID:

```bash
grep -il "<Message-ID-from-alert>" <candidate files>
```

Then read the headers:

```bash
for f in <candidate files>; do
  echo "=== $f ==="
  grep -m1 -i "^Subject:" "$f"
  grep -m1 -i "^Date:" "$f"
  grep -m1 -i "^Message-ID:" "$f"
  grep -m1 -i "^X-Envelope-From:" "$f"
  grep -m1 -i "^X-Envelope-To-Blocked:" "$f"
  echo
done
```

- `X-Envelope-To-Blocked` is the real intended recipient (use for `-r`).
- `X-Envelope-From` is the real sender (use for `-s`).
- If `Message-ID` prints blank, the header is folded onto the next line or uses a different case. Use `grep -i`, or search the ID directly.

**Why several files exist:** each blocked recipient gets its own quarantined copy, and a thread can contain several mails. Release only the file that matches the alert.

## Step 5 (optional): `zmbounceMsg` helper script

Jim Dunphy's script automates Steps 2 to 4 and prints the inject commands without running them.

- Source: `github.com/JimDunphy/ZimbraScripts` (`src/zmbounceMsg`)
- Install: copy to the server, `chmod +x zmbounceMsg`, run as the `zimbra` user.

```bash
./zmbounceMsg "<Message-ID-from-alert>"
```

It is not in PATH by default, so `which zmbounceMsg` finds nothing until you install it.

## Step 6: Inspect before releasing

Inject to **your own admin mailbox** first:

```bash
zmlmtpinject -r your.admin@yourdomain -s <original-sender> /opt/zimbra/store/0/<mailboxId>/msg/0/<file>.msg
```

Replace the placeholder address with a real mailbox, or the command fails. Then:

1. Open the mail and download the ZIP.
2. Hash it: `sha256sum file.zip` (Linux) or `Get-FileHash file.zip -Algorithm SHA256` (PowerShell).
3. Search the hash on VirusTotal. For encrypted ZIPs, "not found" is common and does **not** prove it is clean.
4. Confirm with the sender over a separate channel (phone or chat) that they sent it and that a password-protected ZIP is expected.

If the mail is unconfirmed, do not release it.

## Step 7: Release to the real recipient

```bash
cd /opt/zimbra/store/0/<mailboxId>/msg/0
zmlmtpinject -r <recipient> -s <original-sender> <file>.msg
```

| Flag | Meaning |
| --- | --- |
| `-r` | Recipient (from `X-Envelope-To-Blocked`) |
| `-s` | Sender (from `X-Envelope-From`) |
| last argument | `.msg` filename, or full path |

Output text varies by version. No error means it was queued.

## Step 8: Verify delivery

```bash
grep "<recipient>" /var/log/zimbra.log | grep -i lmtp | tail -5
```

The `.msg` filename does not appear in the logs, so search by recipient. Ask the user to check **Inbox and Junk**. The subject keeps the `[WARNING: ...]` prefix, because it was added at quarantine time.

## Quick reference

```bash
su - zimbra
zmprov gcf zimbraAmavisQuarantineAccount
zmprov gmi <that account>
cd /opt/zimbra/store/0/<mailboxId>/msg/0
grep -il "<Message-ID>" *
grep -m1 -i "^X-Envelope-To-Blocked:" <file>
grep -m1 -i "^X-Envelope-From:" <file>
zmlmtpinject -r <you> -s <sender> <file>        # inspect copy
zmlmtpinject -r <recipient> -s <sender> <file>  # final release
```

## Pitfalls

- Redirect or Forward from webmail: the message is re-quarantined. Use `zmlmtpinject`.
- Releasing every grep hit: the user gets duplicates. Match by Message-ID.
- Wrong `-r`: the mail goes to the wrong person, a real risk for sensitive content such as keys or credentials. Read `X-Envelope-To-Blocked` first.
- Placeholders left in the command: it fails or delivers to a non-existent address.
- Reading quarantined files with `cat`: use `grep -l` or `-m1` instead.
- Mailbox ID differs per server: re-check each time.

## References

- Zimbra forum: "Quarantined files - simple script to show how to release" (forums.zimbra.org, topic 65569)
- Zimbra wiki: Restore-Quarantined-Emails




----



# Releasing a quarantined Zimbra email (ClamAV `Heuristics.Encrypted.Zip`)

Your paste covers two cases: the **VAPT** email (`shree.sthapit@example.com`) and the **FCGO API KEY** email (`ajeet@example.com` → `dibya@example.com`). The steps are the same for both. Only the search terms change.

**Why release by CLI:** forwarding or redirecting from the quarantine mailbox in webmail just gets the message re-quarantined. `zmlmtpinject` delivers straight over LMTP, so it skips Amavis/ClamAV.

**Why verify first:** "encrypted zip" means ClamAV *couldn't scan* it, not that it's clean. Check the file before it reaches the end user.

---

## Step 1: Get the Message-ID from the virus alert

The alert email sent to the user contains the Message-ID of the quarantined mail, for example:

- VAPT: `20260914101453.648958109C8C@proxyexample.com`
- FCGO: `20261008113439.7B9A38115468@proxyexample.com`

This is the most reliable identifier, because sender, subject and keywords often match several files.

## Step 2: Find the quarantine account and mailbox ID

```bash
su - zimbra
zmprov gcf zimbraAmavisQuarantineAccount
zmprov gmi virus-quarantine.kxvuex5f@ldapexample.com
```

From your paste: account `virus-quarantine.kxvuex5f@ldapexample.com`, **mailboxId = 3**.

So the message store is `/opt/zimbra/store/0/3/msg/0/`.

## Step 3: Narrow down candidate files

```bash
cd /opt/zimbra/store/0/3/msg/0

# by sender
grep -l "shree.sthapit@example.com" *

# optionally narrow by subject keyword
grep -l "VAPT" *
```

You got 3 hits: `306-3016.msg`, `307-3017.msg`, `340-3201.msg`. All contain "VAPT", so keyword filtering doesn't help here.

## Step 4: Identify the exact file

**4a. Match by Message-ID (best):**

```bash
grep -il "20260914101453.648958109C8C" 306-3016.msg 307-3017.msg 340-3201.msg
```

Your result was `306-3016.msg`, which is the exact file.

**4b. Compare subject, date and recipients.** In your loop, the `Message-ID` line printed blank. The header is probably `Message-Id:` or folded onto the next line, so use a case-insensitive grep:

```bash
for f in 306-3016.msg 307-3017.msg 340-3201.msg; do
  echo "=== $f ==="
  grep -m1 -i "^Subject:" "$f"
  grep -m1 -i "^Date:" "$f"
  grep -m1 -i "^Message-ID:" "$f"
  grep -m1 -i "^X-Envelope-From:" "$f"
  grep -m1 -i "^X-Envelope-To-Blocked:" "$f"
  echo
done
```

Two of those fields matter:

- **`X-Envelope-To-Blocked`** is the real intended recipient. Use it for `-r`.
- **`X-Envelope-From`** is the real sender. Use it for `-s`.

**Why there are several files:** each blocked recipient gets its own quarantined copy. 306 and 307 were one minute apart on 14 Sep, so they're likely the same mail for two recipients. 340 (1 Oct) is a different message in the same thread. Don't release all of them. Release only the one that matches the alert.

## Step 5 (optional shortcut): `zmbounceMsg` script

The forum script automates steps 2-4 and prints the exact inject commands. It doesn't execute anything.

```bash
su - zimbra
./zmbounceMsg "20260914101453.648958109C8C@proxyexample.com"
```

Example output:

```
Run these commands
cd /opt/zimbra/store/0/3/msg/0
zmlmtpinject -r <recipient> -s <sender> 306-3016.msg
```

You can get the script from `github.com/JimDunphy/ZimbraScripts` (`src/zmbounceMsg`). Make it executable with `chmod +x`. Note that `which zmbounceMsg` won't find it unless you've installed it into your PATH.

## Step 6: Inspect before releasing to the real user

Inject the file to **your own admin mailbox first**.

```bash
zmlmtpinject -r your.admin@example.com \
  -s shree.sthapit@example.com \
  /opt/zimbra/store/0/3/msg/0/306-3016.msg
```

Your paste ended with the literal placeholder `your_email@example.com`. Replace it with a real mailbox on your server or the command will fail.

Then:

1. Log in to that mailbox and open the message.
2. Download the ZIP.
3. Hash it: `sha256sum file.zip` (Linux) or `Get-FileHash file.zip -Algorithm SHA256` (PowerShell).
4. Search the hash on VirusTotal. Since the ZIP is encrypted, "not found" is common and **doesn't prove it's clean**.
5. Confirm with the sender, over a separate channel (phone or chat), that they actually sent it. Also confirm the password-protected ZIP is expected.

If a mail is both password-protected and unconfirmed, don't release it.

## Step 7: Release to the actual recipient

Once you're satisfied:

```bash
cd /opt/zimbra/store/0/3/msg/0
zmlmtpinject -r <recipient@example.com> -s <original-sender> <filename>.msg
```

Examples from your paste:

```bash
# VAPT
zmlmtpinject -r <intended_recipient>@example.com -s shree.sthapit@example.com 306-3016.msg

# FCGO API KEY
zmlmtpinject -r dibya@example.com -s ajeet@example.com 351-3218.msg
```

| Flag | Meaning |
|---|---|
| `-r` | Recipient address (from `X-Envelope-To-Blocked`) |
| `-s` | Sender address (from `X-Envelope-From`) |
| last arg | The `.msg` filename, or full path if you're not in that directory |

A success run returns without error. Don't rely on the exact "250 2.0.0 Ok: queued" text, since zmlmtpinject output varies by version.

## Step 8: Verify delivery

```bash
grep "dibya@example.com" /var/log/zimbra.log | grep -i lmtp | tail -5
```

This matches on recipient. The `.msg` filename won't appear in the logs, so grepping for `351-3218` (as suggested earlier in your paste) finds nothing. Then ask the user to check **Inbox and Junk**. The subject will still carry the `[WARNING: ATTACHMENT UNSCANNED][WARNING: MESSAGE ENCRYPTED]` prefix, since it was added at quarantine time.

---

## Quick reference

```bash
su - zimbra
zmprov gcf zimbraAmavisQuarantineAccount          # quarantine account
zmprov gmi <that account>                         # mailboxId
cd /opt/zimbra/store/0/<mailboxId>/msg/0
grep -il "<Message-ID-from-alert>" *              # exact file
grep -m1 -i "^X-Envelope-To-Blocked:" <file>      # real recipient
grep -m1 -i "^X-Envelope-From:" <file>            # real sender
zmlmtpinject -r <you> -s <sender> <file>          # inspect copy
zmlmtpinject -r <recipient> -s <sender> <file>    # final release
```

## Common pitfalls

- **Redirecting from webmail** → re-quarantined. Use `zmlmtpinject`.
- **Releasing every grep hit** → duplicates for the user. Match by Message-ID.
- **Wrong `-r`** → the mail goes to the wrong person, a real risk for something like an API key. Always read `X-Envelope-To-Blocked` first.
- **Placeholders left in the command** → fails or delivers to a non-existent address.
- **Big output from `grep` on files** → use `-l` or `-m1`, since quarantine files can be large and may contain malicious content. Don't `cat` them.
- **Mailbox ID differs per server.** It was 3 here, but always re-check.

I can also turn this into a downloadable doc or a small shell script that automates steps 2-4 using the Message-ID.