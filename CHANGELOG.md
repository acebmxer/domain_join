# Changelog

All notable changes to `domain-join-setup` are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version that a checkout believes it is comes from `SCRIPT_VERSION` near the
top of `domain-join-setup.sh`, and `./domain-join-setup.sh --version` prints it.
Each released version below has a matching annotated git tag on the commit where
that version stopped being edited, so `git show v1.3.0:domain-join-setup.sh`
prints a script whose own `--version` agrees with the tag.

Because there is no packaging step, "released" here means the version stamp
changed — not that an artefact was published anywhere.

## [Unreleased]

### Removed

- **WinApps is libvirt-only now.** The `docker`, `podman` and `manual` backends
  are gone, along with `--winapps-backend`, `--winapps-host` and
  `--winapps-port`. The containers this tool would never domain-join, and a
  remote/RDS host is separate infrastructure — neither fits "join *this*
  workstation and give it a local Windows VM," which is all this installer does.
  `WAFLAVOR` in the generated template is always `libvirt`; RDP port is 3389
  (change it in the template if the guest uses another). WinApps upstream still
  supports all of them for a hand install.

### Changed

- **The built-in VM local-administrator account is `winadmin`, not `Docker`.**
  The old default was a leftover from upstream WinApps and did not match the
  name the example config and docs already used. Set `admin =` in
  `windows-vm.conf` (or `--winapps-vm-user`) to override, same as before. Only
  affects VMs built from here with no account name given.

- **Every domain user can launch the Windows apps out of the box.** The libvirt
  backend now assumes what a domain workstation actually needs: Outlook, Word
  and the rest are for everyone who logs in, and read-write libvirt — the
  start/stop/reconfigure that `virt-manager` does — is the restricted thing.

  Three settings, all in `windows-vm.conf` (and as flags), each on by default:

  - **`winapps_launcher_readonly`** — the shared launchers now reach libvirt
    **read-only**. A block appended to the WinApps config template (which the
    launcher `source`s) overrides its three libvirt helpers: the
    `libvirt`/`kvm` group check is dropped, and status and IP-discovery calls
    use `virsh -r` against the always-open read-only socket. No domain user
    needs `usermod -aG libvirt,kvm` any more. Turn it off to get upstream
    WinApps' behaviour back.
  - **`libvirt_restrict`** — on Debian and Ubuntu, libvirt trusts the socket
    rather than polkit (`auth_unix_rw = "none"`), so the `libvirt_group` polkit
    rule was never consulted and *every* local user could drive the guest. When
    a group is named this now sets `auth_unix_rw = "polkit"` so the rule bites;
    the read-only socket stays open. Skipped, with a warning, on a polkit too
    old for JS rules (it would lock `qemu:///system` to root).
  - **`winapps_vm_autostart`** — `virsh autostart` the guest, so a user who
    only has read-only libvirt never needs to start it.

  New flags: `--winapps-libvirt-restrict` / `--no-`,
  `--winapps-launcher-readonly` / `--no-`, `--winapps-vm-autostart` / `--no-`.
  `--winapps-libvirt-group` and `libvirt_group` are unchanged in spelling but
  now grant read-write access specifically.

- **The `libvirt_group` polkit rule matches every name form.** It used to be a
  single exact `isInGroup("Domain Admins")`, which failed where NSS returns
  `domain admins@corp.example.com` (SSSD fully-qualified names), `domain admins`
  (lower-cased), or `CORP\domain admins` (Winbind). The rule now tries all of
  them plus the group's numeric GID, so the operator does not need to know which
  form this machine uses. `root` is always allowed. The setup step reports
  whether the group resolves and at which GID.

### Fixed

- **Re-scanning Windows for installed apps works.** The scan re-ran the upstream
  installer as `setup.sh --system`, which aborts with "EXISTING 'SYSTEM'
  WINAPPS INSTALLATION" (exit 3) once WinApps is installed — so a re-scan after
  installing a program never completed. `winapps_install_upstream` now runs
  `setup.sh --system --add-apps` when a system install is already present
  (`/usr/local/bin/winapps` exists), and plain `--system` only for the first
  install. `--add-apps` re-runs the Windows program scan and refreshes the
  launchers; it does not prune launchers for programs removed from Windows —
  for that, `setup.sh --system --uninstall` then `setup.sh --system`.

  Upstream's own `--add-apps` existing-install check is broken for a normal
  layout (it tests for a `winapps` directory inside the source tree that is
  never created), so it would report "NO EXISTING WINAPPS INSTALLATION". The
  fetched installer is corrected in place before it runs; a no-op once upstream
  fixes it.

