# Granting sudo rights

[← back to the README](../README.md)

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
