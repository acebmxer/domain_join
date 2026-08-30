# domain-join-setup

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/tag/acebmxer/domain_join?label=version&sort=semver&color=brightgreen)](CHANGELOG.md)
[![Last commit](https://img.shields.io/github/last-commit/acebmxer/domain_join)](https://github.com/acebmxer/domain_join/commits)
[![Issues](https://img.shields.io/github/issues/acebmxer/domain_join)](https://github.com/acebmxer/domain_join/issues)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](domain-join-setup.sh)
[![Platform: Linux](https://img.shields.io/badge/platform-linux-333333?logo=linux&logoColor=white)](#supported-systems)
[![Tests](https://img.shields.io/badge/tests-476-informational)](tests/run-tests.sh)

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
 ╔═════════════════════════════════════════════════════════════════════════════════╗
 ║             Active Directory Domain Join - Setup and Configuration              ║
 ╚═════════════════════════════════════════════════════════════════════════════════╝
             Distribution    : Fedora Linux 44 (KDE Plasma Desktop Edition)
             Package manager : dnf5 (rhel family)
             Desktop         : KDE Plasma
             Domain          : not joined
             Mode            : changes will be applied
 ───────────────────────────────────────────────────────────────────────────────────
 ▸ [✓] Guided setup                        [ ] Post-join login settings
   [ ] Install packages only               [ ] Grant sudo to a user or group
   [ ] Graphical management tools          [ ] Duo two-factor authentication
   [ ] Join an Active Directory domain     [ ] Windows apps for every user
   [ ] Home directories on first login     [ ] Scan Windows for installed apps
   [✓] Network time synchronisation        [ ] Preflight checks and domain status
   [ ] SDDM login screen
      Install, configure, then offer to join - the whole setup in one pass
 ───────────────────────────────────────────────────────────────────────────────────
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
| **Post-join login settings** | Short usernames, who may log in, then the sudo rights below. |
| **Grant sudo to a user or group** | Asks for an account, a group, or one of each, and writes a `/etc/sudoers.d` drop-in for each. See [sudo rights](#sudo-rights). |
| **Duo two-factor authentication** | Installs Duo Unix, writes `/etc/duo/pam_duo.conf`, and adds `pam_duo.so` to the services you pick — or takes it back out again. See [Duo](#duo-security-two-factor-authentication). |
| **Windows apps for every user** | Installs WinApps system-wide and generates each domain user's configuration at login, so Windows programs in the app menu open under their own account. Can also build the Windows 11 VM (libvirt). See [WinApps](#windows-applications-for-every-domain-user). |
| **Scan Windows for installed apps** | Re-runs the WinApps program scan (`setup.sh --system`) on its own — the same command as the first scan, for use whenever a program is added to or removed from Windows. The entry above already does this at the end of its run. |
| **Preflight checks and domain status** | Read-only: hostname, clock, DNS SRV records, membership and service state. |

The entries fill two columns, the left one taking the odd row when the count is
odd. The terminal only has to be 40x23; below that
the menu says so rather than drawing something broken. It reflows live as the
window is resized, first tightening the spacing between the columns, then
dropping detail — the hint line, then the banner box — before it finally gives
up the second column and stacks everything into one.

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
| **SSSD sudo rules from the directory** | off | Lets `sudo` read sudoers rules *published in AD*, so admin rights are managed centrally. This is not the same thing as [granting sudo here](#sudo-rights), which writes a rule on this machine. |
| **Duo two-factor authentication** | off | A second factor in front of logins, for local *and* domain accounts. Asks separately which services to protect. See [Duo](#duo-security-two-factor-authentication). |
| **Windows applications (WinApps)** | off | Windows programs as entries in the Linux app menu, launched over RDP, configured per domain user. See [WinApps](#windows-applications-for-every-domain-user). |

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
  -e, --extras LIST       mkhomedir,timesync,troubleshoot,shares,sudo,duo,winapps
      --sudo-user LIST    Grant sudo to these accounts, comma separated
      --sudo-group LIST   Grant sudo to these groups, comma separated
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

Windows applications (WinApps):
      --winapps           Set up WinApps for all users (same as -e winapps)
      --no-winapps        Never set up WinApps, whatever the extras say
      --winapps-backend B libvirt | manual | docker | podman
      --winapps-host ADDR Windows hostname or IP. Required for 'manual'
      --winapps-port PORT RDP port (default 3389)
      --winapps-vm NAME   libvirt VM name (default RDPWindows)
      --winapps-libvirt-group G
                          AD group allowed to open the VM in virt-manager
                          (default: the realm's permitted-logins group)
      --winapps-domain D  RDP_DOMAIN (default: the realm this machine joined)
      --winapps-creds M   askpass | kerberos | shared
      --winapps-user USER Windows service account, 'shared' mode only
      --winapps-remove    Remove the multi-user wiring
      --winapps-vm-remove With --winapps-remove, also delete the libvirt guest
      --winapps-deploy    Build the Windows 11 VM (libvirt backend only)
      --no-winapps-deploy Never build the VM; just install the builder script
      --winapps-iso FILE  Full path to a Windows .iso file, filename and all
                          (else fetched with Mido)
      --winapps-vm-ram N  Guest RAM in MiB  (default 4096)
      --winapps-vm-cpus N Guest vCPUs       (default 4)
      --winapps-vm-disk N Guest disk in GiB (default 64)
      --winapps-vm-user U Local administrator account created inside the guest
      --write-vm-config   Write a commented windows-vm.conf and exit
      --vm-config FILE    Read the VM's unattended-install answers from FILE
      --no-vm-config      Ignore any windows-vm.conf that would be found
```

The secret key is also read from the `DUO_SKEY` environment variable, which
keeps it out of the process list and the shell history. The shared-mode WinApps
password is read from `WINAPPS_RDP_PASS` the same way, and the built VM's local
administrator password from `WINAPPS_VM_PASS` (a random one is generated and
printed once if unset).

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

# Grant sudo to a domain group and one account, no prompts
sudo ./domain-join-setup.sh -y --sudo-group 'Linux Admins@corp.example.com' \
     --sudo-user jdoe

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
- **sudo rights** — an account, a group, or one of each. See
  [sudo rights](#sudo-rights) below; the same step is on the menu on its own,
  for a machine that is already a member.

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

## sudo rights

**Grant sudo to a user or group** on the menu (and the last question of the
post-join settings) asks who should be able to run `sudo` here:

```
Who should be allowed to use sudo on this machine?

   1) An account          - one account, local or domain
 * 2) A group             - every member of one group
   3) An account and a group
   4) Neither             - leave sudo exactly as it is
```

Whichever you pick, it asks for the name and writes **one file per grant** under
`/etc/sudoers.d`, named after a slugified form of the principal:

```
/etc/sudoers.d/domain-join-group-linux-admins-corp-example-com
    %Linux\ Admins@corp.example.com ALL=(ALL:ALL) ALL

/etc/sudoers.d/domain-join-user-jdoe
    jdoe ALL=(ALL:ALL) ALL
```

One grant per file means any of them can be revoked by deleting that one file,
and nothing has to be edited out of `/etc/sudoers`.

**Every grant requires a password.** There is no `NOPASSWD` here and no option to
add one: `ALL=(ALL:ALL) ALL` means the account types *its own* password the first
time it runs `sudo` in a session — for a domain account, the domain password,
checked through PAM against SSSD. If `sudo` is among the services Duo protects,
that password is followed by the second factor.

A few details that are easy to get wrong by hand:

- **Spaces in the name.** AD group names routinely have them, and sudoers reads
  a space as a separator — so `Linux Admins` has to be written `Linux\ Admins`.
  The installer escapes it for you.
- **The filename cannot be the name.** `sudo` ignores any file in
  `sudoers.d` whose name contains a dot or ends in `~`, which rules out
  `Linux Admins@corp.example.com` verbatim. The name is folded to
  `linux-admins-corp-example-com` for the filename; the rule inside spells it
  out in full.
- **The qualified form.** A joined machine with the default
  `use_fully_qualified_names` only answers to `name@domain`. If a bare name
  doesn't resolve, the installer retries `name@your.domain` and uses whichever
  one NSS actually answers for — the same thing you would find with:

  ```bash
  getent group "Linux Admins@corp.example.com"
  getent passwd jdoe@corp.example.com
  ```

  A group that resolves has its member list printed back, which is the quickest
  way to confirm you have the group you meant rather than a local one of the
  same name.
- **Nothing invalid is ever installed.** The rule is written to a temporary
  file, checked with `visudo -c`, and only then moved into `/etc/sudoers.d`
  with mode `0440`, owned by root. A syntax error anywhere in that directory
  makes `sudo` refuse to run *at all*, so a file that fails the check must never
  exist at that path even briefly.
- **Names sudoers cannot hold** — anything containing `,` `=` `:` `!` `#` `(`
  `)` or a backslash, and the literal `ALL` — are refused up front rather than
  turned into a rule that means something other than what you typed.

If a name resolves to nothing, it says so and asks whether to write the rule
anyway; a name given with `--sudo-user`/`--sudo-group` is taken as deliberate
and written with a warning. Group membership is read at login, so a member who
is already signed in has to log out and back in before `sudo` sees it.

To take a grant back:

```bash
sudo rm /etc/sudoers.d/domain-join-group-linux-admins-corp-example-com
```

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

#### …and that still does not draw a user list

Getting the account into the model is only half of it. Breeze decides whether to
draw tiles at all in `Main.qml`:

```qml
showUserList: {
    ...
    if (userListModel.hasOwnProperty("containsAllUsers")
        && !userListModel.containsAllUsers) {
        return false                                                      // (1)
    }
    return userListModel.count <= userListModel.disableAvatarsThreshold   // (2)
}
```

Both of those fire. **(1)** because `UserModel` sets `containsAllUsers = false`
in the very branch that appends the domain user — on every released SDDM the
only code path that adds the account is the one that marks the model partial.
**(2)** because the threshold has to sit *below* the user count for that branch
to run at all, which is the exact opposite of what this test wants.

The greeter therefore falls back to a username field with the remembered name
typed into it. That is better than clicking "Other" and typing it yourself, but
it is not a user list, and no combination of settings makes it one.

So the installer forks the theme and patches those two lines. Everything except
`Main.qml` is **symlinked** at the packaged theme, so a Plasma upgrade keeps the
fork's assets, translations and sub-components current and only the one patched
file can go stale — and the fork is rebuilt from source on every run, so that
staleness is corrected the next time the installer is used. The packaged theme
is never modified; `diff -r` against it comes back clean.

If Plasma ever rewrites `showUserList` past recognition, the patch reports
failure and the login screen is left alone rather than replaced by a fork that
looks configured and behaves exactly like the unpatched greeter.

When SDDM is the active display manager, the installer offers to write:

```ini
# /etc/sddm.conf.d/zz-domain-users.conf
[Users]
MinimumUid=1000
RememberLastUser=true

[Theme]
Current=breeze-domain        # the fork, built from whatever theme was selected
DisableAvatarsThreshold=1    # (local accounts in 1000-60000) - 1
EnableAvatars=true           # explicit: the model auto-disables avatars past
                             # the threshold, but only while still default
```

```
/usr/share/sddm/themes/breeze-domain/
├── Main.qml                      # copy, two lines patched
├── metadata.desktop              # copy, renamed for Plasma's Login Screen module
├── theme.conf.user               # needsFullUserModel=false
├── .domain-join-setup.source     # origin + sha256 of the Main.qml it came from
├── theme.conf   -> ../breeze/theme.conf
├── Login.qml    -> ../breeze/Login.qml
└── …                             # every other file, symlinked
```

The stamp file is what stops a second run forking the fork: `sddm_fork_source`
reads the recorded origin and re-derives from the real Breeze rather than
patching an already-patched `Main.qml`.

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

`theme.conf.user` is SDDM's own override file and it lives *inside the fork*, so
the distribution's `theme.conf` is not even opened for writing. Everything takes
effect at the next login screen: local accounts and the last domain user appear
as tiles, and Breeze's own "Other…" button covers a first login or anyone else.
The first domain login still goes through "Other"; the account is remembered
from then on, exactly as a fresh Windows machine behaves.

> Upstream has already fixed this. On SDDM's `develop` branch the `getpwnam()`
> fallback was hoisted out of the loop, so it runs unconditionally,
> `containsAllUsers` stays `true`, and stock Breeze draws the tiles with nothing
> but `RememberLastUser`. That is unreleased — v0.21.0 is still the newest tag —
> and the installer does not try to detect it, because a branch for a version
> that does not exist yet cannot be tested against one. When 0.22 ships, the
> fork can be dropped.

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

## Windows applications for every domain user

[WinApps](https://github.com/winapps-org/winapps) makes individual Windows
programs appear as ordinary entries in the Linux application menu, launched over
RDP against a Windows instance. This section covers what it takes to make that
work for *every* domain user rather than for one account.

### The problem this solves

Upstream WinApps installs one of two ways:

| Mode | Launchers | Binary |
| --- | --- | --- |
| `setup.sh --user` | `~/.local/share/applications` | `~/.local/bin` |
| `setup.sh --system` | `/usr/share/applications` | `/usr/local/bin` |

So `--system` already shares the launchers with every account, and the advice
you will find in older write-ups — run `setup.sh` per user, or copy `.desktop`
files into `/usr/share/applications` by hand — is obsolete.

What `--system` does **not** solve is the configuration. `bin/winapps` opens

```bash
readonly CONFIG_PATH="${HOME}/.config/winapps/winapps.conf"
```

and exits if it is missing. There is no `/etc/winapps` fallback, so every one of
those shared launchers still dies without a file in the home directory of
whoever clicks it. On a domain-joined machine you cannot write those files in
advance: the accounts come from the directory, and the first time you learn a
user exists is when they log in.

### How it works here

One root-owned template, expanded per user at login:

```
/etc/winapps/winapps.conf.template     the master copy - the only file you edit
/usr/local/bin/winapps-user-config     generates ~/.config/winapps/winapps.conf
/usr/local/bin/winapps-askpass         supplies the password to FreeRDP
/etc/profile.d/winapps-user-config.sh  runs the generator for shell/SSH logins
/etc/xdg/autostart/winapps-user-config.desktop   ...and for graphical ones
/etc/skel/.config/winapps/winapps.conf covers the very first login
/usr/local/bin/winapps-vm-deploy       builds the Windows VM (libvirt backend)
```

The generator substitutes `@WINAPPS_USER@` with the login name, stripping a
`DOMAIN\` prefix or an `@realm` suffix so what reaches `RDP_USER` is the bare
`sAMAccountName` Windows expects. **That substitution is the whole point** — it
is what makes the RDP session land in that user's own Windows profile, with
their own mapped drives, instead of everyone sharing one.

Both login hooks are installed because display managers are inconsistent about
sourcing `/etc/profile.d` for a graphical session. Whichever runs second is a
no-op. The generator cannot fail a login: every path in it exits 0.

A user who wants to keep a hand-edited copy deletes the marker line at the top
of their file and it is never regenerated.

### Where Windows runs

| Choice | Description |
| --- | --- |
| **libvirt** *(default)* | A local Windows VM via KVM. Join the VM to the domain in its own right and each user's profile, GPOs and mapped drives come from AD as on a physical box. Best when the PC is used by one person at a time. This is the only backend the script can **build** for you — see [Building the VM](#building-the-vm). |
| **manual** | No VM here at all — the launchers point at a Windows host you already have, typically a Remote Desktop Session Host on the domain. Much lighter, and the sane option beyond a handful of PCs. |
| **docker** / **podman** | Windows in a container via `dockur/windows`. Quick to stand up and easy to reset; joining it to the domain is still on you. |

### Building the VM

With the **libvirt** backend the script can stand up the Windows guest itself
(`--winapps-deploy`, or answer yes when it offers). It installs a
`winapps-vm-deploy` helper and runs it:

- an **unattended** Windows 11 Pro install — no clicking through setup. The
  helper prepares a copy of the ISO under `/var/lib/libvirt/images/` with the
  "Press any key to boot from CD or DVD…" prompt removed so the guest boots
  Setup on its own; if that cannot be done for a given ISO it says so and falls
  back to sending a keypress at boot (watch the first boot in `virt-viewer` and
  press a key if it stalls)
- **virtio** drivers staged so the installer sees the disk, guest tools and the
  QEMU agent installed on first boot
- **Remote Desktop and RemoteApp** switched on, idle sleep disabled, the LAN set
  to a private profile
- a **local administrator account** inside the guest — see below — `q35` + UEFI
  + an emulated TPM 2.0, and the Windows 11 hardware checks bypassed in the
  answer file so it installs regardless of host firmware
- `virsh autostart` on, so WinApps can wake it

Supply the install media with `--winapps-iso FILE`. This has to be the full
path to the `.iso` file itself — filename included, e.g.
`/srv/iso/Win11_24H2_English_x64.iso`, not the directory that holds it. A
directory, or a path that does not point at a file, is rejected (and the
interactive prompt just asks again). Without `--winapps-iso` the helper calls
[Mido](https://github.com/ElliotKillick/Mido) to pull a Windows 11 ISO from
Microsoft — convenient, but Mido scrapes Microsoft's download API and breaks
from time to time, so a local ISO is more reliable. ISOs are cached under
`/var/lib/winapps/iso/`.

Size it with `--winapps-vm-ram` (MiB, default 4096), `--winapps-vm-cpus`
(default 4) and `--winapps-vm-disk` (GiB, default 64).

#### The account inside the guest

The unattended install creates one **local Windows account** and makes it an
administrator. This is a Windows account on that VM, not a domain one: it is
what you sign in with to finish setting the machine up, and — until you join the
guest to the domain — the only account on it.

The name is checked before it goes anywhere near the answer file: 20 characters
or fewer, no spaces, no trailing dot, and none of `" / \ [ ] : ; | = , + * ? <
> @`. Windows does not fail loudly on a name it dislikes — Setup simply creates
no account, and the first sign of trouble is a VM nobody can log into.

The password has **no flag**, deliberately: a flag is readable in `ps` by every
user on the machine for as long as the build runs. Set it in `windows-vm.conf`
below, or in `WINAPPS_VM_PASS`, or let the build generate one — that one is
printed once, at the end, and stored nowhere.

This account is **not** what WinApps connects as by default. In the recommended
`askpass` mode each user connects as themselves with their own AD credentials,
which is what lands them in their own Windows profile. Only
`--winapps-creds shared` connects everyone as one fixed account, and that
account can be this one.

#### Opening the VM in virt-manager

`virt-manager` connects to the system libvirt (`qemu:///system`), whose socket
is `root:libvirt` `0770` out of the box. A domain account is in no local group,
so the first time anyone logs in from the directory and opens Virtual Machine
Manager it fails with **`Failed to connect socket to
'/var/run/libvirt/libvirt-sock': Permission denied`** — the refusal happens at
the socket, before polkit is consulted, so there is not even a password prompt.
Adding each user to `libvirt` by hand does not scale to a directory.

The libvirt backend fixes this once, for a whole group:

- the RW socket is opened to every local user — `unix_sock_rw_perms = "0777"`
  in the daemon config, and a `SocketMode=0777` drop-in on the `.socket` units
  for socket-activated builds (Fedora, recent Debian) that ignore the config key
- `/etc/polkit-1/rules.d/49-domain-join-libvirt.rules` then grants
  `org.libvirt.*` to one AD group with no password prompt

So the socket is *reachable* by anyone local, but *management* still goes
through polkit. The step asks which group — defaulting to the realm's
`permitted-groups` (the group named in the login-access question) — or takes it
from `--winapps-libvirt-group 'Linux Admins@corp.example.com'` or a
`libvirt_group` line in [`windows-vm.conf`](#windows-vmconf). Leave it blank
to skip: access then stays with the local `libvirt` group only. Group
membership is read at login, so a user already signed in must log out and back
in. Revoke by deleting the rule file. Needs polkit with JavaScript rules
(0.106+), which is every currently-supported Fedora, RHEL, Ubuntu and Debian.

#### `windows-vm.conf`

The answers the unattended install needs can be written down once instead of
retyped every build:

```bash
./domain-join-setup.sh --write-vm-config
```

writes a commented `windows-vm.conf` next to the script, **mode `0600`** because
it can hold the administrator password. A blank copy is committed here as
[`windows-vm.conf.example`](windows-vm.conf.example) — `cp` it if you prefer,
but `cp` does not give you `0600`:

```bash
cp windows-vm.conf.example windows-vm.conf
chmod 600 windows-vm.conf
```

```ini
# The VM itself
iso           = /srv/iso/Win11_24H2_English_x64.iso
vm_name       = RDPWindows
ram           = 8192
cpus          = 6
disk          = 120

# The answers Windows Setup asks for
edition       = Windows 11 Pro
product_key   = XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
computer_name = WIN11-LAB
admin         = winadmin
password      = choose something long
owner         = Example User
organization  = Example Ltd
timezone      = Eastern Standard Time
ui_language   = en-GB
system_locale = en-GB
user_locale   = en-GB
input_locale  = 0809:00000809

# WinApps wiring — not a build answer
libvirt_group = Domain Admins
```

Everything between the sizing block and `libvirt_group` goes straight into
`Autounattend.xml`:

| Setting | Unattend setting | Default |
|---|---|---|
| `edition` | `/IMAGE/NAME` | Windows 11 Pro |
| `product_key` | `ProductKey` | the generic Pro key |
| `computer_name` | `ComputerName` | `*` — Setup generates one |
| `admin`, `password` | `LocalAccount`, `AutoLogon` | `Docker`, random |
| `owner` | `RegisteredOwner` | omitted |
| `organization` | `RegisteredOrganization` | omitted |
| `timezone` | `TimeZone` | `UTC` |
| `ui_language` | `SetupUILanguage`, `UILanguage` | `en-US` |
| `system_locale` | `SystemLocale` | follows `ui_language` |
| `user_locale` | `UserLocale` | follows `ui_language` |
| `input_locale` | `InputLocale` | `0409:00000409` |

One more setting, `libvirt_group`, is **not** a build answer — it is the AD
group given `virt-manager` access to the finished guest
([above](#opening-the-vm-in-virt-manager)), otherwise only a prompt or
`--winapps-libvirt-group`. Setting it blank (`libvirt_group =`) grants nobody
and skips the prompt; leaving the line out keeps the prompt. `winapps-vm-deploy`
reads the same file and ignores this key.

That is the whole vocabulary. Anything else is an error naming the file and
line, not a setting quietly ignored. Apart from `libvirt_group`, **this file
covers the VM build and nothing else**; the domain join, Duo, sudo and package
selection stay on the flags and the menu where they were.

A few of these have sharp edges worth knowing:

- **`product_key`** is not about activation. Setup needs a key of the right
  edition to get past its own prompt without a human, so the build supplies
  Microsoft's published generic Windows Pro key by default — it selects the
  edition and nothing more. Change `edition` away from Pro and no key is
  guessed for you: set `product_key`, or Setup will stop and ask. The build
  says so when that happens rather than letting you find out 20 minutes in.
- **`edition`** must be spelled the way the ISO spells it, since Setup matches
  it against `/IMAGE/NAME`. `dism /Get-WimInfo /WimFile:…/sources/install.wim`
  lists what a given ISO actually carries.
- **`timezone`** is a *Windows* time zone name, not an IANA one — `Eastern
  Standard Time`, not `America/New_York`. `tzutil /l` inside any Windows box
  lists them. The default is `UTC`, which is predictable but probably not what
  you want on a desktop you will look at.
- **`ui_language`** only works if the ISO carries that language; a Windows ISO
  is normally single-language. `system_locale` and `user_locale` work
  regardless, which is why they are separate — an `en-GB` ISO is rare, but
  British date formats on a US ISO are one line.
- **`computer_name`** follows NetBIOS rules: 15 characters or fewer, letters
  digits and hyphens, never all digits.

Every one of these is validated before it reaches the answer file, and values
are XML-escaped, so an organization named `Smith & Sons` does not produce a
malformed `Autounattend.xml` that Setup ignores in silence.

A `#` starts a comment only at the **start** of a line, so a password containing
one needs no quoting. The file is read as data, never `source`d — it is parsed
as root, and an answer file has no business running commands.

Without `--vm-config`, the first of these that exists is read, and the run says
which one it used:

| Looked for | Why |
|---|---|
| `$WINDOWS_VM_CONF` | An explicit override for one run |
| the directory holding the script | Travels with a copied checkout |
| `/etc/winapps/windows-vm.conf` | Where the installer's other WinApps files live |

A flag beats the file; `WINAPPS_VM_PASS` in the environment beats it too.
`--no-vm-config` ignores any file that would have been found. `windows-vm.conf`
is in `.gitignore`, so your filled-in copy will not follow the checkout to
GitHub.

`winapps-vm-deploy` reads the same file, so a later
`sudo winapps-vm-deploy --force` rebuilds the guest with the settings that built
it the first time.

**What it does not do:** anything domain-related. The guest comes up in a
workgroup; join it to Active Directory yourself (`sysdm.cpl`, or `Add-Computer`
in PowerShell) once it reaches the desktop. That, plus RDS licensing for more
than one session at a time, is out of scope here.

Rebuild any time with `sudo winapps-vm-deploy --force` (destroys the old guest
and its disk first).

### Credentials

| Mode | Description |
| --- | --- |
| **askpass** *(default)* | Each user is prompted for their own AD password, handed to FreeRDP through its askpass interface — so it never appears on a command line or in the WinApps log. Cached in the kernel *session* keyring where `keyctl` is available, so it is asked once per login rather than once per app, and it dies with the session. Nothing is stored on disk. |
| **kerberos** | Single sign-on from the ticket SSSD obtained at login. The best experience when it works, but it needs the Windows host domain-joined with a correct SPN and a ticket cache FreeRDP can read. **Not verified against a live domain — treat it as the thing to aim for, not to switch on blind.** Falls back to a prompt. |
| **shared** | Everyone connects as one service account. Appropriate for a kiosk; on a multi-user machine it defeats the domain join, because all users land in one Windows profile and the directory cannot tell them apart. |

### Order of operations

The launchers are built by scanning the Windows side for installed programs, so
Windows has to exist first:

1. Install Linux and **join it to the domain** — WinApps reads the joined realm
   to fill in `RDP_DOMAIN`.
2. Run this script's WinApps step. It installs FreeRDP and the backend, writes
   the template, generator and login hooks, and seeds existing accounts. With
   the libvirt backend it also grants an AD group access to `qemu:///system`
   ([above](#opening-the-vm-in-virt-manager)) and offers to **build the Windows
   VM** ([above](#building-the-vm)); otherwise deploy Windows yourself
   (container or RDS host).
3. **Join Windows to the domain.** The script never does this — not even for a
   VM it built.
4. Scan Windows for installed programs to create the launchers:
   `sudo /etc/winapps/setup.sh --system` — and re-run that same command whenever
   a program is added to or removed from Windows. This one scan signs into
   Windows as the guest's **local** administrator (the `admin` / `password` in
   `windows-vm.conf`), which works whether or not Windows is domain-joined; if
   the build generated a random password it asks for one. It connects with
   `/cert:ignore` — the guest's self-signed RDP certificate is regenerated when
   it joins the domain, and `/cert:tofu` would refuse the changed key at a
   prompt the scan cannot answer. The domain users who log in later authenticate
   as themselves, per the credential mode above, and keep `/cert:tofu`.

Step 2 asks whether Windows is already up. If it is not, the groundwork is still
written and it prints the command for step 4 — so the script is safe to run
before Windows exists. A VM built in step 2 takes 20–45 minutes to finish
installing in the background; wait for it to reach the desktop before step 4.

Answering yes at that prompt also offers to strip the install CD drives from a
libvirt guest — the install, virtio and unattend media are only needed through
first boot. It ejects the media from all three drives live, so the ISOs drop off
the running guest immediately, and removes two of the three drives from the
domain definition, leaving a single CD-ROM. libvirt cannot hot-unplug a CD-ROM,
so the two empty drive letters stay until the guest is fully powered off — the
step then offers to `virsh shutdown` and `start` it there and then to finish the
job. Decline and they clear at the next full shutdown; `-y` skips the prompt and
prints the manual commands.

### Day-to-day

```bash
sudo nano /etc/winapps/winapps.conf.template   # change a setting for everyone
sudo /usr/local/bin/winapps-user-config --all  # push it out now, not at next login
sudo /etc/winapps/setup.sh --system            # scan / re-scan Windows for apps
sudo winapps-vm-deploy --force                 # rebuild the Windows VM (libvirt)
sudo ./domain-join-setup.sh --winapps-remove   # take the wiring back out
sudo ./domain-join-setup.sh --winapps-vm-remove # ...and delete the libvirt guest
```

New apps installed in Windows need one re-scan on the machine
(`setup.sh --system`); new *users* need nothing at all — they are configured the
moment they log in.

---

## Verifying

```bash
realm list                          # membership and login policy
id someuser@corp.example.com        # does the directory resolve?
kinit someuser@CORP.EXAMPLE.COM     # get a Kerberos ticket
klist                               # inspect it
sudo systemctl status sssd
sudo -l -U someuser@corp.example.com  # what sudo grants that account
getent group "Linux Admins@corp.example.com"   # the group and its members
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
| A sudo grant seems to do nothing | The rule names something NSS doesn't resolve. `getent group "Linux Admins"` and `getent group "Linux Admins@<domain>"` — use whichever answers, and check with `sudo -l -U <user>`. |
| A group member still can't use sudo | Group membership is read at login. Log out and back in, then `id` to confirm the group is in the list. |
| `sudo` refuses to run at all | A syntax error in `/etc/sudoers.d`. Recover with `pkexec visudo` or a root console, and `visudo -c` to find the offending file. |
| Duo is configured but never asks | Either the rule sits after a `sufficient` that already returned success, or `pam_duo.so` isn't on PAM's search path. `grep -rl pam_duo.so /etc/pam.d/` and check the journal for "module is unknown". |
| Duo denies every login | Wrong `ikey`/`skey`/`host`, or the account isn't enrolled under the username PAM sends. `journalctl -t pam_duo` shows which. |
| Locked out after enabling Duo | Log in on a text console as a member of the bypass group, or from the greeter if `failmode = safe` and Duo is unreachable. Then `sudo sed -i '/pam_duo.so/d' /etc/pam.d/*`. |
| Every `sudo` waits on a phone | `sudo` was among the protected services. Remove it: `sudo sed -i '/pam_duo.so/d' /etc/pam.d/sudo /etc/pam.d/sudo-i`. |
| virt-manager: `Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied` | A domain user is in no local `libvirt` group. Re-run the WinApps step with `--winapps-libvirt-group '<AD group>'`, or add the one account with `sudo usermod -aG libvirt <user>`. Either way, log out and back in — group membership is read at login. |
| virt-manager still asks for a password every time | The polkit rule's group name doesn't match what NSS returns. `id <user>` shows the exact form (`Linux Admins@corp.example.com`); put that in `/etc/polkit-1/rules.d/49-domain-join-libvirt.rules`. |

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

The sudo grants are covered the same way, since a bad file in `/etc/sudoers.d`
stops `sudo` working entirely: that a principal with spaces, `@` and dots folds
into a filename `sudo` will read; that the rule escapes the space and carries
`%` only for a group; that names holding sudoers syntax — and the literal `ALL`
— are refused; that a rule `visudo` rejects never reaches the directory and the
write reports failure; that the file lands mode `0440`; that a comma separated
list writes one file per name; that `--dry-run` and `-y` with no flags write
nothing at all.

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

`windows-vm.conf` is covered the same way, since a build driven from a file is
only as good as the parser reading it: that whitespace, quotes, comments, CRLF
line endings and a `#` inside a password are handled the way the file's own
header claims; that an unknown name, a name belonging to some other part of the
installer, a missing `=` and a non-numeric size each stop the run naming the
file and line; that a flag beats the file and `WINAPPS_VM_PASS` beats it too;
that `--no-vm-config` really ignores it; and that the committed
`windows-vm.conf.example` is byte-identical to what `--write-vm-config`
produces, carries no uncommented setting, and mentions no name the parser would
reject. Malformed product keys, over-long and all-digit computer names and
bogus language tags are each rejected — by the installer *and* by the standalone
builder, which has its own copy of the parser.

`Autounattend.xml` is then rendered for real and read back, because that is
where a wrong value costs 45 minutes rather than a second: that an empty
settings file produces exactly the answer file the script produced before any of
this existed; that each setting reaches the unattend element it claims to;
that `system_locale` and `user_locale` follow `ui_language` when unset; that an
edition with no key of its own leaves `ProductKey` out altogether rather than
emitting an empty one, which Setup treats differently; that a value containing
`&` or `<` comes out escaped; and that the result parses as XML in every case.
The Windows account name is checked against every character Windows refuses,
because an answer file it dislikes produces no account rather than an error.

## Releases

The version a checkout believes it is lives in `SCRIPT_VERSION` near the top of
`domain-join-setup.sh`:

```bash
./domain-join-setup.sh --version
# domain-join-setup 1.5.0
```

Versions follow [Semantic Versioning](https://semver.org/) — the major number
for a change that breaks an existing flag or config file, the minor for a new
menu entry or option, the patch for a fix that changes nothing about how the
script is driven. Every version has an entry in [CHANGELOG.md](CHANGELOG.md) and
an annotated git tag, so `git show v1.3.0:domain-join-setup.sh` prints a script
whose own `--version` agrees with the tag it came from.

There is no packaging step and nothing is published anywhere: cutting a release
means bumping `SCRIPT_VERSION`, moving the **Unreleased** section of the
changelog under the new number with today's date, committing, and tagging that
commit.

```bash
git tag -a v1.5.0 -m "domain-join-setup 1.5.0"
git push origin v1.5.0
```

Machines stay current through the script's own update check rather than through
tags — see `--update` and `--no-update-check` — which fast-forwards the checkout
from its remote. A tag is for reading history, not for delivery.

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 acebmxer.
