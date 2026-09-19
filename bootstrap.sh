#!/usr/bin/env bash
#
# bootstrap.sh - give a fresh Debian or Ubuntu account sane shell history,
# SSH and editor defaults. Idempotent: re-running updates in place.
#
# Debian/Ubuntu is the primary target. On other systems the shell and SSH
# steps still work; the steps that need dpkg tooling announce themselves as
# skipped rather than failing.
#
# https://github.com/guntanis/bootstrap
# SPDX-License-Identifier: MIT

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
	echo "bootstrap.sh: this script requires bash (try: bash bootstrap.sh)" >&2
	exit 1
fi

VERSION='1.0.0'
PROGRAM='bootstrap.sh'
MARKER_BEGIN='# >>> bootstrap.sh managed block >>>'
MARKER_END='# <<< bootstrap.sh managed block <<<'

# --------------------------------------------------------------- defaults ---
SSH_KEY_ARG="${BOOTSTRAP_SSH_KEY:-}"
SSH_KEY_FILE="${BOOTSTRAP_SSH_KEY_FILE:-}"
SSH_KEY_PASTE=0
GITHUB_USER="${BOOTSTRAP_GITHUB_USER:-}"
EDITOR_NAME="${BOOTSTRAP_EDITOR:-vim}"
RC_FILE="${BOOTSTRAP_SHELL_RC:-}"
SHELL_NAME="${BOOTSTRAP_SHELL:-}"
HISTORY_SIZE="${BOOTSTRAP_HISTORY_SIZE:-10000}"
GITHUB_KEY_SRC="${BOOTSTRAP_GITHUB_KEY:-}"
GITHUB_KEY_NAME="${BOOTSTRAP_GITHUB_KEY_NAME:-id_github}"
GIT_NAME="${BOOTSTRAP_GIT_NAME:-}"
GIT_EMAIL="${BOOTSTRAP_GIT_EMAIL:-}"
PACKAGES="${BOOTSTRAP_PACKAGES:-git curl ca-certificates vim htop tmux rsync}"
PERMIT_ROOT_LOGIN="${BOOTSTRAP_PERMIT_ROOT_LOGIN:-prohibit-password}"
SSH_REVERT_SECONDS="${BOOTSTRAP_SSH_REVERT_SECONDS:-300}"
SSH_DROPIN='/etc/ssh/sshd_config.d/01-bootstrap-hardening.conf'
SSH_CONFIRM_FILE='/etc/ssh/.bootstrap-ssh-confirmed'
SSH_HARDENED=0
SSH_KEYS_PENDING=0
DO_PACKAGES=0
DO_HARDEN_SSH=0
DO_LOCK_ROOT=0
DO_HISTORY=1
DO_SSH=1
DO_EDITOR=1
DO_SUDO=0
DRY_RUN=0
QUIET=0
WARNINGS=0
CHANGES=()

# ----------------------------------------------------------------- output ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
	C_RESET=$'\033[0m'
	C_DIM=$'\033[2m'
	C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'
	C_YELLOW=$'\033[33m'
	C_BLUE=$'\033[34m'
else
	C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