## [1.5.0] — 2026-08-30

A dedicated menu entry for re-scanning the Windows guest for installed apps,
`libvirt_group` moved into `windows-vm.conf`, and the round of fixes that stops
the WinApps teardown and program scan tripping over `sudo`, the guest's domain
certificate and stray removal flags.

### Added

- **"Scan Windows for installed apps" on the menu.** The WinApps program scan
  (`setup.sh --system`, which enumerates what is installed in Windows and
  rewrites the shared launchers) is now a menu entry of its own, next to
  "Windows apps for every user". It is the same command for the first scan and
  every re-scan, so run it whenever a program is added to or removed from
  Windows. The install entry still does the scan at the end of its own run; the
  new entry no-ops if that already happened in the same batch, and tells you to
  run the install step first if WinApps was never set up. The menu's minimum
  terminal height moves from 40x22 to 40x23.
- **`libvirt_group` in `windows-vm.conf`.** The AD group given `virt-manager`
  access to the Windows guest — previously only a prompt or the
  `--winapps-libvirt-group` flag — can now be written in the answer file. It is
  the one setting in that file that is not part of the VM build; the file's
  header and `--write-vm-config` sample say so. A `--winapps-libvirt-group` flag
  still overrides it. Setting it to an explicit blank (`libvirt_group =`) means
  "grant nobody, don't ask"; leaving the line out keeps the interactive prompt.
  The `winapps-vm-deploy` helper reads the same file and now skips the key
  instead of aborting on an unknown setting.
- **`windows-vm.conf` — answers for the unattended Windows install.** The
  edition, product key, computer name, locale settings and the local
  administrator account and password now come from a config file instead of
  being fixed in the script. Driven by `--write-vm-config`, `--vm-config` and
  `--no-vm-config`, with precedence **flags > `WINAPPS_VM_PASS` > file >
  defaults**. The Windows local account name is validated against the
  characters Windows refuses, and every value is XML-escaped on its way into
  `Autounattend.xml`. A blank `windows-vm.conf.example` is committed and the
  filled-in `windows-vm.conf` is gitignored, so a real password never reaches
  GitHub. Tests cover the parser, the precedence rules and the rendered answer
  file. (`98d015a`)
- **This changelog, and versioning for the project.** `CHANGELOG.md` records
  every release back to the first commit, and annotated git tags `v1.0.0`,
  `v1.2.0`, `v1.3.0` and `v1.4.0` were backfilled onto the commit where each
  version stamp stopped being edited, so a tag and the `SCRIPT_VERSION` in the
  script it points at always agree. A `Releases` section in the README explains
  what the version numbers mean and how a release is cut.
- **`LICENSE`.** The README had said MIT since the first commit without a
  license file to back it, so the repository showed no license at all. Full MIT
  text, Copyright (c) 2026 acebmxer.
- **Badges in the README** — license, version, last commit, open issues, shell,
  platform and the test count.
- **The WinApps libvirt backend now grants domain users access to
  `qemu:///system`.** A domain account is in no local group, so
  `virt-manager` was refused at `/run/libvirt/libvirt-sock` with a bare
  "Permission denied" — before polkit was ever consulted — the first time
  anyone logged in from the directory. The step now opens the RW socket to
  every local user (via both `unix_sock_rw_perms` in the daemon config and a
  `SocketMode` drop-in on the `.socket` units, since socket-activated builds
  ignore the former) and writes `/etc/polkit-1/rules.d/49-domain-join-libvirt.rules`
  granting `org.libvirt.*` to one AD group with no password. The group is
  asked for — defaulting to the realm's `permitted-groups` — or set with
  `--winapps-libvirt-group`; blank skips the whole thing. Authorisation still
  runs through polkit; deleting the rule file revokes it.
