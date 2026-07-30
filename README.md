# domain-join-setup

An interactive installer that sets up everything a Linux workstation needs to
join and live on an **Active Directory** domain — on multiple distributions and
under any desktop environment.

The script detects the distribution *and* the desktop, then offers only the
choices that actually apply to that combination, each with a short description
of what it does and when you'd want it.

```bash
git clone https://github.com/acebmxer/domain_join.git
cd domain_join
sudo ./domain-join-setup.sh
```

Run with no options and you get a menu of everything the script can do. Every
step is still available as a flag for unattended runs.

---

## The menu

```
 ╔════════════════════════════════════════════════════════════════════════════╗
 ║           Active Directory Domain Join - Setup and Configuration           ║
 ╚════════════════════════════════════════════════════════════════════════════╝
          Distribution    : Fedora Linux 44 (KDE Plasma Desktop Edition)
          Package manager : dnf5 (rhel family)
          Desktop         : KDE Plasma
          Domain          : not joined
          Mode            : changes will be applied
 ──────────────────────────────────────────────────────────────────────────────
 ▸ [✓] Guided setup                         [ ] Home directories on first login
   [ ] Install packages only                [✓] Network time synchronisation
   [ ] Graphical management tools           [ ] SDDM login screen
   [ ] Join an Active Directory domain      [ ] Post-join login settings
                                            [ ] Duo two-factor authentication
                      [ ] Preflight checks and domain status
      Install, configure, then offer to join - the whole setup in one pass
 ──────────────────────────────────────────────────────────────────────────────
 Selected: 2
 ↑↓←→ Navigate   SPACE Select/Deselect   ENTER Confirm   D Dry-run   Q Quit
 Legend: [✓] selected  [ ] not selected
```

Arrow keys move, **SPACE** ticks an entry, **ENTER** runs everything ticked,
**D** toggles dry-run without leaving the menu, **Q** or **Esc** quits without
changing anything. Tick several entries and they run in a sensible order —
packages before configuration, configuration before the join, and the settings
that only apply to a domain member last. The header shows what was detected and
whether the machine is already joined.