step() { [ "$QUIET" -eq 1 ] || printf '\n%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { [ "$QUIET" -eq 1 ] || printf '  %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip() { [ "$QUIET" -eq 1 ] || printf '  %s.%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() {
	WARNINGS=$((WARNINGS + 1))
	printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}
die() {
	printf '%s%s: error:%s %s\n' "$C_RED" "$PROGRAM" "$C_RESET" "$*" >&2
	exit 1
}
say_running() { [ "$QUIET" -eq 1 ] || printf '  %s~%s %s ...\n' "$C_DIM" "$C_RESET" "$*"; }
note() { [ "$QUIET" -eq 1 ] || printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
record() { CHANGES[${#CHANGES[@]}]="$1"; }

usage() {
	cat <<'USAGE'
bootstrap.sh - set up shell history search, an SSH key and editor defaults.
Built for Debian/Ubuntu; degrades gracefully elsewhere.

USAGE:
    bootstrap.sh [OPTIONS]
    curl -fsSL <raw-url>/bootstrap.sh | bash -s -- [OPTIONS]

INBOUND SSH - who may log in to this machine (skipped if no key is given):
    --ssh-key-paste        Paste public key(s) into the terminal
    --ssh-key KEY          Install this public key in ~/.ssh/authorized_keys
    --ssh-key-file PATH    Read public key(s) from PATH ("-" for stdin)
    --github-user USER     Install the keys published at github.com/USER.keys

GITHUB ACCESS - this machine's identity to GitHub (skipped if no key is given):
    --github-key PATH      Import an OpenSSH private key ("-" for stdin)
    --github-key-paste     Paste the private key into the terminal
    --github-key-name NAME Filename under ~/.ssh (default: id_github)
    --git-name NAME        git config --global user.name
    --git-email EMAIL      git config --global user.email

  Importing a key also pins GitHub's host keys in known_hosts, writes a
  github.com block in ~/.ssh/config and verifies the connection. There is no
  flag that takes the key material itself: an argument would be visible in
  shell history and in `ps`.

SERVER HARDENING - all opt-in:
    --harden               Shorthand for --harden-ssh --lock-root
    --harden-ssh           Key-only SSH: no password or keyboard-interactive
                           logins. Refuses unless a key is already installed,
                           validates with sshd -t, and reverts itself unless
                           you confirm (see --ssh-revert-seconds).
    --permit-root-login V  yes | no | prohibit-password (default) |
                           forced-commands-only
    --ssh-revert-seconds N Undo the SSH changes after N seconds unless
                           confirmed; 0 disables (default: 300)
    --lock-root            Lock the root password; keys and sudo still work

OPTIONS:
    --install-packages     Install a base set of packages
    --packages "A B C"     Install this set instead
    --editor NAME          Editor for EDITOR/VISUAL (default: vim)
    --shell NAME           Force shell flavour: bash or zsh (default: $SHELL)
    --shell-rc PATH        Rc file to manage (default: derived from the shell)
    --history-size N       History entries to keep (default: 10000)
    --passwordless-sudo    Give the "sudo" group NOPASSWD (Debian/Ubuntu).
                           Opt-in: this materially weakens system security.
    --no-history           Skip the shell history configuration
    --no-ssh               Skip the SSH key step
    --no-editor            Skip the editor configuration
    -n, --dry-run          Report what would change, change nothing
    -q, --quiet            Only print warnings and errors
    -h, --help             Show this help
    -V, --version          Show the version

Every option also has a BOOTSTRAP_* environment variable equivalent; see the
README. Changes to rc files live in a single marked block that later runs
rewrite, so editing outside the block is safe.
USAGE
}

# ---------------------------------------------------------------- helpers ---
have() { command -v "$1" >/dev/null 2>&1; }

os_id() {
	[ -r /etc/os-release ] || return 0
	# Sourced in a subshell so the caller's environment stays clean.
	(
		# shellcheck disable=SC1091
		. /etc/os-release
		printf '%s %s\n' "${ID:-}" "${ID_LIKE:-}"
	)
}

is_debian_like() {
	case " $(os_id) " in
	*" debian "* | *" ubuntu "*) return 0 ;;
	*) return 1 ;;
	esac
}

ROOT_CMD=()
ROOT_OK=0
init_privilege() {
	if [ "$(id -u)" -eq 0 ]; then
		ROOT_OK=1
	elif have sudo; then
		if sudo -n true 2>/dev/null; then
			ROOT_OK=1
			ROOT_CMD=(sudo -n)
		elif [ -t 0 ]; then
			# Only prompt when a human can actually answer; under
			# `curl | bash` stdin is the script itself.
			ROOT_OK=1
			ROOT_CMD=(sudo)
		fi
	fi
}

# How to run a command as root here, for instructions we print. On a minimal
# Debian install sudo is simply absent, so "run: sudo ..." would be useless.
as_root_hint() {
	if [ "$(id -u)" -eq 0 ]; then
		printf '%s' "$1"
	elif have sudo; then
		printf 'sudo %s' "$1"
	else
		printf "su -c '%s'" "$1"
	fi
}

# Printed once, the first time a step needs root and cannot get it.
ROOT_ADVICE_SHOWN=0
explain_no_root() {
	[ "$ROOT_ADVICE_SHOWN" -eq 0 ] || return 0
	ROOT_ADVICE_SHOWN=1
	have sudo && return 0
	note "sudo is not installed; a minimal Debian install leaves it out."
	note "  Become root with 'su -', then:"
	note "    apt-get install -y sudo && usermod -aG sudo $(id -un)"
	note "  Log out and back in, and the skipped steps above will work."
}

as_root() {
	if [ ${#ROOT_CMD[@]} -gt 0 ]; then
		"${ROOT_CMD[@]}" "$@"
	else
		"$@"
	fi
}

# Replace the managed block in $1 with the content on stdin, creating the file
# if needed. Prints nothing; returns 0 if the file changed, 1 if it did not.
apply_block() {
	local rc="$1" block tmp existing
	block="$(cat)"
	existing=''
	[ -f "$rc" ] && existing="$(cat "$rc")"

	tmp="$(mktemp "${TMPDIR:-/tmp}/bootstrap.XXXXXX")"
	if [ -f "$rc" ]; then
		awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
			$0 == b { skip = 1; next }
			$0 == e { skip = 0; next }
			!skip
		' "$rc" >"$tmp"
	fi
	# Collapse trailing blank lines so repeated runs do not grow the file,
	# and only separate the block from preceding content that exists.
	local kept
	kept="$(cat "$tmp")"
	{
		if [ -n "$kept" ]; then
			printf '%s\n\n' "$kept"
		fi
		printf '%s\n%s\n%s\n' "$MARKER_BEGIN" "$block" "$MARKER_END"
	} >"$tmp"

	if [ "$existing" = "$(cat "$tmp")" ]; then
		rm -f "$tmp"
		return 1
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		rm -f "$tmp"
		return 0
	fi
	[ -f "$rc" ] && cp -p "$rc" "$rc.bootstrap.bak"
	cat "$tmp" >"$rc"
	rm -f "$tmp"
	return 0
}

# ------------------------------------------------------------------- args ---
parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--ssh-key)
			SSH_KEY_ARG="${2:?--ssh-key needs a value}"
			shift 2
			;;
		--ssh-key=*)
			SSH_KEY_ARG="${1#*=}"
			shift
			;;
		--ssh-key-file)
			SSH_KEY_FILE="${2:?--ssh-key-file needs a value}"
			shift 2
			;;
		--ssh-key-file=*)
			SSH_KEY_FILE="${1#*=}"
			shift
			;;
		--ssh-key-paste)
			SSH_KEY_PASTE=1
			shift
			;;
		--github-user)
			GITHUB_USER="${2:?--github-user needs a value}"
			shift 2
			;;
		--github-user=*)
			GITHUB_USER="${1#*=}"
			shift
			;;
		--editor)
			EDITOR_NAME="${2:?--editor needs a value}"
			shift 2
			;;
		--editor=*)
			EDITOR_NAME="${1#*=}"
			shift
			;;
		--shell)
			SHELL_NAME="${2:?--shell needs a value}"
			shift 2
			;;
		--shell=*)
			SHELL_NAME="${1#*=}"
			shift
			;;
		--shell-rc)
			RC_FILE="${2:?--shell-rc needs a value}"
			shift 2
			;;
		--shell-rc=*)
			RC_FILE="${1#*=}"
			shift
			;;
		--history-size)
			HISTORY_SIZE="${2:?--history-size needs a value}"
			shift 2
			;;
		--history-size=*)
			HISTORY_SIZE="${1#*=}"
			shift
			;;
		--github-key)
			GITHUB_KEY_SRC="${2:?--github-key needs a path (or - for stdin)}"
			shift 2
			;;
		--github-key=*)
			GITHUB_KEY_SRC="${1#*=}"
			shift
			;;
		--github-key-paste)
			GITHUB_KEY_SRC='paste'
			shift
			;;
		--github-key-name)
			GITHUB_KEY_NAME="${2:?--github-key-name needs a value}"
			shift 2
			;;
		--github-key-name=*)
			GITHUB_KEY_NAME="${1#*=}"
			shift
			;;
		--git-name)
			GIT_NAME="${2:?--git-name needs a value}"
			shift 2
			;;
		--git-name=*)
			GIT_NAME="${1#*=}"
			shift
			;;
		--git-email)
			GIT_EMAIL="${2:?--git-email needs a value}"
			shift 2
			;;
		--git-email=*)
			GIT_EMAIL="${1#*=}"
			shift
			;;
		--passwordless-sudo)
			DO_SUDO=1
			shift
			;;
		--install-packages)
			DO_PACKAGES=1
			shift
			;;
		--packages)
			PACKAGES="${2:?--packages needs a list}"
			DO_PACKAGES=1
			shift 2
			;;
		--packages=*)
			PACKAGES="${1#*=}"
			DO_PACKAGES=1
			shift
			;;
		--harden-ssh)
			DO_HARDEN_SSH=1
			shift
			;;
		--lock-root)
			DO_LOCK_ROOT=1
			shift
			;;
		--harden)
			DO_HARDEN_SSH=1
			DO_LOCK_ROOT=1
			shift
			;;
		--permit-root-login)
			PERMIT_ROOT_LOGIN="${2:?--permit-root-login needs a value}"
			shift 2
			;;
		--permit-root-login=*)
			PERMIT_ROOT_LOGIN="${1#*=}"
			shift
			;;
		--ssh-revert-seconds)
			SSH_REVERT_SECONDS="${2:?--ssh-revert-seconds needs a value}"
			shift 2
			;;
		--ssh-revert-seconds=*)
			SSH_REVERT_SECONDS="${1#*=}"
			shift
			;;
		--no-history)
			DO_HISTORY=0
			shift
			;;
		--no-ssh)
			DO_SSH=0
			shift
			;;
		--no-editor)
			DO_EDITOR=0
			shift
			;;
		-n | --dry-run)
			DRY_RUN=1
			shift
			;;
		-q | --quiet)
			QUIET=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			printf '%s %s\n' "$PROGRAM" "$VERSION"
			exit 0
			;;
		--)
			shift
			break
			;;
		*) die "unknown option: $1 (try --help)" ;;
		esac
	done

	case "$HISTORY_SIZE" in
	'' | *[!0-9]*) die "--history-size must be a positive integer" ;;
	esac
	case "$SSH_REVERT_SECONDS" in
	'' | *[!0-9]*) die "--ssh-revert-seconds must be a whole number (0 disables)" ;;
	esac
	case "$PERMIT_ROOT_LOGIN" in
	yes | no | prohibit-password | forced-commands-only) : ;;
	*) die "--permit-root-login must be yes, no, prohibit-password or forced-commands-only" ;;
	esac
}

