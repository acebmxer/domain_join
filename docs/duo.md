# Duo Security two-factor authentication

[← back to the README](../README.md)

Duo Unix adds a second factor in front of this machine's logins. `pam_duo.so`
runs *after* the password module and doesn't care which module checked the
password — so the same configuration covers **local accounts and Active
Directory accounts together**, with nothing account-type-specific about it.

Pick **Duo two-factor authentication** from the menu, or `-e duo`, or `--duo`.

## Flags

```
      --duo               Set up Duo Security 2FA (same as -e duo)
      --no-duo            Never set up Duo, whatever the extras say
      --duo-ikey KEY      Duo integration key
      --duo-skey KEY      Duo secret key. Visible in 'ps'; prefer the two below
      --duo-skey-file F   Read the secret key from the first line of F
      --duo-host HOST     Duo API hostname, e.g. api-1234abcd.duosecurity.com
      --duo-protect LIST  login,sshd,sudo,none
      --duo-failmode MODE safe (allow logins if Duo is unreachable) or secure
      --duo-autopush Y/N  yes = push to the enrolled device instead of prompting
      --duo-exempt GROUP  Break-glass group whose members skip Duo
      --duo-repo          Allow adding Duo's own package repository
      --duo-build         Allow building Duo Unix from source where unpackaged
```

The secret key is also read from the `DUO_SKEY` environment variable, which
keeps it out of the process list and the shell history.

## What you need first

From the Duo Admin Panel: **Applications → Protect an Application → Unix
Application**. That yields an integration key, a secret key and an API hostname.
Each account that will log in also has to be **enrolled in Duo under the same
username PAM sees** — `jdoe` for a local account, and `jdoe` rather than
`jdoe@corp.example.com` once short names are on (see below).

## Duo Unix has no graphical interface

This is the constraint everything else follows from. Duo talks over the PAM
conversation in plain text, so a greeter can render it as a line of text at
best, and often not at all. There is no Duo dialog on Linux.

The configuration that works on a desktop is therefore **autopush**, which the
installer turns on by default whenever the login screen is among the protected
services:

```ini
autopush = yes    # push to the enrolled device instead of asking for a passcode
prompts  = 1      # one attempt; a rejected push fails the login rather than
                  # hanging on a second question the greeter cannot show
```

The greeter takes the password as normal, Duo pushes to the phone, and the login
completes when it's approved. No typing, no dialog needed.

## Where the rule goes, and why not `common-auth`

The installer edits the PAM file of each **individual service** —
`/etc/pam.d/sddm`, `/etc/pam.d/login`, `/etc/pam.d/sshd` — and never
`common-auth`, `system-auth` or `password-auth`. Two reasons:

1. **Those files are generated.** `pam-auth-update` on Debian and `authselect`
   on RHEL rewrite them, and would drop a hand-added line at the next run.
2. **Every service includes them.** A second factor there lands on `sudo`, `su`,
   `cron` and polkit as well as the login screen — and Plasma's graphical polkit
   prompt cannot show Duo's text conversation at all.

Placement inside a service file is *measured*, not assumed. A rule appended to
an auth stack only runs if nothing ahead of it can return success for the whole
stack, and two constructs can:

| Construct | Returns from the stack on success? |
| --- | --- |
| `auth sufficient …` | **yes** |
| `auth include <file>` | yes, if that file has a `sufficient` |
| `auth [… success=done]` | **yes** |
| `auth substack <file>` | no — a `sufficient` inside ends only the substack |
| `auth [success=1 default=ignore]` (Debian) | no |

So on Kubuntu, where `/etc/pam.d/sddm` pulls the primary block in with
`@include common-auth` and that block uses `[success=1 default=ignore]`, the
rule is appended and Duo runs **after** the password:

```
auth       requisite    pam_nologin.so
@include common-auth
-auth      optional     pam_kwallet5.so
auth       required     pam_duo.so     <- added here
```

Where a stack *does* short-circuit — Fedora's `/etc/pam.d/sudo` is just
`auth include system-auth`, and `system-auth` ends `auth sufficient pam_unix.so`
— appending would produce a rule that never runs: 2FA that looks configured and
silently does nothing. The installer detects that, puts the rule **first**
instead, and tells you which files were affected and that Duo will ask before
the password there.

## Failing open or failing closed

```ini
failmode = safe      # Duo unreachable -> password alone is accepted, and logged
failmode = secure    # Duo unreachable -> nobody logs in
```