- **The WinApps step tidies up the guest's install CD drives.** The build
  attaches three CD-ROMs — the install ISO, the virtio drivers and the unattend
  answer disk. After you confirm Windows is installed and reachable, the step
  ejects the medium from every drive (live, so the ISOs drop off the running
  guest at once) and removes two of the three drives from the domain definition
  (`virsh detach-disk --config` — libvirt refuses to hot-unplug a CD-ROM, so the
  empty drive letters linger until the guest is fully powered off), leaving one
  CD-ROM for mounting an ISO by hand later. It then offers to power-cycle the
  guest there and then to finish the removal (`virsh shutdown`, wait, `start`);
  decline and it clears at the next full shutdown as before. libvirt backend
  only; `-y` skips the power-cycle prompt and prints the manual commands.

### Changed

- **The VM builder stops re-asking for RAM, vCPUs and disk when the answer is
  already in `windows-vm.conf`.** A value set in the file (or by
  `--winapps-vm-ram` / `-cpus` / `-disk`) is now taken as the answer, the way
  `iso`, `admin` and `password` already were; only the settings left at their
  built-in default still prompt.
- **`timezone` defaults to UTC when nothing sets it.** The unattended install
  previously wrote no `<TimeZone>` at all and inherited whatever the install
  media defaulted to; it now always writes one, so a build without a `timezone`
  line lands on UTC rather than an unpredictable zone. An empty `timezone =` in
  `windows-vm.conf` is rejected with a message pointing at either a real value
  or removing the line.

### Fixed

- **`--winapps-remove` and `--winapps-vm-remove` ran the whole installer first.**
  Neither flag routed straight to the teardown: they only suppressed the menu, so
  the script fell into the guided setup and prompted for an Active Directory
  backend, previewed and installed packages, and offered to join a domain before
  `winapps_remove` finally ran at the tail of `configure_winapps`. `main` now
  short-circuits to `winapps_remove` as soon as either flag is seen and stops
  there.
- **The removal hint printed the wrong uninstall command.** It suggested
  `sudo /etc/winapps/setup.sh --uninstall`, but upstream `setup.sh` refuses
  `--uninstall` without `--user` or `--system`; since the installer only ever
  runs `--system`, the hint now reads `setup.sh --system --uninstall`.
- **The WinApps program scan tried to log into Windows as `root`.** When the
  installer ran `setup.sh --system` under `sudo`, it seeded root's
  `~/.config/winapps/winapps.conf` from the per-user template — which carries a
  `RDP_USER` placeholder, `RDP_DOMAIN` set to the realm and (in Kerberos mode)
  `/sec:nla` — and the password helper's dialog was labelled *"Active Directory
  password for root"*. There is no `root` account in the directory, so the scan
  could never authenticate, and a stale copy from an earlier run was never
  refreshed. The scan now connects as the guest's **local** administrator (the
  `admin` / `password` from `windows-vm.conf`), with no domain and no Kerberos
  NLA — an account that exists whether or not Windows is domain-joined. The
  password goes into a root-only askpass helper, never `RDP_PASS`, so it is
  never a `/p:` argument in `ps` or the WinApps log; with no password in the
  config the scan asks for one. Domain-user sign-in is unchanged.
- **The WinApps program scan aborted at the TLS handshake once the guest was
  domain-joined.** The guest's self-signed RDP certificate is regenerated when
  its hostname changes — which happens the moment it joins the domain (the CN
  goes from `HOST` to `HOST.realm`). FreeRDP's `/cert:tofu` then sees a
  *changed* host key, refuses it and prompts — but the scan has no terminal, so
  it died with `ERRCONNECT_TLS_CONNECT_FAILED` before authentication was even
  attempted. The scan's copy of `winapps.conf` now uses `/cert:ignore` for that
  one connection (the per-user template keeps `/cert:tofu`), and any host key a
  previous attempt pinned under `/root/.config/freerdp/server/` is cleared
  first.
- The menu banner in the README was one column too wide: the title row's
  interior measured 82 characters against an 81-character `╔═╗` border, so the
  closing `║` sat one place past the corner. The README now uses the same
  padding arithmetic the script does, which puts the odd column on the right.