| Entry | What it runs |
| --- | --- |
| **Guided setup** | The whole thing: pick a backend, GUI tools and extras, install, configure, then offer to join. This is what the flags drive when you skip the menu. |
| **Install packages only** | The same choices and the same install, but nothing is configured and no service is enabled. |
| **Graphical management tools** | Installs and enables just the GUI front ends — Cockpit, GNOME Enterprise Login, YaST or ADSys, whichever apply here. |
| **Join an Active Directory domain** | `realm discover`, `realm join`, then the post-join login settings. |
| **Home directories on first login** | Wires up `pam_mkhomedir` the way this distro expects. |
| **Network time synchronisation** | Enables `chronyd` or `systemd-timesyncd` and turns on NTP. |
| **SDDM login screen** | The last-domain-user tweak described in the [KDE note](#putting-the-domain-user-back-on-the-login-screen). |
| **Post-join login settings** | Short usernames, who may log in, and optional sudo for a domain group. |
| **Duo two-factor authentication** | Installs Duo Unix, writes `/etc/duo/pam_duo.conf`, and adds `pam_duo.so` to the services you pick — or takes it back out again. See [Duo](#duo-security-two-factor-authentication). |
| **Preflight checks and domain status** | Read-only: hostname, clock, DNS SRV records, membership and service state. |

The terminal only has to be 40x20; below that the menu says so rather than
drawing something broken. It reflows live as the window is resized, dropping
detail — the hint line, then the banner box — before it gives up two columns.

---

## Why this exists

GNOME has first-class domain support: Settings → Users → **Enterprise Login**
joins the domain from the GUI. Nothing equivalent ships with KDE Plasma, Xfce,
LXQt or Cinnamon — Plasma's System Settings has no Active Directory module at
all, so those desktops are usually left to the command line.

This script closes that gap. It installs the same backend GNOME uses (SSSD +
realmd) and pairs it with a graphical front end that works **regardless of
desktop**: the Cockpit web console, whose Overview page carries a realmd-driven
*Join domain* dialog.

Primary targets called out during development:

| Distro + Desktop | Status |
| --- | --- |
| **Ubuntu / Kubuntu with KDE** | Full support — SSSD + Cockpit GUI, plus optional Ubuntu ADSys for Group Policy |
| **Fedora KDE Spin** | Full support — SSSD + Cockpit GUI |
| Ubuntu with GNOME | Supported (GNOME's native Enterprise Login is offered) |
| Fedora with GNOME | Supported (GNOME's native Enterprise Login is offered) |

---

## Supported systems

**Distributions** (detected via `/etc/os-release`, with `ID_LIKE` fallback for
derivatives):

| Family | Distributions | Package manager |
| --- | --- | --- |
| `debian` | Debian, Ubuntu, Kubuntu, Linux Mint, Pop!\_OS, Zorin, elementary | `apt-get` |
| `rhel` | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux | `dnf5` / `dnf` / `yum` |
| `suse` | openSUSE Leap, Tumbleweed, SLED/SLES | `zypper` |
| `arch` | Arch, Manjaro, EndeavourOS, Garuda | `pacman` |

**Desktops:** KDE Plasma, GNOME, Xfce, Cinnamon, MATE, LXQt, Budgie, COSMIC,
Sway/Hyprland, and headless systems with no desktop at all.

---

## The choices it presents

### 1. Authentication backend

| Choice | Description |
| --- | --- |
| **SSSD + realmd + adcli** *(recommended)* | The modern standard used by Fedora, RHEL and Ubuntu. Kerberos SSO, cached credentials for offline logins, AD-to-POSIX ID mapping, one-command joins via `realm join`. |
| **Samba Winbind** | Samba's own AD client. Pick this if the machine is also a Samba file server, if you need Windows RID-based UID/GID mapping, or for an old NT4-style domain. Joins with `net ads join`. |
| **Both** | SSSD handles logins; Winbind tooling stays available for Samba shares and `net ads` troubleshooting. |

### 2. Graphical management tools

Only the entries valid for your system are shown.

| Choice | Shown on | Description |
| --- | --- | --- |
| **Cockpit web console** | Everything | Browser UI at `https://localhost:9090`; the Overview page has a **Join domain** button. The practical GUI for KDE, Xfce, LXQt and headless boxes. |
| **GNOME Settings — Enterprise Login** | GNOME, Cinnamon, Budgie | GNOME's native AD integration in the Users panel. |
| **YaST — User Logon / Domain Membership** | openSUSE / SLE | openSUSE's own graphical admin modules for SSSD and Winbind. |
| **Ubuntu ADSys** | Ubuntu and derivatives | Applies AD **Group Policy Objects** to the Ubuntu desktop (dconf, privileges, scripts, shares). Complements SSSD. Full GPO support needs Ubuntu Pro; the package works without it. |
| **No GUI** | Everything | Command line only — `realm`, `adcli`, `net ads`. |

### 3. Supporting components

| Choice | Default | Description |
| --- | --- | --- |
| **Create home directories on first login** | on | Without it a domain user logs in with no home directory and most desktop sessions fail to start. Wired up via `authselect`, `pam-auth-update`, `pam-config` or `pam_mkhomedir` depending on distro. |
| **Enforce network time sync** | on | Kerberos rejects tickets with more than ~5 minutes of clock skew — the single most common cause of a failed join. |
| **Diagnostic tools** | on | `dig`, `ldapsearch`, `kinit` for checking SRV records, querying the directory and testing tickets. |
| **Access to Windows file shares** | off | `cifs-utils` + `smbclient`, including Kerberos-authenticated mounts. |
| **SSSD sudo rules from the directory** | off | Lets `sudo` read sudoers rules published in AD. |
| **Duo two-factor authentication** | off | A second factor in front of logins, for local *and* domain accounts. Asks separately which services to protect. See [Duo](#duo-security-two-factor-authentication). |

---

## Usage

```
sudo ./domain-join-setup.sh [options]

      --menu              Force the interactive menu
      --no-menu           Skip the menu and run the guided setup
  -d, --domain DOMAIN     Active Directory domain (e.g. corp.example.com)
  -u, --user USER         Domain account used to perform the join
  -b, --backend NAME      sssd | winbind | both
  -g, --gui LIST          cockpit,gnome,yast,adsys,none
  -e, --extras LIST       mkhomedir,timesync,troubleshoot,shares,sudo,duo
      --join              Join the domain after installing
      --no-join           Install only; never attempt a join
      --open-firewall     Allow Cockpit (9090/tcp) through the firewall
      --no-open-firewall  Leave the firewall alone
  -y, --yes               Non-interactive; accept every recommended default
  -n, --dry-run           Print what would happen without changing anything
  -l, --list              Show the packages for this system and exit
  -h, --help              Show help
      --version           Print the version

Duo two-factor authentication:
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

Any option that says *what to do* skips the menu and runs the guided setup
directly. `--dry-run` and the internal `--detected-de` only change *how* it is
done, so they leave the menu in place — `sudo ./domain-join-setup.sh --dry-run`
opens the menu with dry-run already on.

### Examples

```bash
# The menu
sudo ./domain-join-setup.sh

# The menu, with nothing allowed to change on disk
sudo ./domain-join-setup.sh --dry-run

# Straight to the guided setup, no menu
sudo ./domain-join-setup.sh --no-menu

# Just show the package list for this machine
./domain-join-setup.sh --list

# Unattended install and join (Kubuntu / Fedora KDE)
sudo ./domain-join-setup.sh -y -b sssd -g cockpit \
     -e mkhomedir,timesync,shares -d corp.example.com -u svc-join --join

# The same, with Duo protecting the login screen
DUO_SKEY=... sudo -E ./domain-join-setup.sh -y -b sssd -g cockpit \
     -d corp.example.com -u svc-join --join \
     --duo --duo-repo --duo-ikey DIXXXXXXXXXXXXXXXXXX \
     --duo-host api-1234abcd.duosecurity.com \
     --duo-protect login --duo-exempt duo-exempt
```

`--dry-run` and `--list` work without root.

---

## What it does after installing

1. **Time sync** — enables `chronyd` or `systemd-timesyncd` and turns on NTP.
2. **Home directories** — enables `pam_mkhomedir` using the right mechanism for
   the distro.
3. **Services** — enables `sssd` (deliberately *not* started, since it has no
   valid config until the join creates one), plus `cockpit.socket` and
   `adsys` if selected.
4. **Firewall** — only if you say yes, opens 9090/tcp for Cockpit. Declining
   still leaves Cockpit usable at `https://localhost:9090`.
5. **Preflight checks** — FQDN hostname, clock sync, and DNS SRV records for
   the domain.
6. **Duo 2FA**, if selected — runs *last*, after the join and after the login
   settings, because it is the only step that can leave a machine unable to
   authenticate. See [Duo](#duo-security-two-factor-authentication).

### Optional join

If you let it join, it runs `realm discover`, then `realm join`, then offers:

- **Short usernames** — `jdoe` instead of `jdoe@corp.example.com`, with home
  directories at `/home/jdoe`.
- **SDDM login screen** — only offered when SDDM is the active display manager.
  See [KDE Plasma note](#kde-plasma-note) below.
- **Login access** — restrict to one AD group (default), allow all domain
  users, or leave the rules alone. A fresh join otherwise exposes the machine
  to every account in the directory, so the group option is the safer default.
- **sudo rights** — grant an AD group sudo via `/etc/sudoers.d/domain-admins`,
  validated with `visudo -c` and removed again if it doesn't parse.

Every file it edits is backed up first as `<file>.domain-join-setup.<timestamp>.bak`,
and `/etc/sssd/sssd.conf` keeps its `0600` mode (SSSD refuses to start otherwise).

### Short usernames need the cache cleared, not just the setting

`use_fully_qualified_names = False` in `sssd.conf` is only half of it. Every
record already in `cache_<domain>.ldb` was written under the *qualified* name,
and a lookup for the short form misses it — so `jdoe` keeps getting rejected
while `sssd.conf` plainly says short names are on. `sss_cache -E` is not enough
either: it marks records stale, but the keys themselves are still in the old
format. The cache has to go:

```bash
sudo systemctl stop sssd
sudo rm -f /var/lib/sss/db/*.ldb
sudo systemctl start sssd
```

The installer does this for you whenever you turn short names on. The one cost
is cached credentials — the next domain login has to reach a domain controller,
after which offline logins work again. `jdoe@corp.example.com` keeps working
throughout; the short form is simply what gets displayed and accepted as well.

Two things that also make a domain login *look* like a name-format problem when
it isn't:

- **No home directory.** Short names move homes from `/home/jdoe@corp.example.com`
  to `/home/jdoe`. If nothing on the machine creates them, the login succeeds
  and the desktop session then dies instantly on a missing `$HOME` — straight
  back to the greeter, with the session often still listed as active. Enable
  **Home directories on first login** (`-e mkhomedir`); the installer warns if
  you turn short names on without it.
- **SSSD restarted under your own session.** If you run the installer *as a
  domain user* in a graphical session, restarting SSSD pulls NSS and PAM out
  from under it: the screen locker engages, a greeter appears, and the session
  keeps running behind it. It reads as being thrown out even though nothing is
  lost. The installer detects this and leaves SSSD alone, telling you to reboot
  or re-run from a local account instead.

---

## KDE Plasma note

Once the machine is joined, **domain logins work normally through SDDM** — pick
"Other" and type the domain username. KDE's System Settings has no Active
Directory module, so use Cockpit or the `realm` command for join and membership
management.

### Putting the domain user back on the login screen

Out of the box the greeter shows local accounts only, so every domain login
starts with a trip through "Other". SDDM builds its user list with `getpwent()`,
and SSSD deliberately answers that with local accounts only — enumerating a
directory is expensive, so it is off by default.

The fix is *not* to enumerate the domain. SDDM 0.19 added a per-theme
`needsFullUserModel` flag; with it `false`, the greeter resolves the last user
from `/var/lib/sddm/state.conf` with a single `getpwnam()` — which SSSD answers
without complaint. On an issued workstation that gives the Windows behaviour,
where the owner sees their own name and types only a password.

**That flag is not sufficient on its own**, which is easy to miss. In
`UserModel.cpp` the `getpwnam()` fallback is not a separate code path — it sits
inside the early-exit branch of the enumeration loop:

```cpp
if (!needAllUsers && d->users.count() > Theme.DisableAvatarsThreshold) {
    if (!lastUserFound && (lastUserData = getpwnam(lastUser())))
        d->users << ...
    break;
}
```

`needsFullUserModel=false` only clears the `needAllUsers` half of that
condition. The enumerated count still has to *exceed*
`DisableAvatarsThreshold`, whose default is 7 — more accounts than a normal
workstation has. The loop therefore never breaks early, the fallback never
runs, and the domain user never appears. Setting the theme flag alone changes
nothing visible.

So the installer sets the threshold to one below the number of local accounts.
The branch then fires on the last local account: every local user is already in
the model, the domain user is appended by name, and nothing is lost.

When SDDM is the active display manager, the installer offers to write:

```ini
# /etc/sddm.conf.d/zz-domain-users.conf
[Users]
MinimumUid=1000
RememberLastUser=true

[Theme]
DisableAvatarsThreshold=1    # (local accounts in 1000-60000) - 1
EnableAvatars=true           # explicit: the model auto-disables avatars past
                             # the threshold, but only while still default
```

```ini
# /usr/share/sddm/themes/<theme>/theme.conf.user
[General]
needsFullUserModel=false
```

Three details in that drop-in are deliberate:

- **The `zz-` prefix.** Drop-ins are read in alphabetical order and the last
  value wins. Kubuntu ships `20-kubuntu.conf` and `numlock.conf`, and KDE's
  "Login Screen" module writes `kde_settings.conf` — a `10-` prefix loses to all
  of them. (The installer removes an older `10-domain-users.conf` if it finds
  one.)
- **`MaximumUid` is left alone.** AD UIDs land in the millions, far past the
  `60000` default, but the UID window is only applied while walking
  `getpwent()` — `getpwnam()` ignores it. Raising the ceiling is unnecessary
  here and would put `nobody` (65534) on the login screen.
- **No backup is left in that directory.** `ConfigBase::load()` walks it with
  `entryInfoList(QDir::Files | QDir::NoDotAndDotDot)` — **no name filter**. A
  `.bak` there is not an inert backup, it is live configuration, and
  `foo.conf.<stamp>.bak` sorts *after* `foo.conf`, so it overrides the file it
  was copied from. Backups of this drop-in go to
  `/var/backups/domain-join-setup/` instead, and the installer moves any strays
  it finds out of the way. Note also that `/etc/sddm.conf` is read *after* the
  whole drop-in directory, so a key set there beats every drop-in; the installer
  warns if it sees one.

`theme.conf.user` is SDDM's own override file, so the packaged `theme.conf` is
never touched and the setting survives a Plasma upgrade. Both files take effect
at the next login screen. The first domain login still goes through "Other";
the account is remembered from then on, exactly as a fresh Windows machine
behaves.

> **Never run `sddm --version`,** and don't `systemctl restart sddm` from inside
> a running session either. On Kubuntu's build the daemon does not recognise
> `--version` and simply *starts*: it takes VT 1, brings up a display server and
> throws a greeter over whatever session you were in. Your session keeps running
> on its own VT, so nothing is lost — but it is indistinguishable from being
> locked out of your own machine, and you have to `Ctrl-C` a stray daemon.
>
> This is why the installer probes the version through the package database
> (`dpkg-query`, `rpm`, `pacman`) and falls back to grepping the greeter binary
> for the option name. Nothing in it executes `sddm`, and a test asserts that.

If there is no local account in the 1000–60000 range there is nothing for the
loop to enumerate, so the lookup can never fire; the installer says so and
stops. On SDDM older than 0.19 it does the same. The fallback in both cases is
`enumerate = true` in `sssd.conf` paired with an `ldap_user_search_base` scoped
to a single OU, so the greeter gets a short list instead of the whole directory.

---

## Duo Security two-factor authentication

Duo Unix adds a second factor in front of this machine's logins. `pam_duo.so`
runs *after* the password module and doesn't care which module checked the
password — so the same configuration covers **local accounts and Active
Directory accounts together**, with nothing account-type-specific about it.

Pick **Duo two-factor authentication** from the menu, or `-e duo`, or `--duo`.

### What you need first

From the Duo Admin Panel: **Applications → Protect an Application → Unix
Application**. That yields an integration key, a secret key and an API hostname.
Each account that will log in also has to be **enrolled in Duo under the same
username PAM sees** — `jdoe` for a local account, and `jdoe` rather than
`jdoe@corp.example.com` once short names are on (see below).

### Duo Unix has no graphical interface

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

### Where the rule goes, and why not `common-auth`

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

### Failing open or failing closed

```ini
failmode = safe      # Duo unreachable -> password alone is accepted, and logged
failmode = secure    # Duo unreachable -> nobody logs in
```

`safe` is the default. `secure` is the stronger stance and also the one that
locks a workstation out of its own front door during a Duo outage, a DNS
problem, or a laptop that's off the network at the wrong moment.

### The break-glass group

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

### Domain usernames

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

### Getting hold of `pam_duo.so`

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

### Testing it without locking yourself out

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

### SSH

`pam_duo` can only reach an SSH client through keyboard-interactive
authentication, so with `sshd` among the protected services the installer checks
for `UsePAM yes` and `KbdInteractiveAuthentication yes` and offers to write them
to `/etc/ssh/sshd_config.d/99-duo.conf` — validated with `sshd -t` and removed
again if `sshd` rejects it. Note that public-key authentication bypasses the PAM
auth stack entirely, so a key-only login gets no second factor.

---

## Verifying

```bash
realm list                          # membership and login policy
id someuser@corp.example.com        # does the directory resolve?
kinit someuser@CORP.EXAMPLE.COM     # get a Kerberos ticket
klist                               # inspect it
sudo systemctl status sssd
grep -rl pam_duo.so /etc/pam.d/     # which services require Duo
```

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `realm discover` returns nothing | The machine isn't using the AD DNS servers. Check `dig -t SRV _ldap._tcp.dc._msdcs.<domain>`. |
| Join fails with a clock/preauth error | Clock skew over ~5 minutes. `timedatectl` and re-enable NTP. |
| Login accepted but no desktop starts | No home directory — re-run with the `mkhomedir` extra. |
| Domain user not found by `id` | `sssd` isn't running, or the join didn't complete. |
| Login refused after a successful join | Access rules. `realm permit -g "Some Group"` or `realm permit --all`. |
| Login screen lists local users only | SDDM enumerates local accounts and caps UIDs at 60000. See [the KDE note](#putting-the-domain-user-back-on-the-login-screen). |
| Duo is configured but never asks | Either the rule sits after a `sufficient` that already returned success, or `pam_duo.so` isn't on PAM's search path. `grep -rl pam_duo.so /etc/pam.d/` and check the journal for "module is unknown". |
| Duo denies every login | Wrong `ikey`/`skey`/`host`, or the account isn't enrolled under the username PAM sends. `journalctl -t pam_duo` shows which. |
| Locked out after enabling Duo | Log in on a text console as a member of the bypass group, or from the greeter if `failmode = safe` and Duo is unreachable. Then `sudo sed -i '/pam_duo.so/d' /etc/pam.d/*`. |
| Every `sudo` waits on a phone | `sudo` was among the protected services. Remove it: `sudo sed -i '/pam_duo.so/d' /etc/pam.d/sudo /etc/pam.d/sudo-i`. |

A full log of every action is written to `/var/log/domain-join-setup.log`.

---

## Tests

```bash
./tests/run-tests.sh
```

The installer is *sourced* rather than executed by the suite, so the
per-distribution and per-desktop logic can be verified on a single machine.
Coverage: syntax, the package map for all four families, cross-contamination of
distro-specific package names, GUI menu composition per distro/desktop, desktop
detection, argument parsing and CLI exit codes, plus the interactive menu — that
every entry dispatches to an action, that the run order is a permutation of the
entries, that every entry is actually drawn whichever column is longer, that the
layout degrades correctly from 120x45 down to 30x12 without drawing a line wider
than the terminal, and that cursor movement wraps the way the two columns imply.

For Duo, where a mistake is a lockout or a silent 2FA bypass, the risky parts are
tested directly rather than by inspection: the credential formats; which
repository fits which distro; that a module on PAM's search path is named plainly
while one off it gets an absolute path, including when the directory is reached
through a symlink; that `sufficient`, `include`, `substack`, `@include` and
`success=done` are each classified correctly, so the rule is placed where it will
actually run; that the rule lands after the last auth rule when that is safe and
before the stack when it is not; that a second run adds no second copy; that a
PAM file's mode survives the rewrite and `--dry-run` never touches the disk; that
removal refuses to empty a PAM file; and that the secret key stays out of the
`--dry-run` transcript while the config file is created mode `0600`.

## License

MIT
