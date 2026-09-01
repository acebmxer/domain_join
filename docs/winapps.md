# Windows applications for every domain user

[← back to the README](../README.md)

[WinApps](https://github.com/winapps-org/winapps) makes individual Windows
programs appear as ordinary entries in the Linux application menu, launched over
RDP against a Windows instance. This page covers what it takes to make that
work for *every* domain user rather than for one account.

## Flags

```
      --winapps           Set up WinApps for all users (same as -e winapps)
      --no-winapps        Never set up WinApps, whatever the extras say
      --winapps-vm NAME   Windows VM name (default RDPWindows)
      --winapps-libvirt-group G
                          AD group given read-write libvirt / virt-manager
                          (default: the realm's permitted-logins group)
      --winapps-libvirt-restrict, --no-...
                          Gate read-write qemu:///system through polkit
                          (default: on when a group is named)
      --winapps-launcher-readonly, --no-...
                          Shared launchers reach libvirt read-only, so every
                          domain user can launch apps (default: on)
      --winapps-vm-autostart, --no-...
                          'virsh autostart' the guest (default: on)
      --winapps-domain D  RDP_DOMAIN (default: the realm this machine joined)
      --winapps-creds M   askpass | shared
      --winapps-user USER Windows service account, 'shared' mode only
      --winapps-remove    Remove the multi-user wiring
      --winapps-vm-remove With --winapps-remove, also delete the libvirt guest
      --winapps-deploy    Build the Windows 11 VM
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

The shared-mode WinApps password is read from `WINAPPS_RDP_PASS` in the
environment, and the built VM's local administrator password from
`WINAPPS_VM_PASS` (a random one is generated and printed once if unset).

## The problem this solves

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

## How it works here

One root-owned template, expanded per user at login:

```
/etc/winapps/winapps.conf.template     the master copy - the only file you edit
/usr/local/bin/winapps-user-config     generates ~/.config/winapps/winapps.conf
/usr/local/bin/winapps-askpass         supplies the password to FreeRDP
/etc/profile.d/winapps-user-config.sh  runs the generator for shell/SSH logins
/etc/xdg/autostart/winapps-user-config.desktop   ...and for graphical ones
/etc/skel/.config/winapps/winapps.conf covers the very first login
/usr/local/bin/winapps-vm-deploy       builds the Windows VM
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

## Where Windows runs

A **local Windows VM under libvirt/KVM**, joined to the domain in its own right,
so each user's profile, GPOs and mapped drives come from AD exactly as on a
physical box. The script installs the virtualisation stack, builds the guest for
you if you want ([Building the VM](#building-the-vm)), and wires up the per-user
launchers.

WinApps upstream also supports Docker/Podman containers (`dockur/windows`) and
pointing at an existing remote RDP host. This installer does **not** offer those:
the containers it would not domain-join, and a remote/RDS host is a separate
piece of infrastructure. If you want one of those, install WinApps by hand — this
tool is specifically "join *this* workstation and give it a local Windows VM."

## Building the VM

The script can stand up the Windows guest itself (`--winapps-deploy`, or answer
yes when it offers). It installs a `winapps-vm-deploy` helper and runs it:

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

The helper brings libvirt up before it builds. Fedora, RHEL and their rebuilds
split libvirt into a daemon per driver (`virtqemud`, `virtstoraged`,
`virtnetworkd`) that only starts once its socket unit is listening — so on a
freshly installed libvirt that has not been rebooted, `virt-install` fails with
`Failed to connect socket to '…/virtstoraged-sock'`. The helper starts those
sockets (or the monolithic `libvirtd`) and checks the storage and network
drivers answer before doing any multi-GB ISO work.

### Docker on the same host

Docker's default firewall setup sets the `FORWARD` chain policy to `DROP` and
adds no exception for a libvirt NAT network. The Windows guest then gets a DHCP
lease (that traffic goes to the host and is never forwarded) but no routed
packet reaches the internet — the fault looks like broken DNS. libvirt's own
accept and masquerade rules live in a separate nftables table and cannot undo
Docker's `DROP`.

When it sees Docker installed with its iptables driver active, the WinApps step
offers to install `libvirt-docker-forward.service` — a one-shot unit, ordered
`After=` and `PartOf=` `docker.service`, that adds an `ACCEPT` for the libvirt
bridge (`virbr0` unless renamed) to Docker's `DOCKER-USER` chain. Docker
recreates that chain empty on every daemon start, so the unit re-applies the
rule each time; a matching permanent firewalld direct rule covers
`firewall-cmd --reload`, which makes Docker rebuild its chains too. Declining
the prompt leaves the firewall untouched — the guest just has no outbound
network while Docker is running. `--winapps-remove` disables the unit and drops
the firewalld rule.

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

### The account inside the guest

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

### Who can launch apps, and who can drive the VM

A domain-joined workstation needs two different things from libvirt:

- **every domain user** must be able to launch the Windows apps (Outlook, Word,
  …). Upstream WinApps refuses to run unless the user is in the local `libvirt`
  and `kvm` groups, and a domain account is in neither — `usermod -aG` for each
  one does not scale to a directory.
- **only some people** should be able to start, stop or reconfigure the guest
  in Virtual Machine Manager.

This installer splits them:

- **Launching apps** — the shared launchers reach libvirt **read-only**. A block
  appended to the config template (which the WinApps launcher `source`s)
  overrides its libvirt helpers: the `libvirt`/`kvm` group check is dropped, and
  the "is it up?" and address-lookup calls use `virsh -r` against the
  read-only socket, which is open to every local user by default on every
  supported distro. Nothing to add anyone to. `winapps_launcher_readonly = no`
  turns this off and restores the upstream behaviour.
- **Driving the VM** — `virt-manager` needs read-write `qemu:///system`. The
  RW socket is opened so the request reaches polkit
  (`unix_sock_rw_perms = "0777"`, plus a `SocketMode=0777` drop-in for
  socket-activated builds), `/etc/polkit-1/rules.d/49-domain-join-libvirt.rules`
  grants `org.libvirt.*` to one AD group, and — because Debian and Ubuntu ship
  `auth_unix_rw = "none"`, which would ignore that rule and hand every local
  user full control — `libvirt_restrict` sets `auth_unix_rw = "polkit"` so the
  rule is actually consulted. It is skipped, with a warning, where polkit is
  too old for JavaScript rules (pre-0.106; it would lock `qemu:///system` to
  root). The group comes from the prompt (defaulting to the realm's
  `permitted-groups`), `--winapps-libvirt-group 'Domain Admins'`, or a
  `libvirt_group` line in [`windows-vm.conf`](#windows-vmconf); blank skips it
  and RW access stays with the local `libvirt` group. You can spell it however
  `id` shows it — the rule is written to match the short name (`Domain Admins`),
  the fully-qualified name (`Domain Admins@corp.example.com`), the `DOMAIN\`
  form, their lower-cased variants and the numeric GID, so it works whether or
  not SSSD uses fully-qualified names on this machine. `root` is always allowed.
  Group membership is read at login, so a member already signed in must log out
  and back in.

So that a read-only user is never stuck waiting for a stopped guest,
`winapps_vm_autostart` has libvirt start it when the host boots.

### `windows-vm.conf`

The answers the unattended install needs can be written down once instead of
retyped every build:

```bash
./domain-join-setup.sh --write-vm-config
```

writes a commented `windows-vm.conf` next to the script, **mode `0600`** because
it can hold the administrator password. A blank copy is committed here as
[`windows-vm.conf.example`](../windows-vm.conf.example) — `cp` it if you prefer,
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

# WinApps access — not build answers
libvirt_group             = Domain Admins
libvirt_restrict          = yes
winapps_launcher_readonly = yes
winapps_vm_autostart      = yes
```

Everything between the sizing block and the WinApps access section goes straight
into `Autounattend.xml`:

| Setting | Unattend setting | Default |
|---|---|---|
| `edition` | `/IMAGE/NAME` | Windows 11 Pro |
| `product_key` | `ProductKey` | the generic Pro key |
| `computer_name` | `ComputerName` | `*` — Setup generates one |
| `admin`, `password` | `LocalAccount`, `AutoLogon` | `winadmin`, random |
| `owner` | `RegisteredOwner` | omitted |
| `organization` | `RegisteredOrganization` | omitted |
| `timezone` | `TimeZone` | `UTC` |
| `ui_language` | `SetupUILanguage`, `UILanguage` | `en-US` |
| `system_locale` | `SystemLocale` | follows `ui_language` |
| `user_locale` | `UserLocale` | follows `ui_language` |
| `input_locale` | `InputLocale` | `0409:00000409` |

The last four are **not** build answers — they decide who, on this machine, may
launch the Windows apps and who may drive the guest
([above](#who-can-launch-apps-and-who-can-drive-the-vm)):

| Setting | What it does | Default |
|---|---|---|
| `libvirt_group` | AD group given **read-write** libvirt (the start/stop/reconfigure `virt-manager` does). Blank grants nobody and skips the prompt; omitting the line keeps the prompt. | realm's permitted-groups |
| `libvirt_restrict` | Switch `auth_unix_rw` to `polkit` so only `libvirt_group` gets read-write in — without it, Debian and Ubuntu trust the socket and the grant does nothing. | `yes` when a group is named |
| `winapps_launcher_readonly` | Shared launchers reach libvirt **read-only**, so every domain user launches apps with no local group. Off restores upstream WinApps' `usermod -aG libvirt,kvm` requirement. | `yes` |
| `winapps_vm_autostart` | `virsh autostart` the guest so the host powers it. | `yes` |

`winapps-vm-deploy` reads the same file and ignores these four.

That is the whole vocabulary. Anything else is an error naming the file and
line, not a setting quietly ignored. Apart from the WinApps access block, **this
file covers the VM build and nothing else**; the domain join, Duo, sudo and
package selection stay on the flags and the menu where they were.

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
| **shared** | Everyone connects as one service account. Appropriate for a kiosk; on a multi-user machine it defeats the domain join, because all users land in one Windows profile and the directory cannot tell them apart. |

Kerberos single sign-on is **not** an option. WinApps reaches the libvirt guest
by its NAT IP address, and Kerberos cannot issue a service ticket for an IP — so
FreeRDP falls back to NLA-over-NTLM, which needs a password anyway. Making SSO
work would require pinning the guest to a stable address, resolving its AD name
from the host, and connecting FreeRDP by that name; that is out of scope for this
installer.

### Order of operations

The launchers are built by scanning the Windows side for installed programs, so
Windows has to exist first:

1. Install Linux and **join it to the domain** — WinApps reads the joined realm
   to fill in `RDP_DOMAIN`.
2. Run this script's WinApps step. It installs FreeRDP and the virtualisation
   stack, writes the template, generator and login hooks, seeds existing
   accounts, grants an AD group access to `qemu:///system`
   ([above](#who-can-launch-apps-and-who-can-drive-the-vm)), fixes libvirt
   forwarding if Docker is in the way
   ([above](#docker-on-the-same-host)), and offers to
   **build the Windows VM** ([above](#building-the-vm)).
3. **Join Windows to the domain.** The script never does this — not even for a
   VM it built.
4. Scan Windows for installed programs to create the launchers:
   `sudo /etc/winapps/setup.sh --system`. Afterwards, whenever a program is
   added to Windows, refresh the launchers with
   `sudo /etc/winapps/setup.sh --system --add-apps` (or the **Scan Windows for
   installed apps** menu entry, which picks the right one). Plain `--system`
   aborts once WinApps is installed.

   The scan runs as root. The account prompt defaults to the guest's **local**
   administrator (`admin` in `windows-vm.conf`, or `winadmin` if that file was
   not read); accepting that default signs in locally, and if the build
   generated a random password it asks for one. Typing **any other name** makes
   it an **Active Directory** account, and the next prompt asks for its domain,
   defaulting to the realm this host is joined to. An AD account must have local
   Administrator rights on the guest — AD does not grant those on its own; put
   an AD group (for example the one in `libvirt_group`) into the guest's local
   Administrators, e.g. with a GPO. It connects with
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
sudo /etc/winapps/setup.sh --system --add-apps  # re-scan Windows for new apps
sudo winapps-vm-deploy --force                 # rebuild the Windows VM (libvirt)
sudo ./domain-join-setup.sh --winapps-remove   # take the wiring back out
sudo ./domain-join-setup.sh --winapps-vm-remove # ...and delete the libvirt guest
```

New apps installed in Windows need one re-scan on the machine
(`setup.sh --system --add-apps`); new *users* need nothing at all — they are
configured the moment they log in.
