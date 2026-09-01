# domain-join-setup

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/tag/acebmxer/domain_join?label=version&sort=semver&color=brightgreen)](CHANGELOG.md)
[![Last commit](https://img.shields.io/github/last-commit/acebmxer/domain_join)](https://github.com/acebmxer/domain_join/commits)
[![Issues](https://img.shields.io/github/issues/acebmxer/domain_join)](https://github.com/acebmxer/domain_join/issues)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](domain-join-setup.sh)
[![Platform: Linux](https://img.shields.io/badge/platform-linux-333333?logo=linux&logoColor=white)](#supported-systems)
[![Tests](https://img.shields.io/badge/tests-517-informational)](tests/run-tests.sh)

An interactive installer that sets up everything a Linux workstation needs to
join and live on an **Active Directory** domain — on multiple distributions and
under any desktop environment. It installs the same backend GNOME uses (SSSD +
realmd) and pairs it with a graphical front end that works regardless of desktop:
the Cockpit web console, whose Overview page has a realmd-driven **Join domain**
dialog. This is the gap it closes — GNOME has Enterprise Login built in; KDE
Plasma, Xfce, LXQt and Cinnamon have nothing equivalent.

```bash
git clone https://github.com/acebmxer/domain_join.git
cd domain_join
sudo ./domain-join-setup.sh
```

Run with no options and you get a menu of everything the script can do. Every
step is also a flag, for unattended runs.

## Read next

| Topic | Page |
| --- | --- |
| Granting `sudo` to a user or AD group | [docs/sudo.md](docs/sudo.md) |
| Duo two-factor authentication | [docs/duo.md](docs/duo.md) |
| Windows apps for every domain user (WinApps + the VM builder) | [docs/winapps.md](docs/winapps.md) |
| Domain users on the SDDM / KDE login screen | [docs/sddm-user-list.md](docs/sddm-user-list.md) |
| Short usernames and the SSSD cache | [docs/short-usernames.md](docs/short-usernames.md) |
| Tests and releases | [docs/development.md](docs/development.md) |

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
```

Arrow keys move, **SPACE** ticks an entry, **ENTER** runs everything ticked, **D**
toggles dry-run, **Q** or **Esc** quits without changing anything. Tick several
entries and they run in a sensible order — packages, then configuration, then the
join, then the settings that only apply to a domain member. The menu needs a
40x23 terminal and reflows as the window resizes; below the minimum it says so
rather than drawing something broken.

| Entry | What it runs |
| --- | --- |
| **Guided setup** | The whole thing: pick a backend, GUI tools and extras, install, configure, then offer to join. This is what the flags drive when you skip the menu. |
| **Install packages only** | The same choices and install, but nothing configured and no service enabled. |
| **Graphical management tools** | Just the GUI front ends — Cockpit, GNOME Enterprise Login, YaST or ADSys, whichever apply. |
| **Join an Active Directory domain** | `realm discover`, `realm join`, then the post-join login settings. |
| **Home directories on first login** | Wires up `pam_mkhomedir` the way this distro expects. |
| **Network time synchronisation** | Enables `chronyd` or `systemd-timesyncd` and turns on NTP. |
| **SDDM login screen** | Puts the last domain user back on the greeter as a tile — see [docs/sddm-user-list.md](docs/sddm-user-list.md). |
| **Post-join login settings** | Short usernames, who may log in, then sudo rights. |
| **Grant sudo to a user or group** | An account, a group, or one of each; one `/etc/sudoers.d` drop-in per grant — see [docs/sudo.md](docs/sudo.md). |
| **Duo two-factor authentication** | Installs Duo Unix and adds `pam_duo.so` to the services you pick — or takes it back out — see [docs/duo.md](docs/duo.md). |
| **Windows apps for every user** | Installs WinApps system-wide, generates each domain user's config at login, and can build the Windows 11 VM — see [docs/winapps.md](docs/winapps.md). |
| **Scan Windows for installed apps** | Re-runs the WinApps program scan on its own, for whenever a program is added to Windows. |
| **Preflight checks and domain status** | Read-only: hostname, clock, DNS SRV records, membership and service state. |

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

Full support — SSSD + Cockpit GUI — is targeted at **Ubuntu/Kubuntu with KDE**
and the **Fedora KDE Spin**. On GNOME (Ubuntu or Fedora) the script offers
GNOME's own native Enterprise Login instead.

---

## The choices it presents

### Authentication backend

| Choice | Description |
| --- | --- |
| **SSSD + realmd + adcli** *(recommended)* | The modern standard used by Fedora, RHEL and Ubuntu. Kerberos SSO, cached credentials for offline logins, AD-to-POSIX ID mapping, one-command joins via `realm join`. |
| **Samba Winbind** | Samba's own AD client. Pick this if the machine is also a Samba file server, if you need Windows RID-based UID/GID mapping, or for an old NT4-style domain. |
| **Both** | SSSD handles logins; Winbind tooling stays available for Samba shares and `net ads` troubleshooting. |

### Graphical management tools

Only the entries valid for your system are shown.

| Choice | Shown on | Description |
| --- | --- | --- |
| **Cockpit web console** | Everything | Browser UI at `https://localhost:9090`; Overview page has a **Join domain** button. The practical GUI for KDE, Xfce, LXQt and headless boxes. |
| **GNOME Settings — Enterprise Login** | GNOME, Cinnamon, Budgie | GNOME's native AD integration in the Users panel. |
| **YaST — User Logon / Domain Membership** | openSUSE / SLE | openSUSE's own graphical admin modules for SSSD and Winbind. |
| **Ubuntu ADSys** | Ubuntu and derivatives | Applies AD **Group Policy Objects** to the Ubuntu desktop. Full GPO support needs Ubuntu Pro; the package works without it. |
| **No GUI** | Everything | Command line only — `realm`, `adcli`, `net ads`. |

### Supporting components

| Choice | Default | Description |
| --- | --- | --- |
| **Create home directories on first login** | on | Without it a domain user logs in with no home directory and most desktop sessions fail to start. |
| **Enforce network time sync** | on | Kerberos rejects tickets with more than ~5 minutes of clock skew — the most common cause of a failed join. |
| **Diagnostic tools** | on | `dig`, `ldapsearch`, `kinit` for checking SRV records, querying the directory and testing tickets. |
| **Access to Windows file shares** | off | `cifs-utils` + `smbclient`, including Kerberos-authenticated mounts. |
| **SSSD sudo rules from the directory** | off | Lets `sudo` read sudoers rules *published in AD*. Not the same as [granting sudo here](docs/sudo.md), which writes a rule on this machine. |
| **Duo two-factor authentication** | off | A second factor in front of logins, local *and* domain — see [docs/duo.md](docs/duo.md). |
| **Windows applications (WinApps)** | off | Windows programs in the Linux app menu, per domain user — see [docs/winapps.md](docs/winapps.md). |

---

## Usage

```
sudo ./domain-join-setup.sh [options]

      --menu / --no-menu   Force the menu / skip it and run the guided setup
  -d, --domain DOMAIN      Active Directory domain (e.g. corp.example.com)
  -u, --user USER          Domain account used to perform the join
  -b, --backend NAME       sssd | winbind | both
  -g, --gui LIST           cockpit,gnome,yast,adsys,none
  -e, --extras LIST        mkhomedir,timesync,troubleshoot,shares,sudo,duo,winapps
      --sudo-user LIST     Grant sudo to these accounts (comma separated)
      --sudo-group LIST    Grant sudo to these groups (comma separated)
      --join / --no-join   Join the domain after installing / install only
      --open-firewall      Allow Cockpit (9090/tcp) through the firewall
  -y, --yes                Non-interactive; accept every recommended default
  -n, --dry-run            Print what would happen without changing anything
  -l, --list               Show the packages for this system and exit
  -h, --help               Full option list, including all Duo and WinApps flags
      --version            Print the version
```

The Duo and WinApps steps add many more flags — run `--help` for the full list,
or see [docs/duo.md](docs/duo.md) and [docs/winapps.md](docs/winapps.md).
Secrets are read from the environment rather than a flag so they stay out of
`ps`: `DUO_SKEY`, `WINAPPS_RDP_PASS`, `WINAPPS_VM_PASS`.

Any option that says *what to do* skips the menu and runs the guided setup.
`--dry-run` and `--list` work without root.

```bash
# The menu (add --dry-run to open it with dry-run already on)
sudo ./domain-join-setup.sh

# Just show the package list for this machine
./domain-join-setup.sh --list

# Unattended install and join
sudo ./domain-join-setup.sh -y -b sssd -g cockpit \
     -e mkhomedir,timesync,shares -d corp.example.com -u svc-join --join

# Grant sudo to a domain group and one account, no prompts
sudo ./domain-join-setup.sh -y --sudo-group 'Linux Admins@corp.example.com' \
     --sudo-user jdoe
```

---

## What it does after installing

1. **Time sync** — enables `chronyd` or `systemd-timesyncd` and turns on NTP.
2. **Home directories** — enables `pam_mkhomedir` using the right mechanism for
   the distro.
3. **Services** — enables `sssd` (not started, since it has no valid config
   until the join creates one), plus `cockpit.socket` and `adsys` if selected.
4. **Firewall** — only if you say yes, opens 9090/tcp for Cockpit. Declining
   still leaves Cockpit usable at `https://localhost:9090`.
5. **Preflight checks** — FQDN hostname, clock sync, DNS SRV records.
6. **Duo 2FA**, if selected — runs *last*, because it is the only step that can
   leave a machine unable to authenticate.

If you let it join, it runs `realm discover`, then `realm join`, then offers
short usernames, an SDDM greeter tweak, a login-access group (safer than
exposing every account in the directory), and sudo rights. Every file it edits
is backed up first as `<file>.domain-join-setup.<timestamp>.bak`.

> Turning on **short usernames** wipes the SSSD cache, so the next domain login
> has to reach a domain controller. It also needs home-directory creation on, or
> the session dies on a missing `$HOME`. Details:
> [docs/short-usernames.md](docs/short-usernames.md).

### KDE Plasma

Domain logins work normally through SDDM — pick "Other" and type the domain
username. KDE's System Settings has no Active Directory module, so use Cockpit or
`realm` for join and membership management. The optional greeter tweak that puts
the last domain user back as a named tile is in
[docs/sddm-user-list.md](docs/sddm-user-list.md).

---

## Verifying

```bash
realm list                          # membership and login policy
id someuser@corp.example.com        # does the directory resolve?
kinit someuser@CORP.EXAMPLE.COM     # get a Kerberos ticket
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
| Login screen lists local users only | SDDM enumerates local accounts and caps UIDs at 60000. See [docs/sddm-user-list.md](docs/sddm-user-list.md). |
| A sudo grant seems to do nothing | The rule names something NSS doesn't resolve. `getent group "Linux Admins"` and `getent group "Linux Admins@<domain>"` — use whichever answers. |
| A group member still can't use sudo | Group membership is read at login. Log out and back in, then `id` to confirm. |
| `sudo` refuses to run at all | A syntax error in `/etc/sudoers.d`. Recover with `pkexec visudo` or a root console. |
| Duo is configured but never asks | The rule sits after a `sufficient` that already succeeded, or `pam_duo.so` isn't on PAM's search path. See [docs/duo.md](docs/duo.md). |
| Locked out after enabling Duo | Log in on a text console as a member of the bypass group, then `sudo sed -i '/pam_duo.so/d' /etc/pam.d/*`. |
| A WinApps app won't launch: "not part of group 'libvirt' and/or 'kvm'" | The read-only launcher block is missing from `~/.config/winapps/winapps.conf`. Re-run the WinApps step, then log out and back in. See [docs/winapps.md](docs/winapps.md). |
| virt-install: `Failed to connect socket to '…/virtstoraged-sock'` | libvirt's modular daemons aren't started. Re-run the builder (it now starts them), or `sudo systemctl start virtstoraged.socket`. |
| virt-manager: `Failed to connect socket to '…/libvirt-sock': Permission denied` | This user has no read-write libvirt. Re-run the WinApps step with `--winapps-libvirt-group '<AD group>'`, or `sudo usermod -aG libvirt <user>`. |

A full log of every action is written to `/var/log/domain-join-setup.log`.

---

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 acebmxer.
