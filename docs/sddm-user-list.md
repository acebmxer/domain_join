# Domain users on the SDDM login screen

[← back to the README](../README.md)

Once the machine is joined, **domain logins work normally through SDDM** — pick
"Other" and type the domain username. KDE's System Settings has no Active
Directory module, so use Cockpit or the `realm` command for join and membership
management.

This note covers the optional tweak that puts the last domain user back on the
greeter as a named tile, the way a fresh Windows machine behaves.

## Why the greeter shows local accounts only

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

## …and that still does not draw a user list

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

## What the installer writes

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
