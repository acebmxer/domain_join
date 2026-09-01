# Short usernames and the SSSD cache

[← back to the README](../README.md)

Turning on short usernames (`jdoe` instead of `jdoe@corp.example.com`, with home
directories at `/home/jdoe`) needs the cache cleared, not just the setting
changed.

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