- The test suite's "every drawn line fits the terminal" check measured line
  width with `awk`, which on systems where `awk` is `mawk` counts bytes rather
  than characters and reported the menu's box-drawing borders as three times
  their real width. It now counts display columns and passes on `mawk`.

## [1.4.0] — 2026-08-29

Windows applications for every domain user: the WinApps integration, a libvirt
VM builder to give it something to talk to, and the long tail of fixes needed to
make an unattended Windows 11 install actually complete. Also the point at which
the script started noticing it was out of date.

### Added

- **Startup update check and `--update`.** A checkout three commits behind looks
  exactly like a current one until it does the wrong thing, so the script now
  checks its own git remote at launch, says what is missing and offers to fix it
  before anything else runs. `--update` checks, updates and exits;
  `--no-update-check` turns the launch check off. (`6b2a72f`)
- **WinApps multi-user support for domain-joined machines.** One Windows guest,
  seeded for every domain user who logs in, rather than a per-user setup.
  `--winapps`, `--no-winapps`, `--winapps-backend`, `--winapps-creds` and
  `--winapps-domain` drive it unattended. (`eeb9294`)
- **VM builder for a libvirt Windows guest.** Builds the VM WinApps connects to
  — disk, network, TPM 2.0, virtio drivers and a generated `Autounattend.xml` —
  from `--winapps-iso`, with `--no-winapps-deploy` to configure WinApps without
  building anything. (`1679ba5`)
- **WinApps launcher scripts are seeded during configuration.** The
  application entries now exist before the first login rather than after it.
  (`e6be898`)
- **Windows ISO is patched to skip the CD boot prompt.** `iso_efi_noprompt()`
  rewrites the EFI boot image so the install starts without a keypress, instead
  of relying on the script timing one. (`ef4bbc7`)

### Changed

- The ESC keypress window is a firmware-only prompt, and the wait is ~25s rather
  than the longer figure previously documented. (`dbfad33`)

### Fixed

- `--winapps-iso` takes a full path to the ISO file, not a directory — enforced
  as well as documented. (`3d354e3`)
- ISO permissions the hypervisor could not read, the wrong `RDPApps.reg` URL,
  and files left behind when a retry cleaned up. (`4538a8c`)
- A rebuild no longer clobbers an existing qcow2 disk silently: it fails fast
  without `--force`, skips re-copying the staged install ISO when its size
  already matches, and removes the stale qcow2 and unattend ISOs only on a real
  rebuild. (`4da7264`)
- The staged Windows ISO is reused instead of being downloaded again through
  Mido. (`46bcb87`)
- A failed deploy now prints the exact re-run command, with the VM name and ISO
  path filled in. (`b85402b`)
- Windows 11 24H2/25H2 Setup aborting with `0xD000A000-0x40031`: a
  `$WinPEDriver$` INF matching a driver WinPE had already loaded caused the
  abort; only `viostor` and `NetKVM` are staged now, and
  `virtio-win-guest-tools` installs the rest on first boot. (`0afbcfc`)
- The install failing with "computer restarted unexpectedly"
  (`0x80220003`). Without `publicKeyToken` on its components, the offline SMI
  parser rejected `Autounattend.xml` in the specialize and oobeSystem passes.
  (`14e314e`)
- The CD boot prompt keypress, over three passes: tap Enter during the initial
  install (`258c5ac`), verify the `np.bin` write actually landed (`b5913c8`),
  send ESC and skip the tap entirely when the ISO is already patched
  (`4fc27a3`), then ENTER rather than ESC for the UEFI prompt (`ceb1c7c`).

## [1.3.0] — 2026-08-26

sudo rights for domain principals, and the SDDM login screen fixed properly
rather than worked around.

### Added

- **sudo grants for users and groups via `sudoers.d`.** Grants a domain user or
  group sudo rights in its own drop-in file, interactively or through
  `--sudo-user` and `--sudo-group`. Principal names are resolved and validated
  before anything is written, group members can be listed, and each rule is
  visited through `visudo` so a bad file can never land. (`19aab2d`)
