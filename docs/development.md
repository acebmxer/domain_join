# Development

[← back to the README](../README.md)

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
script is driven. Every version has an entry in [CHANGELOG.md](../CHANGELOG.md)
and an annotated git tag, so `git show v1.3.0:domain-join-setup.sh` prints a
script whose own `--version` agrees with the tag it came from.

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
