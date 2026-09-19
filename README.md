# bootstrap

One script to make a fresh Debian or Ubuntu box comfortable to work on: shell
history you can search with the arrow keys, your SSH key installed for login,
your GitHub key set up for `git clone`, and `vim` as the default editor.

Re-running it is safe. Everything it writes into a config file lives inside a
single marked block, so a second run updates that block instead of appending a
second copy of itself.

```bash
curl -fsSL https://raw.githubusercontent.com/guntanis/bootstrap/main/bootstrap.sh \
  | bash -s -- --github-user YOUR_GITHUB_USERNAME
```

Run it with no arguments and it configures the shell only — it never installs a
key you did not ask for.

## What it sets up

| Step | What happens | Where |
| --- | --- | --- |
| Shell history | Up/Down search history for what you have already typed; 10k deduplicated entries shared between sessions | `~/.bashrc` or `~/.zshrc` |
| Inbound SSH | Installs public keys so **you** can log in to this machine | `~/.ssh/authorized_keys` |
| GitHub access | Imports a private key, pins GitHub's host keys, writes an SSH config block, verifies the connection | `~/.ssh/` |
| Editor | `EDITOR`/`VISUAL`, plus the system-wide editor via `update-alternatives` | rc file, `update-alternatives` |
| Passwordless sudo | Opt-in `NOPASSWD` for the `sudo` group, validated with `visudo` | `/etc/sudoers.d/99-passwordless-sudo` |
| Base packages | Opt-in `apt-get install` of a small working set | dpkg |
| SSH hardening | Opt-in key-only logins, with a lockout guard and an automatic revert | `/etc/ssh/sshd_config.d/` |
| Root password | Opt-in lock, leaving keys and sudo working | `passwd -l root` |

Debian and Ubuntu get all of it. On other Linux distributions and macOS the
shell, SSH and GitHub steps still work; the two steps that need Debian tooling
report themselves as skipped instead of failing.

## Letting yourself log in

The script installs **public** keys into `authorized_keys`. Paste one straight
into the terminal:

```bash
./bootstrap.sh --ssh-key-paste
```

It takes one key per line, so you can paste several at once; press Enter on an
empty line when you are done. The other sources:

```bash
./bootstrap.sh --github-user YOUR_GITHUB_USERNAME        # from github.com/USER.keys
./bootstrap.sh --ssh-key "ssh-ed25519 AAAAC3Nza... you@laptop"
./bootstrap.sh --ssh-key-file ~/.ssh/id_ed25519.pub      # "-" reads stdin
```

They combine, so `--ssh-key-paste --github-user you` installs both.

Anything that is not a well-formed public key line is reported and skipped, and
a key already present is left alone — including when only its comment differs.

## Setting up GitHub

Hand the script the **private** key for the machine and the rest is automatic:

```bash
./bootstrap.sh --github-key-paste                 # paste it into the terminal
./bootstrap.sh --github-key ~/Downloads/id_ed25519  # or import a file
./bootstrap.sh --github-key -                       # or pipe it in
```

That one step:

1. installs the key at `~/.ssh/id_github` with mode `600`, refusing to
   overwrite a different key already there;
2. derives the public half into `id_github.pub` and prints it, so you can paste
   it into <https://github.com/settings/keys>;
3. pins GitHub's real host keys in `known_hosts`, fetched over HTTPS from
   `api.github.com/meta` — so the first `git clone` is verified rather than
   trusted blindly;
4. adds a `github.com` block to `~/.ssh/config` pointing at that key;
5. checks that GitHub actually accepts it, using that key specifically.

Then `git clone git@github.com:OWNER/REPO.git` works.

Add `--git-name "Your Name" --git-email you@example.com` to set your commit
identity at the same time. If the key has a passphrase, the script says how to
load it into `ssh-agent` and skips the connection check rather than reporting a
failure it cannot distinguish from a rejected key.

There is deliberately no flag that takes the key material itself as a value: an
argument like `--github-key "-----BEGIN..."` would be visible in your shell
history and to anyone who can run `ps`.

## Options

```
INBOUND SSH - who may log in to this machine
    --ssh-key-paste        Paste public key(s) into the terminal
    --ssh-key KEY          Install this public key in ~/.ssh/authorized_keys
    --ssh-key-file PATH    Read public key(s) from PATH ("-" for stdin)
    --github-user USER     Install the keys published at github.com/USER.keys

GITHUB ACCESS - this machine's identity to GitHub
    --github-key PATH      Import an OpenSSH private key ("-" for stdin)
    --github-key-paste     Paste the private key into the terminal
    --github-key-name NAME Filename under ~/.ssh (default: id_github)
    --git-name NAME        git config --global user.name
    --git-email EMAIL      git config --global user.email

SERVER HARDENING - all opt-in
    --harden               Shorthand for --harden-ssh --lock-root
    --harden-ssh           Key-only SSH; refuses unless a key is installed,
                           validates with sshd -t, and reverts unless confirmed
    --permit-root-login V  yes | no | prohibit-password (default) |
                           forced-commands-only
    --ssh-revert-seconds N Undo the SSH changes after N seconds unless
                           confirmed; 0 disables (default: 300)
    --lock-root            Lock the root password; keys and sudo still work

OTHER
    --install-packages     Install a base set of packages
    --packages "A B C"     Install this set instead
    --editor NAME          Editor for EDITOR/VISUAL (default: vim)
    --shell NAME           Force shell flavour: bash or zsh (default: $SHELL)
    --shell-rc PATH        Rc file to manage (default: derived from the shell)
    --history-size N       History entries to keep (default: 10000)
    --passwordless-sudo    Give the "sudo" group NOPASSWD (Debian/Ubuntu)
    --no-history           Skip the shell history configuration
    --no-ssh               Skip the SSH key step
    --no-editor            Skip the editor configuration
    -n, --dry-run          Report what would change, change nothing
    -q, --quiet            Only print warnings and errors
    -h, --help             Show this help
    -V, --version          Show the version
```

