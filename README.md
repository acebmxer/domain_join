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

---

## Usage

```
sudo ./domain-join-setup.sh [options]

  -d, --domain DOMAIN     Active Directory domain (e.g. corp.example.com)
  -u, --user USER         Domain account used to perform the join
  -b, --backend NAME      sssd | winbind | both
  -g, --gui LIST          cockpit,gnome,yast,adsys,none
  -e, --extras LIST       mkhomedir,timesync,troubleshoot,shares,sudo
      --join              Join the domain after installing
      --no-join           Install only; never attempt a join
      --open-firewall     Allow Cockpit (9090/tcp) through the firewall
      --no-open-firewall  Leave the firewall alone
  -y, --yes               Non-interactive; accept every recommended default
  -n, --dry-run           Print what would happen without changing anything
  -l, --list              Show the packages for this system and exit
  -h, --help              Show help
      --version           Print the version
```

### Examples

```bash
# Interactive — detect the system and ask what to install
sudo ./domain-join-setup.sh

# See exactly what would happen, change nothing
sudo ./domain-join-setup.sh --dry-run

# Just show the package list for this machine
./domain-join-setup.sh --list

# Unattended install and join (Kubuntu / Fedora KDE)
sudo ./domain-join-setup.sh -y -b sssd -g cockpit \
     -e mkhomedir,timesync,shares -d corp.example.com -u svc-join --join
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

---

## KDE Plasma note

Once the machine is joined, **domain logins work normally through SDDM** — pick
"Other" and type the domain username. KDE's System Settings has no Active
Directory module, so use Cockpit or the `realm` command for join and membership
management.

### Putting the domain user back on the login screen

Out of the box the greeter shows local accounts only, so every domain login
starts with a trip through "Other". Two things cause that:

1. SDDM builds its user list with `getpwent()`, and SSSD deliberately answers
   that with local accounts only — enumerating a directory is expensive, so it
   is off by default.
2. AD accounts get algorithmic UIDs in the millions, well past the greeter's
   default `MaximumUid=60000`.

The fix is *not* to enumerate the domain. SDDM 0.20 added a per-theme
`needsFullUserModel` flag: set it to `false` and the greeter skips the
enumeration entirely, resolving just the last user from
`/var/lib/sddm/state.conf` with a single `getpwnam()` — which SSSD answers
without complaint. On an issued workstation that gives the Windows behaviour,
where the owner sees their own name and types only a password.

When SDDM is the active display manager, the installer offers to write:

```ini
# /etc/sddm.conf.d/10-domain-users.conf
[Users]
MinimumUid=1000
MaximumUid=2000200000        # top of the sssd.conf ldap_idmap_range
RememberLastUser=true
```

```ini
# /usr/share/sddm/themes/<theme>/theme.conf.user
[General]
needsFullUserModel=false
```

`theme.conf.user` is SDDM's own override file, so the packaged `theme.conf` is
never touched and the setting survives a Plasma upgrade. Both files take effect
at the next login screen — **do not** restart `sddm` from inside a running
session. The first domain login still goes through "Other"; the account is
remembered from then on, exactly as a fresh Windows machine behaves.

On SDDM older than 0.20 the installer writes the UID drop-in, says so, and
leaves the rest alone. The fallback there is `enumerate = true` in `sssd.conf`
paired with an `ldap_user_search_base` scoped to a single OU, so the greeter
gets a short list instead of the whole directory.

---

## Verifying

```bash
realm list                          # membership and login policy
id someuser@corp.example.com        # does the directory resolve?
kinit someuser@CORP.EXAMPLE.COM     # get a Kerberos ticket
klist                               # inspect it
sudo systemctl status sssd
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
detection, argument parsing and CLI exit codes.

## License

MIT
