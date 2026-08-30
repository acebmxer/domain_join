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

### Added

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

### Fixed

- The menu banner in the README was one column too wide: the title row's
  interior measured 82 characters against an 81-character `╔═╗` border, so the
  closing `║` sat one place past the corner. The README now uses the same
  padding arithmetic the script does, which puts the odd column on the right.

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

[Unreleased]: https://github.com/acebmxer/domain_join/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/acebmxer/domain_join/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/acebmxer/domain_join/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/acebmxer/domain_join/compare/v1.0.0...v1.2.0
[1.0.0]: https://github.com/acebmxer/domain_join/releases/tag/v1.0.0