- **A forked Breeze SDDM theme.** Breeze's `Main.qml` bails out of the user list
  when `showUserList` is false, which is exactly the case on a domain-joined
  machine. The theme is forked and patched rather than edited in place, so a
  Plasma update cannot silently revert it or fight the change. (`d82cc06`)

### Fixed

- SDDM: a `Current=` override elsewhere in the config could quietly win over the
  theme the script set. The override is now detected and the conflicting lines
  are logged. (`43f44a7`)
- sudo: an unusable principal name now re-prompts instead of aborting the step,
  and the per-step guards reset between batches so a second grant in the same
  run is not skipped as already done. (`672073e`)

## [1.2.0] — 2026-07-30

### Added

- **Duo Security two-factor authentication.** Covers local and Active Directory
  logins with one configuration, since `pam_duo` runs after the password module
  and does not care which module checked the password. Available as menu entry
  9, as `-e duo`, or through `--duo` and the `--duo-*` flags. It runs last in
  both the menu order and the guided setup, being the only step that can leave a
  machine unable to authenticate. (`25418d9`)

  - Wires **per-service PAM files** rather than `common-auth` or `system-auth`:
    those are regenerated by `pam-auth-update` and `authselect`, and are included
    by every service, so a second factor there would also land on `sudo`, `su`,
    `cron` and polkit.
  - Placement within a stack is **measured, not assumed** — `sufficient`,
    `include`, `substack`, `@include` and `success=done` are each classified, and
    the rule is appended where that is reachable and inserted first where it is
    not, because a rule sitting after a short-circuiting `sufficient` would look
    configured and never run.
  - Detects `pam_duo.so` rather than the package, since Fedora's `duo_unix`
    ships `login_duo` only. Falls back from the distro repositories to Duo's own
    (fingerprint shown before it is trusted) to a source build.
  - Lockout defences: `failmode=safe` by default, a break-glass group written as
    `groups = *,!duo-exempt` and evaluated by `pam_duo` before it contacts Duo,
    a backup of every edited file, and a built-in removal path.
  - `autopush=yes` with `prompts=1` when a greeter is protected, as Duo Unix has
    no graphical interface.

### Fixed

- The menu draw loop walked only as many rows as the left column had, which
  would have hidden the last entry of a longer right column. (`25418d9`)
- SDDM last-user lookup, and the short-name cache flush that has to accompany
  it — a changed `use_fully_qualified_names` does nothing until the SSSD cache
  is cleared, so the setting looks broken rather than pending. (`8485de5`)

## [1.0.0] — 2026-07-29

First working installer.

### Added

- **`domain-join-setup.sh`**, an interactive installer that detects the
  distribution *and* the desktop and offers only the choices that apply to that
  combination: authentication backend, graphical management tools, supporting
  components, the `realm` join itself, `pam_mkhomedir` home directories and
  network time synchronisation. Every menu entry is also a flag, `--dry-run`
  changes nothing on disk, and the README and test suite land with it.
  (`f0dd8d5`)
- **Last domain user on the SDDM login screen.** `configure_sddm_greeter()`
  detects SDDM as the active display manager, raises the UID ceiling to match
  SSSD's idmap range, and sets `needsFullUserModel=false` in `theme.conf.user`
  so the greeter resolves the last domain login by name instead of enumerating
  the whole directory. Falls back to a UID-only drop-in on SDDM versions before
  0.20. Brings with it the general-purpose `ini_set()` helper for editing INI
  files in place. (`8ea556c`)

---

## A note on 1.1.0

There is no 1.1.0. The SDDM last-user work (`8ea556c`) was the kind of change
that would normally have taken the minor bump, but `SCRIPT_VERSION` was left at
`1.0.0` and the next bump went straight to `1.2.0`. Rather than invent a tag
whose script would print a different number than the tag it sits on, that work
is recorded above under 1.0.0, which is what the script itself claimed at the
time.

[Unreleased]: https://github.com/acebmxer/domain_join/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/acebmxer/domain_join/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/acebmxer/domain_join/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/acebmxer/domain_join/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/acebmxer/domain_join/compare/v1.0.0...v1.2.0
[1.0.0]: https://github.com/acebmxer/domain_join/releases/tag/v1.0.0