`safe` is the default. `secure` is the stronger stance and also the one that
locks a workstation out of its own front door during a Duo outage, a DNS
problem, or a laptop that's off the network at the wrong moment.

## The break-glass group

Strongly recommended, and offered by default. Duo's `groups` directive is
evaluated by `pam_duo` itself, before it ever contacts Duo, so the exemption
holds even when the Duo service is completely unreachable:

```ini
groups = *,!duo-exempt
```

Everyone needs Duo except members of `duo-exempt`. The installer creates the
group and offers to add the account that invoked `sudo`, so one local
administrator can always get in and undo things. `pam_duo` logs each bypass to
syslog, so it is auditable rather than invisible.

> Space separates independent patterns in `groups`; commas separate the
> alternatives within one pattern, and `!` negates. `*,!duo-exempt` is a single
> pattern meaning "any group, except that one" — a negated match wins outright.

## Domain usernames

Duo receives the PAM username verbatim. Enable **short usernames** in the
post-join settings (`use_fully_qualified_names = False` in `sssd.conf`) and the
name PAM sees is `jdoe`, which matches a Duo directory entry directly. Otherwise
enrol users as `jdoe@corp.example.com`, or create username aliases in the Duo
Admin Panel.

There is **no** `username_format` option in `pam_duo.conf` — the recognised keys
are `ikey`, `skey`, `host`, `cafile`, `http_proxy`, `groups`/`group`, `failmode`,
`pushinfo`, `autopush`, `verified_push`, `prompts`, `accept_env_factor`,
`fallback_local_ip`, `https_timeout`, `noverify`, `send_gecos`, `gecos_parsed`,
`gecos_delim` and `gecos_username_pos`. Rewriting the username is what
`send_gecos` and the `gecos_*` options are for.

## Getting hold of `pam_duo.so`

The installer tries the cheapest source first and checks for the **module**, not
the package — because a package can install without one:

| System | Where the module comes from |
| --- | --- |
| Ubuntu / Kubuntu / Debian | `duo-unix` from Duo's apt repository (`--duo-repo`) |
| RHEL, Rocky, AlmaLinux, Oracle | `duo_unix` from Duo's yum repository (`--duo-repo`) |
| **Fedora** | Fedora's own `duo_unix` ships `login_duo` **only, with no PAM module**, so this falls through to a source build (`--duo-build`) |
| openSUSE, Arch | no Duo package; source build (`--duo-build`) |

Adding Duo's repository shows you the signing key's fingerprint and asks before
trusting it. The source build downloads Duo's release, verifies its detached
signature where one is published (and shows the SHA256 and asks when it isn't),
then runs `./configure --with-pam=<this system's PAM module directory>
--prefix=/usr/local`. The PAM directory is passed explicitly because Duo's own
default hard-codes `/lib64/security`, which is right on the RPM distributions
and wrong on Debian's multiarch layout. `sysconfdir` is deliberately *not*
passed, so Duo's own default of `/etc/duo` applies — override it and `pam_duo`
would read a different file from the one the installer writes.

## Testing it without locking yourself out

The installer says all of this before it touches anything, and then:

1. Keep a root shell open on a text console (**Ctrl+Alt+F3**) while you test.
2. Test in a **second** session. Don't log out of the current one first.
3. Every file is backed up as `<file>.domain-join-setup.<timestamp>.bak`.

To undo it, run the Duo entry again and choose **Remove Duo from every service**
— that strips the rule from every file under `/etc/pam.d/` that carries it and
leaves the package and credentials in place, so it can be switched back on. By
hand:

```bash
sudo grep -rl pam_duo.so /etc/pam.d/                 # what is wired up
sudo sed -i '/pam_duo.so/d' /etc/pam.d/sddm          # take it back out
```

`/etc/duo/pam_duo.conf` is written root-owned and mode `0600`; the secret key is
never echoed while you type it and never appears in the `--dry-run` transcript
or the log.

## SSH

`pam_duo` can only reach an SSH client through keyboard-interactive
authentication, so with `sshd` among the protected services the installer checks
for `UsePAM yes` and `KbdInteractiveAuthentication yes` and offers to write them
to `/etc/ssh/sshd_config.d/99-duo.conf` — validated with `sshd -t` and removed
again if `sshd` rejects it. Note that public-key authentication bypasses the PAM
auth stack entirely, so a key-only login gets no second factor.
