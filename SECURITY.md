# Security

## Reporting a vulnerability

Please report security issues privately through GitHub's
[security advisories](https://github.com/guntanis/bootstrap/security/advisories/new)
rather than in a public issue.

## What this script does to a machine

It is worth knowing before you pipe it into `bash`:

- **It installs no SSH key unless you name one.** There is no built-in or
  default key. Run it with no arguments and `authorized_keys` is untouched.
- **A key in `authorized_keys` grants login.** Only install keys whose private
  half you control. `--github-user NAME` trusts whatever that GitHub account
  publishes, so check the name.
- **`--passwordless-sudo` is off by default** and materially weakens the
  machine — see the README. The file it writes is validated with `visudo`
  first, because an invalid sudoers file locks out `sudo` entirely.
- **Private keys never go in argv.** `--github-key` takes a path, `-` for
  stdin, or `--github-key-paste` for the terminal. A key passed as an argument
  would be readable via `ps` and saved in your shell history.
- **GitHub's host keys are fetched over HTTPS** from `api.github.com/meta` and
  pinned in `known_hosts`, instead of being accepted on first sight. If that
  fetch fails the script says so and leaves you with the normal prompt.
- **Permissions are set explicitly**: `700` on `~/.ssh`, `600` on private keys,
  `authorized_keys`, `known_hosts` and `~/.ssh/config`, and `0440 root:root` on
  the sudoers file. The private key is written under `umask 077` so it is never
  briefly readable by others.

## The hardening steps

`--harden-ssh` and `--lock-root` change how you can log in, so they are built to
fail safe:

- **It will not disable password logins unless a key is already installed.**
  Without a key in `~/.ssh/authorized_keys` it refuses and changes nothing.
- **The drop-in is named `01-...`, not `99-...`.** sshd takes the *first* value
  it sees for a keyword, so a high-numbered file would be overridden by
  `50-cloud-init.conf` on Ubuntu cloud images and the hardening would quietly
  have no effect.
- **`sshd -t` validates the result** before it is relied on; if sshd rejects the
  configuration the file is removed and the run aborts.
- **sshd is reloaded, not restarted**, so the session you are sitting in is not
  dropped.
- **The change reverts itself after five minutes** unless you confirm with
  `sudo touch /etc/ssh/.bootstrap-ssh-confirmed` from a second session. Set
  `--ssh-revert-seconds 0` to opt out.
- **`--lock-root` only locks the password.** Key login and `sudo` continue to
  work. Single-user recovery normally prompts for that password, so keep
  console or rescue access in mind.

Combining `--passwordless-sudo` with `--harden-ssh` means a stolen private key
is immediate root access with no second factor. That can be a reasonable trade
for a personal machine; it is worth making on purpose.

## Auditing before you run it

```bash
curl -fsSL https://raw.githubusercontent.com/guntanis/bootstrap/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh
./bootstrap.sh --dry-run
```

`--dry-run` performs every check and prints every change without writing
anything.