# ------------------------------------------------------------------ shell ---
resolve_shell() {
	[ -n "$SHELL_NAME" ] || SHELL_NAME="$(basename -- "${SHELL:-}")"
	case "$SHELL_NAME" in
	zsh)
		[ -n "$RC_FILE" ] || RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
		;;
	bash)
		if [ -z "$RC_FILE" ]; then
			if [ -f "$HOME/.bashrc" ]; then
				RC_FILE="$HOME/.bashrc"
			elif [ -f "$HOME/.bash_profile" ]; then
				RC_FILE="$HOME/.bash_profile"
			elif [ "$(uname -s)" = Darwin ]; then
				# macOS terminals start bash as a login shell.
				RC_FILE="$HOME/.bash_profile"
			else
				RC_FILE="$HOME/.bashrc"
			fi
		fi
		;;
	esac
}

render_zsh_block() {
	if [ "$DO_HISTORY" -eq 1 ]; then
		cat <<ZSH_HIST
HISTFILE="\${HISTFILE:-\$HOME/.zsh_history}"
HISTSIZE=$HISTORY_SIZE
SAVEHIST=$HISTORY_SIZE
setopt SHARE_HISTORY EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS

if [[ -o interactive ]]; then
  # Up/Down search history for commands starting with what is already typed.
  autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
  zle -N up-line-or-beginning-search
  zle -N down-line-or-beginning-search
  # Both the normal and application-mode escape sequences.
  bindkey '^[[A' up-line-or-beginning-search
  bindkey '^[OA' up-line-or-beginning-search
  bindkey '^[[B' down-line-or-beginning-search
  bindkey '^[OB' down-line-or-beginning-search
fi
ZSH_HIST
	fi
	if [ "$DO_EDITOR" -eq 1 ]; then
		[ "$DO_HISTORY" -eq 1 ] && echo
		cat <<ZSH_EDITOR
if (( \$+commands[$EDITOR_NAME] )); then
  export EDITOR=$EDITOR_NAME
  export VISUAL=$EDITOR_NAME
fi
ZSH_EDITOR
	fi
}

render_bash_block() {
	if [ "$DO_HISTORY" -eq 1 ]; then
		cat <<BASH_HIST
HISTSIZE=$HISTORY_SIZE
HISTFILESIZE=$((HISTORY_SIZE * 2))
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend cmdhist

if [[ \$- == *i* ]]; then
  # Up/Down search history for commands starting with what is already typed.
  # Guarded: \`bind\` fails in non-interactive shells (scp, rsync, ...).
  bind '"\e[A": history-search-backward'
  bind '"\eOA": history-search-backward'
  bind '"\e[B": history-search-forward'
  bind '"\eOB": history-search-forward'
fi
BASH_HIST
	fi
	if [ "$DO_EDITOR" -eq 1 ]; then
		[ "$DO_HISTORY" -eq 1 ] && echo
		cat <<BASH_EDITOR
if command -v $EDITOR_NAME >/dev/null 2>&1; then
  export EDITOR=$EDITOR_NAME
  export VISUAL=$EDITOR_NAME
fi
BASH_EDITOR
	fi
}

configure_shell() {
	step "Shell configuration"
	if [ "$DO_HISTORY" -eq 0 ] && [ "$DO_EDITOR" -eq 0 ]; then
		skip "history and editor steps both disabled"
		return
	fi
	case "$SHELL_NAME" in
	zsh | bash) : ;;
	'')
		warn "could not determine your shell; pass --shell bash|zsh"
		return
		;;
	*)
		warn "unsupported shell '$SHELL_NAME'; pass --shell bash|zsh to force"
		return
		;;
	esac

	if [ "$DRY_RUN" -eq 0 ] && [ ! -e "$RC_FILE" ]; then
		mkdir -p "$(dirname -- "$RC_FILE")"
	fi

	if "render_${SHELL_NAME}_block" | apply_block "$RC_FILE"; then
		if [ "$DRY_RUN" -eq 1 ]; then
			ok "would write the managed block to $RC_FILE"
		else
			ok "managed block written to $RC_FILE"
			[ -f "$RC_FILE.bootstrap.bak" ] &&
				skip "previous version saved as $RC_FILE.bootstrap.bak"
			record "reload your shell: exec $SHELL_NAME -l"
		fi
	else
		skip "$RC_FILE already up to date"
	fi
}