Every option has an environment variable equivalent, which is useful when
piping the script into `bash`: `BOOTSTRAP_SSH_KEY`, `BOOTSTRAP_SSH_KEY_FILE`,
`BOOTSTRAP_GITHUB_USER`, `BOOTSTRAP_GITHUB_KEY`, `BOOTSTRAP_GITHUB_KEY_NAME`,
`BOOTSTRAP_GIT_NAME`, `BOOTSTRAP_GIT_EMAIL`, `BOOTSTRAP_EDITOR`,
`BOOTSTRAP_SHELL`, `BOOTSTRAP_SHELL_RC`, `BOOTSTRAP_HISTORY_SIZE`,
`BOOTSTRAP_PACKAGES`, `BOOTSTRAP_PERMIT_ROOT_LOGIN`,
`BOOTSTRAP_SSH_REVERT_SECONDS`.

`--dry-run` prints every change it would make and writes nothing. It is worth a
look before the first real run:

```bash
./bootstrap.sh --dry-run --github-user YOUR_GITHUB_USERNAME
```

## Hardening a fresh server

Nothing here runs unless you ask for it:

```bash
./bootstrap.sh --github-user YOUR_GITHUB_USERNAME --install-packages --harden
```

`--harden` is shorthand for `--harden-ssh --lock-root`.

### Key-only SSH

`--harden-ssh` writes `/etc/ssh/sshd_config.d/01-bootstrap-hardening.conf`:

```
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
LoginGraceTime 30
```

That removes essentially all of the brute-force traffic a public server
attracts within minutes of booting. Root can still log in by key; pass
`--permit-root-login no` to stop that too.

The filename starts with `01-` deliberately. **sshd uses the first value it
sees for a keyword**, not the last, so a file named `99-hardening.conf` would
lose to the `50-cloud-init.conf` that Ubuntu cloud images ship with
`PasswordAuthentication yes` in it — and the hardening would silently do
nothing.

Locking yourself out of a remote machine is the obvious risk, so:

- it **refuses to run** unless `~/.ssh/authorized_keys` already holds a key, so
  there is always a way back in;
- the result is validated with `sshd -t` before it takes effect, and removed
  again if sshd rejects it;
- sshd is **reloaded, not restarted**, so your current session survives;
- and it **undoes itself after five minutes** unless you confirm.

On a system older than Debian 12 / Ubuntu 22.04 whose `sshd_config` has no
`Include` line, a drop-in would be ignored — the script detects that, changes
nothing, and prints what to edit by hand.

### The automatic revert

After applying, the script tells you to open a **second** terminal, confirm you
can still get in, and only then run:

```bash
sudo touch /etc/ssh/.bootstrap-ssh-confirmed
```

Do nothing and password logins come back by themselves. A mistake costs five
minutes, not the server. Tune it with `--ssh-revert-seconds N`, or set `0` to
turn the safety net off.

It is a systemd transient timer where systemd is available, pinned to
`AccuracySec=1s` so it fires when promised rather than up to a minute late, and
a detached background job otherwise.

### Locking the root password

`--lock-root` runs `passwd -l root`. Key-based root login and `sudo` keep
working; only password authentication for root goes away. Note that
single-user/recovery mode normally prompts for that password, so keep console
or rescue access in mind before you reboot.

## Passwordless sudo

`--passwordless-sudo` drops a file in `/etc/sudoers.d` that lets every member of
the `sudo` group run any command as root without a password. It is off unless
you ask for it, because it is a real reduction in security: anything that can
run as you can then run as root, without a prompt.

If you do want it, the script writes the file through `visudo -c` validation and
installs it as `0440 root:root`. A sudoers file with a syntax error locks out
`sudo` for everyone on the machine, so it refuses to install one that does not
parse.

Only turn it on for machines you control and that are not shared.

## Undoing it

Every rc-file change sits between two markers:

```
# >>> bootstrap.sh managed block >>>
...
# <<< bootstrap.sh managed block <<<
```

Delete that block from `~/.bashrc`, `~/.zshrc` or `~/.ssh/config` and the change
is gone; your own edits outside the markers are never touched. The script also
keeps a copy of the previous version as `<file>.bootstrap.bak` whenever it
changes one.

The rest:

```bash
rm ~/.ssh/id_github ~/.ssh/id_github.pub                    # GitHub key
sudo rm /etc/sudoers.d/99-passwordless-sudo                 # passwordless sudo
sudo rm /etc/ssh/sshd_config.d/01-bootstrap-hardening.conf  # SSH hardening
sudo systemctl reload ssh
sudo passwd -u root                                         # unlock root
```

and edit `~/.ssh/authorized_keys` to drop any key you no longer want.

## Requirements

`bash` 3.2 or newer. `curl` or `wget` for the steps that fetch keys, `git` for
`--git-name`/`--git-email`, and `ssh-keygen` (from `openssh-client`) to derive a
public key. Missing tools are reported and that step is skipped.

## Development

```bash
shellcheck bootstrap.sh    # lint
shfmt -d bootstrap.sh      # formatting
tests/smoke.sh             # tests, against a throwaway HOME
```

CI runs all three on Debian and Ubuntu. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
