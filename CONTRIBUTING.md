# Contributing

Thanks for taking a look. Bug reports and patches are both welcome.

## Ground rules for this script

It runs on machines people are setting up, often as root, often piped straight
from `curl` into `bash`. A few constraints follow from that:

- **Idempotent.** Running it twice must leave the machine in the same state as
  running it once. Config file changes go inside the managed block; nothing is
  blindly appended.
- **Honest output.** A step reports success only when it succeeded. If
  something was skipped, it says so and why.
- **`--dry-run` writes nothing.** Every new step must respect it.
- **Nothing destructive without warning.** Don't overwrite a key or a config
  file that the user did not ask you to touch. Back it up or refuse.
- **bash 3.2.** macOS still ships it, so avoid `declare -A`, `${x^^}`,
  `mapfile`, and `"${arr[@]}"` on a possibly-empty array under `set -u`.
- **Secrets stay out of argv.** Private key material is read from a file, stdin
  or the terminal — never from a command-line argument, which shows up in shell
  history and `ps`.

## Before opening a pull request

```bash
shellcheck bootstrap.sh
shfmt -d bootstrap.sh    # or `shfmt -w bootstrap.sh` to apply
tests/smoke.sh
```

CI runs the same three on Debian and Ubuntu, plus a real end-to-end run in a
container. If you change behaviour, add a case to `tests/smoke.sh`.

## Adding a step

Steps are self-contained functions called from `main`, in the shape of the
existing ones: announce with `step`, then `ok` / `skip` / `warn` / `note` per
outcome, and `record` anything the user needs to do afterwards. Add the flag to
`parse_args`, the help text in `usage`, and the README's options list.