# -------------------------------------------------------------------- ssh ---
# A public key line: <type> <base64> [comment]
valid_key() {
	case "$1" in
	"ssh-rsa "* | "ssh-ed25519 "* | "ssh-dss "* | \
		"ecdsa-sha2-nistp256 "* | "ecdsa-sha2-nistp384 "* | \
		"ecdsa-sha2-nistp521 "* | \
		"sk-ssh-ed25519@openssh.com "* | \
		"sk-ecdsa-sha2-nistp256@openssh.com "*)
		# Require a non-empty second field that looks like base64.
		# shellcheck disable=SC2086  # splitting into fields is the point
		set -- $1
		[ $# -ge 2 ] && [ "${2#*[!A-Za-z0-9+/=]}" = "$2" ] && [ ${#2} -ge 32 ]
		;;
	*) return 1 ;;
	esac
}

# Type + key material only, so a differing comment is not a different key.
key_fingerprint_fields() {
	# shellcheck disable=SC2086  # splitting into fields is the point
	set -- $1
	printf '%s %s\n' "$1" "$2"
}

# "<type> <comment>", for human-readable output.
describe_key() {
	printf '%s' "$1" | awk '{print $1, ($3 != "" ? $3 : "(no comment)")}'
}

http_get() {
	if have curl; then
		curl -fsSL --max-time 20 "$1"
	elif have wget; then
		wget -qO- --timeout=20 "$1"
	else
		die "need curl or wget to reach $1"
	fi
}

fetch_github_keys() { http_get "https://github.com/$1.keys"; }

# Public keys are one line each, so a blank line ends the paste rather than
# the BEGIN/END markers a private key has.
read_pasted_public_keys() {
	local line out=''
	: 2>/dev/null </dev/tty || die "no terminal to paste into; use --ssh-key-file PATH instead"
	{
		printf 'Paste one or more public keys, one per line.\n'
		printf 'Press Enter on an empty line when you are done.\n\n'
	} >/dev/tty
	while :; do
		# A paste ended with Ctrl-D rather than Enter leaves a final line
		# with no newline, which plain `read` would discard.
		IFS= read -r line || { [ -n "$line" ] || break; }
		line="${line%$'\r'}"
		case "$line" in '') break ;; esac
		out="$out$line"$'\n'
		line=''
	done </dev/tty
	printf '%s' "$out"
}

collect_keys() {
	local keys=''
	[ -n "$SSH_KEY_ARG" ] && keys="$keys$SSH_KEY_ARG"$'\n'
	if [ "$SSH_KEY_PASTE" -eq 1 ]; then
		keys="$keys$(read_pasted_public_keys)"$'\n'
	fi
	if [ -n "$SSH_KEY_FILE" ]; then
		if [ "$SSH_KEY_FILE" = '-' ]; then
			keys="$keys$(cat)"$'\n'
		elif [ -r "$SSH_KEY_FILE" ]; then
			keys="$keys$(cat "$SSH_KEY_FILE")"$'\n'
		else
			die "cannot read key file: $SSH_KEY_FILE"
		fi
	fi
	if [ -n "$GITHUB_USER" ]; then
		local fetched
		if ! fetched="$(fetch_github_keys "$GITHUB_USER")"; then
			die "could not fetch keys for GitHub user '$GITHUB_USER'"
		fi
		[ -n "$fetched" ] ||
			die "GitHub user '$GITHUB_USER' has no public keys"
		keys="$keys$fetched"$'\n'
	fi
	printf '%s' "$keys"
}

configure_ssh() {
	step "SSH authorized_keys"
	if [ "$DO_SSH" -eq 0 ]; then
		skip "disabled with --no-ssh"
		return
	fi
	if [ -z "$SSH_KEY_ARG" ] && [ -z "$SSH_KEY_FILE" ] &&
		[ -z "$GITHUB_USER" ] && [ "$SSH_KEY_PASTE" -eq 0 ]; then
		skip "no key given (--ssh-key-paste / --ssh-key / --ssh-key-file / --github-user)"
		return
	fi

	local ssh_dir="$HOME/.ssh" auth_keys="$HOME/.ssh/authorized_keys"
	local raw line added=0

	# Checked here, in the main shell. An assignment like k="$k$(f)" keeps
	# status 0 even when f fails, so a die() inside collect_keys' own
	# substitution could not stop the run.
	if [ "$SSH_KEY_PASTE" -eq 1 ]; then
		: 2>/dev/null </dev/tty ||
			die "no terminal to paste into; use --ssh-key-file PATH instead"
	fi
	# die() inside the substitution exits only that subshell, so the
	# status has to be checked here too.
	if ! raw="$(collect_keys)"; then
		exit 1
	fi

	if [ "$DRY_RUN" -eq 0 ]; then
		mkdir -p "$ssh_dir"
		chmod 700 "$ssh_dir"
		[ -f "$auth_keys" ] || : >"$auth_keys"
		chmod 600 "$auth_keys"
		# A file without a trailing newline would glue our key onto the
		# last existing one.
		if [ -s "$auth_keys" ] &&
			[ "$(tail -c 1 "$auth_keys" | wc -l)" -eq 0 ]; then
			printf '\n' >>"$auth_keys"
		fi
	fi

	while IFS= read -r line; do
		case "$line" in '' | '#'*) continue ;; esac
		if ! valid_key "$line"; then
			warn "ignoring line that is not a valid public key: ${line:0:40}..."
			continue
		fi
		local want
		want="$(key_fingerprint_fields "$line")"
		if [ -f "$auth_keys" ] && grep -qF -- "$want" "$auth_keys" 2>/dev/null; then
			skip "already present: $(printf '%s' "$want" | cut -c1-24)..."
			continue
		fi
		if [ "$DRY_RUN" -eq 0 ]; then
			printf '%s\n' "$line" >>"$auth_keys"
		fi
		added=$((added + 1))
		SSH_KEYS_PENDING=$((SSH_KEYS_PENDING + 1))
		if [ "$DRY_RUN" -eq 1 ]; then
			ok "would add key: $(describe_key "$line")"
		else
			ok "added key: $(describe_key "$line")"
		fi
	done <<EOF
$raw
EOF

	if [ "$added" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
		record "$added SSH key(s) added to $auth_keys"
	fi
	if [ "$DRY_RUN" -eq 0 ]; then
		ok "$ssh_dir is 700, authorized_keys is 600"
	fi
}

# ----------------------------------------------------------------- github ---
# Read a pasted private key from the terminal. Deliberately not a --github-key
# VALUE flag: a key passed as an argument lands in shell history and in `ps`.
read_pasted_key() {
	local line out=''
	: 2>/dev/null </dev/tty || die "no terminal to paste into; use --github-key PATH instead"
	{
		printf 'Paste the private key for GitHub, including the\n'
		printf -- '-----BEGIN ... ----- and -----END ... ----- lines.\n\n'
	} >/dev/tty
	while :; do
		IFS= read -r line || { [ -n "$line" ] || break; }
		# Clipboards from Windows terminals carry CR; OpenSSH rejects it.
		line="${line%$'\r'}"
		out="$out$line"$'\n'
		case "$line" in *'-----END '*'PRIVATE KEY-----') break ;; esac
		line=''
	done </dev/tty
	printf '%s' "$out"
}

looks_like_private_key() {
	case "$1" in
	*'-----BEGIN '*'PRIVATE KEY-----'*'-----END '*'PRIVATE KEY-----'*) return 0 ;;
	*) return 1 ;;
	esac
}

# Sets GITHUB_KEY_PATH rather than printing it: the log helpers write to
# stdout, so command substitution would capture them too.
GITHUB_KEY_PATH=''
GITHUB_KEY_LOCKED=0
install_github_key() {
	local key_path="$HOME/.ssh/$GITHUB_KEY_NAME" material='' existed=0
	GITHUB_KEY_PATH="$key_path"
	[ -f "$key_path" ] && existed=1

	if [ "$GITHUB_KEY_SRC" = 'paste' ]; then
		material="$(read_pasted_key)"
	elif [ "$GITHUB_KEY_SRC" = '-' ]; then
		material="$(cat)"
	else
		[ -r "$GITHUB_KEY_SRC" ] || die "cannot read private key: $GITHUB_KEY_SRC"
		material="$(cat "$GITHUB_KEY_SRC")"
	fi

	# Same for keys arriving from a file written on Windows.
	case "$material" in
	*$'\r'*) material="$(printf '%s' "$material" | tr -d '\r')" ;;
	esac

	# Checked before the generic test so a .ppk gets the useful message.
	case "$material" in
	*'PuTTY-User-Key-File'*)
		die "PuTTY .ppk keys need converting first: puttygen key.ppk -O private-openssh -o key"
		;;
	esac
	case "$material" in
	*'-----BEGIN '*'PUBLIC KEY-----'* | 'ssh-'* | 'ecdsa-'*)
		die "that is a public key; --github-key takes the private half (no .pub)"
		;;
	esac
	if ! looks_like_private_key "$material"; then
		die "that does not look like an OpenSSH private key (no BEGIN/END block)"
	fi

	if [ -f "$key_path" ] && [ "$material" != "$(cat "$key_path" 2>/dev/null)" ]; then
		die "$key_path already holds a different key; move it aside or pass --github-key-name"
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "would install the private key as $key_path (mode 600)"
		return 0
	fi

	# Create with a tight umask so the key is never briefly world-readable.
	local old_umask
	old_umask="$(umask)"
	umask 077
	printf '%s' "$material" >"$key_path"
	# OpenSSH rejects a key file whose final line lacks a newline.
	case "$material" in
	*$'\n') : ;;
	*) printf '\n' >>"$key_path" ;;
	esac
	umask "$old_umask"
	chmod 600 "$key_path"
	if [ "$existed" -eq 1 ]; then
		skip "private key already at $key_path (mode 600)"
	else
		ok "private key installed at $key_path (mode 600)"
	fi

	# Derive the public key when the private one is not passphrase-protected.
	if have ssh-keygen; then
		local pub
		if pub="$(ssh-keygen -y -P '' -f "$key_path" 2>/dev/null)"; then
			printf '%s\n' "$pub" >"$key_path.pub"
			chmod 644 "$key_path.pub"
			ok "public key derived: $(describe_key "$pub")"
			record "add this key to https://github.com/settings/keys if it is not there yet:"
			record "  $(cat "$key_path.pub")"
		else
			GITHUB_KEY_LOCKED=1
			note "the key is passphrase-protected; unlock it per session with:"
			# shellcheck disable=SC2016  # printed for the user to run
			note '  eval "$(ssh-agent -s)" && ssh-add '"$key_path"
		fi
	fi
}

# GitHub's host keys, straight from their HTTPS API, so the first connection
# is verified rather than trusted blindly.
trust_github_host_keys() {
	local known="$HOME/.ssh/known_hosts" keys='' line added=0
	keys="$(http_get https://api.github.com/meta 2>/dev/null |
		tr ',' '\n' |
		grep -oE '(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+' || true)"

	if [ -z "$keys" ]; then
		note "could not fetch GitHub's host keys from api.github.com"
		note "  the first git connection will ask you to confirm the fingerprint"
		return 0
	fi

	[ "$DRY_RUN" -eq 1 ] || { [ -f "$known" ] || : >"$known"; }
	[ "$DRY_RUN" -eq 1 ] || chmod 600 "$known"
	if [ -s "$known" ] && [ "$(tail -c 1 "$known" | wc -l)" -eq 0 ]; then
		[ "$DRY_RUN" -eq 1 ] || printf '\n' >>"$known"
	fi

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ -f "$known" ] && grep -qF -- "$line" "$known" 2>/dev/null; then
			continue
		fi
		[ "$DRY_RUN" -eq 1 ] || printf 'github.com %s\n' "$line" >>"$known"
		added=$((added + 1))
	done <<EOF
$keys
EOF

	if [ "$added" -gt 0 ]; then
		if [ "$DRY_RUN" -eq 1 ]; then
			ok "would pin $added GitHub host key(s) in $known"
		else
			ok "pinned $added GitHub host key(s) in $known"
		fi
	else
		skip "GitHub host keys already in known_hosts"
	fi
}

configure_ssh_config() {
	local key_path="$1" cfg="$HOME/.ssh/config"
	if printf 'Host github.com\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n' \
		"$key_path" | apply_block "$cfg"; then
		[ "$DRY_RUN" -eq 1 ] || chmod 600 "$cfg"
		if [ "$DRY_RUN" -eq 1 ]; then
			ok "would add a github.com block to $cfg"
		else
			ok "github.com block written to $cfg"
		fi
	else
		skip "$cfg already up to date"
	fi
}

configure_git_identity() {
	have git || {
		note "git is not installed; skipping name/email (apt-get install git)"
		return 0
	}
	local field value
	for field in name email; do
		case "$field" in
		name) value="$GIT_NAME" ;;
		email) value="$GIT_EMAIL" ;;
		esac
		[ -n "$value" ] || continue
		if [ "$(git config --global "user.$field" 2>/dev/null || true)" = "$value" ]; then
			skip "git user.$field already set"
			continue
		fi
		if [ "$DRY_RUN" -eq 1 ]; then
			ok "would set git user.$field to $value"
		else
			git config --global "user.$field" "$value"
			ok "git user.$field set to $value"
		fi
	done
}

verify_github() {
	have ssh || return 0
	[ "$DRY_RUN" -eq 0 ] || return 0
	if [ "$GITHUB_KEY_LOCKED" -eq 1 ]; then
		# An unattended check cannot unlock the key, so a failure here would
		# say nothing about whether GitHub accepts it.
		skip "skipping the connection check: the key needs its passphrase"
		record "load the key, then check with: ssh -T git@github.com"
		return 0
	fi
	local out
	# `ssh -T git@github.com` exits 1 even on success, so match the banner.
	# The key and known_hosts are named explicitly: ssh resolves "~" from the
	# password database, and an agent key could otherwise authenticate here
	# and make the key we just installed look good when it is not.
	out="$(ssh -F "$HOME/.ssh/config" \
		-i "$GITHUB_KEY_PATH" \
		-o IdentitiesOnly=yes \
		-o IdentityAgent=none \
		-o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
		-o BatchMode=yes -o ConnectTimeout=10 \
		-T git@github.com 2>&1 || true)"
	case "$out" in
	*"successfully authenticated"*)
		ok "GitHub authentication works: ${out#Hi }"
		record "GitHub is ready: git clone git@github.com:OWNER/REPO.git"
		;;
	*"Permission denied"*)
		note "GitHub refused the key. Add the public key to your account:"
		note "  https://github.com/settings/keys"
		;;
	*)
		note "could not verify the GitHub connection: ${out%%$'\n'*}"
		;;
	esac
}

configure_github() {
	step "GitHub access"
	if [ -z "$GITHUB_KEY_SRC" ]; then
		skip "no private key given (--github-key PATH | --github-key-paste)"
		if [ -n "$GIT_NAME" ] || [ -n "$GIT_EMAIL" ]; then
			configure_git_identity
		fi
		return
	fi

	if [ "$DRY_RUN" -eq 0 ]; then
		mkdir -p "$HOME/.ssh"
		chmod 700 "$HOME/.ssh"
	fi

	install_github_key
	trust_github_host_keys
	configure_ssh_config "$GITHUB_KEY_PATH"
	configure_git_identity
	verify_github
}

# --------------------------------------------------- system default editor ---
configure_system_editor() {
	step "System default editor"
	if [ "$DO_EDITOR" -eq 0 ]; then
		skip "disabled with --no-editor"
		return
	fi
	if ! have "$EDITOR_NAME"; then
		# Not fatal: Debian may still register a variant such as vim.tiny,
		# and the rc block only exports EDITOR when the binary exists.
		warn "'$EDITOR_NAME' is not on PATH; EDITOR/VISUAL stay unset until it is installed"
	fi
	if ! is_debian_like; then
		skip "update-alternatives is Debian/Ubuntu only; EDITOR/VISUAL still set"
		return
	fi
	if ! have update-alternatives; then
		skip "update-alternatives not available"
		return
	fi

	local target current
	# Pick the registered alternative that matches the editor, e.g. vim ->
	# /usr/bin/vim.basic on Debian.
	target="$(update-alternatives --list editor 2>/dev/null |
		grep -E "/${EDITOR_NAME}(\..+)?$" | head -n 1 || true)"
	if [ -z "$target" ]; then
		warn "$EDITOR_NAME is not a registered 'editor' alternative"
		return
	fi

	current="$(update-alternatives --query editor 2>/dev/null |
		awk '/^Value:/ {print $2}' || true)"
	if [ "$current" = "$target" ]; then
		skip "system editor is already $target"
		return
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "would set system editor to $target"
		return
	fi
	if [ "$ROOT_OK" -eq 0 ]; then
		warn "need root to set the system editor"
		warn "  run: $(as_root_hint "update-alternatives --set editor $target")"
		explain_no_root
		return
	fi
	if as_root update-alternatives --set editor "$target" >/dev/null 2>&1; then
		ok "system editor set to $target"
		record "system editor is now $target"
	else
		warn "update-alternatives --set editor $target failed"
	fi
}

# ------------------------------------------------------- passwordless sudo ---
configure_passwordless_sudo() {
	step "Passwordless sudo"
	if [ "$DO_SUDO" -eq 0 ]; then
		skip "not requested (opt in with --passwordless-sudo)"
		return
	fi
	if ! is_debian_like; then
		skip "only configured on Debian/Ubuntu"
		return
	fi
	if [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
		skip "$(id -un) is not in the sudo group"
		return
	fi

	local file='/etc/sudoers.d/99-passwordless-sudo'
	local content='%sudo ALL=(ALL:ALL) NOPASSWD: ALL'

	if [ -f "$file" ] && grep -qxF -- "$content" "$file" 2>/dev/null; then
		skip "already configured in $file"
		return
	fi

	note "passwordless sudo lets every member of the sudo group run any"
	note "  command as root with no password. Only do this on machines you"
	note "  control, and never on a shared or internet-facing host."

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "would write $file"
		return
	fi
	if [ "$ROOT_OK" -eq 0 ]; then
		warn "need root to write $file"
		warn "  run: echo '$content' | $(as_root_hint "tee $file") && $(as_root_hint "chmod 440 $file")"
		explain_no_root
		return
	fi

	local tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/sudoers.XXXXXX")"
	printf '%s\n' "$content" >"$tmp"
	chmod 0440 "$tmp"

	# Never install an unvalidated sudoers file: a syntax error there locks
	# sudo out for everyone.
	local visudo=''
	for candidate in visudo /usr/sbin/visudo /sbin/visudo; do
		have "$candidate" && visudo="$candidate" && break
	done
	if [ -n "$visudo" ]; then
		if ! as_root "$visudo" -c -q -f "$tmp" >/dev/null 2>&1; then
			rm -f "$tmp"
			die "generated sudoers file failed visudo validation; nothing written"
		fi
	else
		warn "visudo not found; installing without validation"
	fi

	if as_root install -m 0440 -o root -g root "$tmp" "$file"; then
		rm -f "$tmp"
		ok "wrote $file"
		record "passwordless sudo enabled for the sudo group"
	else
		rm -f "$tmp"
		warn "could not write $file"
	fi
}

# --------------------------------------------------------------- packages ---
configure_packages() {
	step "Base packages"
	if [ "$DO_PACKAGES" -eq 0 ]; then
		skip "not requested (--install-packages)"
		return
	fi
	if ! is_debian_like; then
		skip "apt-get is Debian/Ubuntu only"
		return
	fi

	local missing='' pkg
	for pkg in $PACKAGES; do
		if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
			missing="$missing $pkg"
		fi
	done
	missing="${missing# }"

	if [ -z "$missing" ]; then
		skip "already installed: $PACKAGES"
		return
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "would install: $missing"
		return
	fi
	if [ "$ROOT_OK" -eq 0 ]; then
		warn "need root to install packages"
		warn "  run: $(as_root_hint "apt-get install -y $missing")"
		explain_no_root
		return
	fi

	say_running "installing: $missing"
	if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
		warn "apt-get update failed; trying the install anyway"
	fi
	# shellcheck disable=SC2086  # the list is intentionally split into args
	if as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing >/dev/null 2>&1; then
		ok "installed: $missing"
		record "installed packages: $missing"
	else
		warn "could not install: $missing"
	fi
}

# ---------------------------------------------------------- ssh hardening ---
sshd_binary() {
	local c
	for c in sshd /usr/sbin/sshd /sbin/sshd; do
		if have "$c"; then
			printf '%s' "$c"
			return 0
		fi
	done
	return 1
}

# Count key lines in a file, ignoring blanks and comments.
count_keys() {
	[ -f "$1" ] || return 0
	grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$1" 2>/dev/null || true
}

sshd_running() {
	if have systemctl; then
		systemctl is-active --quiet ssh 2>/dev/null && return 0
		systemctl is-active --quiet sshd 2>/dev/null && return 0
	fi
	have pgrep && pgrep -x sshd >/dev/null 2>&1 && return 0
	return 1
}

reload_sshd() {
	local unit
	if have systemctl; then
		for unit in ssh sshd; do
			if systemctl is-active --quiet "$unit" 2>/dev/null; then
				as_root systemctl reload "$unit" >/dev/null 2>&1 && return 0
			fi
		done
	fi
	if have service; then
		as_root service ssh reload >/dev/null 2>&1 && return 0
		as_root service sshd reload >/dev/null 2>&1 && return 0
	fi
	return 1
}

schedule_ssh_revert() {
	local dropin="$1" seconds="$2" script reload

	reload="systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true"
	# One line on purpose. systemd-run rewrites embedded newlines as a
	# literal \n, which silently turns the script into nonsense and leaves
	# you trusting a safety net that never fires.
	script="[ -f $SSH_CONFIRM_FILE ] || { rm -f $dropin; $reload; }"

	if have systemctl; then
		as_root systemctl stop bootstrap-ssh-revert.timer >/dev/null 2>&1 || true
		as_root systemctl reset-failed bootstrap-ssh-revert >/dev/null 2>&1 || true
	fi

	# A transient systemd timer survives this SSH session ending; a plain
	# background job may not, so it is only the fallback.
	# AccuracySec defaults to a minute, which would let the revert drift well
	# past the deadline the user was told to trust.
	if have systemd-run && as_root systemd-run --quiet --collect \
		--on-active="${seconds}s" --unit=bootstrap-ssh-revert \
		--timer-property=AccuracySec=1s \
		/bin/sh -c "$script" >/dev/null 2>&1; then
		return 0
	fi
	if have setsid; then
		as_root setsid /bin/sh -c "sleep $seconds; $script" >/dev/null 2>&1 &
		return 0
	fi
	as_root nohup /bin/sh -c "sleep $seconds; $script" >/dev/null 2>&1 &
	return 0
}

configure_ssh_hardening() {
	step "SSH hardening"
	if [ "$DO_HARDEN_SSH" -eq 0 ]; then
		skip "not requested (--harden-ssh, or --harden for the full set)"
		return
	fi

	local sshd_bin
	if ! sshd_bin="$(sshd_binary)"; then
		skip "no sshd on this machine, nothing to harden"
		return
	fi
	if [ ! -f /etc/ssh/sshd_config ]; then
		skip "/etc/ssh/sshd_config not found"
		return
	fi
	# Drop-ins are only read if the main config includes them, and the
	# include must already be there: appending one would land after the
	# settings it needs to override.
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
		warn "this sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf' line,"
		warn "  so a drop-in would be ignored. Edit /etc/ssh/sshd_config by hand:"
		warn "    PasswordAuthentication no"
		warn "    PermitRootLogin $PERMIT_ROOT_LOGIN"
		return
	fi

	# The lockout guard. Turning off password authentication without a key
	# in place makes the machine unreachable.
	local auth_keys="$HOME/.ssh/authorized_keys" n
	n="$(count_keys "$auth_keys")"
	n="${n:-0}"
	# In a dry run the keys are not on disk yet, so count the ones this same
	# command would have installed; otherwise it reports a lockout that a
	# real run would never hit.
	[ "$DRY_RUN" -eq 1 ] && n=$((n + SSH_KEYS_PENDING))
	if [ "$n" -lt 1 ]; then
		warn "refusing to disable password logins: no key in $auth_keys"
		warn "  install one first, e.g. --github-user YOUR_USERNAME"
		return
	fi
	ok "$n key(s) in $auth_keys, so key login will keep working"

	if [ "$ROOT_OK" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
		warn "need root to write $SSH_DROPIN"
		explain_no_root
		return
	fi

	# KbdInteractiveAuthentication is the modern spelling; sshd older than
	# 8.7 (Ubuntu 20.04) only knows the old one.
	local kbd='KbdInteractiveAuthentication'
	if [ "$DRY_RUN" -eq 0 ] &&
		! as_root "$sshd_bin" -T 2>/dev/null | grep -q '^kbdinteractiveauthentication'; then
		kbd='ChallengeResponseAuthentication'
	fi

	local content
	content="# Written by bootstrap.sh. Delete this file to undo.
# Sorted early on purpose: sshd uses the FIRST value it sees for a keyword,
# so a later file such as 50-cloud-init.conf would otherwise win.
PubkeyAuthentication yes
PasswordAuthentication no
$kbd no
PermitRootLogin $PERMIT_ROOT_LOGIN
LoginGraceTime 30"

	if [ -f "$SSH_DROPIN" ] && [ "$(cat "$SSH_DROPIN" 2>/dev/null)" = "$content" ]; then
		skip "$SSH_DROPIN already up to date"
		return
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "would write $SSH_DROPIN (password logins off, root: $PERMIT_ROOT_LOGIN)"
		[ "$SSH_REVERT_SECONDS" -gt 0 ] &&
			ok "would schedule an automatic revert in ${SSH_REVERT_SECONDS}s"
		return
	fi

	local tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/sshd.XXXXXX")"
	printf '%s\n' "$content" >"$tmp"
	as_root install -m 0644 -o root -g root "$tmp" "$SSH_DROPIN"
	rm -f "$tmp"

	# Validate the whole configuration, not just this file.
	if ! as_root "$sshd_bin" -t >/dev/null 2>&1; then
		as_root rm -f "$SSH_DROPIN"
		die "sshd rejected the new configuration; it has been removed and nothing changed"
	fi
	ok "$SSH_DROPIN written and validated by sshd -t"

	as_root rm -f "$SSH_CONFIRM_FILE"
	if [ "$SSH_REVERT_SECONDS" -gt 0 ]; then
		if schedule_ssh_revert "$SSH_DROPIN" "$SSH_REVERT_SECONDS"; then
			ok "automatic revert armed: these settings undo themselves in ${SSH_REVERT_SECONDS}s"
		else
			warn "could not arm the automatic revert; you are on your own here"
		fi
	fi

	if ! sshd_running; then
		note "sshd is not running; these settings apply when it next starts"
	elif reload_sshd; then
		ok "sshd reloaded (your current session stays open)"
	else
		warn "could not reload sshd, so the file is written but not yet active."
		warn "  It WILL apply at the next restart. Apply it now with:"
		warn "    $(as_root_hint "systemctl reload ssh")"
	fi

	SSH_HARDENED=1
	record "password logins are off; root login: $PERMIT_ROOT_LOGIN"
}

# ------------------------------------------------------------- root login ---
configure_root_lock() {
	step "Root password"
	if [ "$DO_LOCK_ROOT" -eq 0 ]; then
		skip "not requested (--lock-root, or --harden for the full set)"
		return
	fi
	if ! have passwd; then
		skip "passwd is not available"
		return
	fi

	local status
	status="$(as_root passwd -S root 2>/dev/null | awk '{print $2}' || true)"
	case "$status" in
	L | LK)
		skip "root password is already locked"
		return
		;;
	esac

	# Locking the password is only safe while another way in still exists.
	if [ "$(id -u)" -ne 0 ]; then
		if [ "$ROOT_OK" -eq 0 ]; then
			warn "need root to lock the root password"
			explain_no_root
			return
		fi
	elif [ "$(count_keys "$HOME/.ssh/authorized_keys")" -lt 1 ] && [ "$DO_SUDO" -eq 0 ]; then
		warn "refusing to lock the root password: you are root, root has no"
		warn "  authorized key, and no sudo user was configured. You would be"
		warn "  locked out. Install a key first."
		return
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "would lock the root password (key login and sudo keep working)"
		return
	fi
	if as_root passwd -l root >/dev/null 2>&1; then
		ok "root password locked; keys and sudo are unaffected"
		note "single-user recovery normally asks for this password, so keep"
		note "  console or rescue-mode access in mind before rebooting."
		record "root password locked"
	else
		warn "could not lock the root password"
	fi
}

# ------------------------------------------------------------------- main ---
main() {
	parse_args "$@"
	resolve_shell
	init_privilege

	[ "$QUIET" -eq 1 ] || printf '%s %s%s\n' "$PROGRAM" "$VERSION" \
		"$([ "$DRY_RUN" -eq 1 ] && printf ' (dry run: nothing will change)')"

	# Packages first: later steps look for vim, git and ssh-keygen.
	configure_packages
	configure_shell
	configure_ssh
	configure_github
	configure_system_editor
	configure_passwordless_sudo
	# Hardening last, once a key is in place for the lockout guard to find.
	configure_ssh_hardening
	configure_root_lock

	step "Done"
	if [ ${#CHANGES[@]} -eq 0 ]; then
		ok "nothing to change"
	else
		local c
		for c in "${CHANGES[@]}"; do ok "$c"; done
	fi
	[ "$WARNINGS" -gt 0 ] && printf '  %s%s warning(s) above%s\n' \
		"$C_YELLOW" "$WARNINGS" "$C_RESET" >&2

	if [ "$SSH_HARDENED" -eq 1 ] && [ "$SSH_REVERT_SECONDS" -gt 0 ]; then
		printf '\n%s==>%s %sACTION NEEDED WITHIN %ss%s\n' \
			"$C_YELLOW" "$C_RESET" "$C_YELLOW" "$SSH_REVERT_SECONDS" "$C_RESET"
		printf '  Keep this session open. From a %snew%s terminal, check that\n' \
			"$C_YELLOW" "$C_RESET"
		printf '  you can still log in:\n\n'
		printf '      ssh %s@%s\n\n' "$(id -un)" "$(hostname 2>/dev/null || echo THIS-HOST)"
		printf '  Once that works, keep the new settings:\n\n'
		printf '      %s\n\n' "$(as_root_hint "touch $SSH_CONFIRM_FILE")"
		printf '  Do nothing and password logins come back on their own,\n'
		printf '  so a mistake here costs you %s seconds, not the server.\n' \
			"$SSH_REVERT_SECONDS"
	fi
	return 0
}

main "$@"
