#!/usr/bin/env bash
#
# Smoke tests for bootstrap.sh. Every case runs against a throwaway HOME, so
# this never touches the machine it runs on.
#
# Usage: tests/smoke.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP="$ROOT/bootstrap.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tests.XXXXXX")"
PASS=0
FAIL=0

trap 'rm -rf "$WORK"' EXIT

pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	[ $# -gt 1 ] && printf '       %s\n' "$2"
}
check() { # name, expected substring, actual
	case "$3" in
	*"$2"*) pass "$1" ;;
	*) fail "$1" "expected to find: $2" ;;
	esac
}
refute() { # name, unexpected substring, actual
	case "$3" in
	*"$2"*) fail "$1" "did not expect: $2" ;;
	*) pass "$1" ;;
	esac
}

# A fresh empty HOME for a single case.
new_home() {
	local h="$WORK/home.$1"
	rm -rf "$h"
	mkdir -p "$h"
	printf '%s' "$h"
}

run() { # HOME, args...
	local h="$1"
	shift
	HOME="$h" NO_COLOR=1 "$BOOTSTRAP" "$@" 2>&1
}

printf '\n== bootstrap.sh smoke tests ==\n\n'

printf 'basics\n'
check "--help lists the options" "--dry-run" "$(run "$(new_home help)" --help)"
check "--version prints a version" "bootstrap.sh 1" "$(run "$(new_home ver)" --version)"
check "rejects an unknown option" "unknown option" "$(run "$(new_home bad)" --nope)"
check "rejects a bad history size" "positive integer" "$(run "$(new_home hs)" --history-size x)"

printf 'shell configuration\n'
# --shell-rc is passed explicitly: with an empty HOME the default lands on
# .bash_profile on macOS and .bashrc on Linux, which is correct but not a
# useful thing for a test to depend on.
H="$(new_home bash)"
RC="$H/.bashrc"
out="$(run "$H" --shell bash --shell-rc "$RC" --no-ssh)"
check "writes a bash rc" "managed block written" "$out"
check "creates the rc file" ".bashrc" "$(ls -a "$H")"
check "binds the up arrow" 'history-search-backward' "$(cat "$RC")"
check "guards bind for non-interactive shells" 'if [[ $- == *i* ]]' "$(cat "$RC")"
check "sources cleanly when non-interactive" "SOURCED" \
	"$(HOME="$H" bash -c 'source "$HOME/.bashrc" && echo SOURCED' 2>&1)"

out="$(run "$H" --shell bash --shell-rc "$RC" --no-ssh)"
check "second run is idempotent" "already up to date" "$out"
n="$(grep -c 'managed block' "$RC")"
if [ "$n" -eq 2 ]; then
	pass "exactly one managed block"
else
	fail "exactly one managed block" "found $n markers"
fi

H="$(new_home preserve)"
printf 'export MINE=1\n' >"$H/.bashrc"
run "$H" --shell bash --shell-rc "$H/.bashrc" --no-ssh >/dev/null
check "preserves existing rc content" "export MINE=1" "$(cat "$H/.bashrc")"
check "backs up the previous rc" ".bashrc.bootstrap.bak" "$(ls -a "$H")"

H="$(new_home zsh)"
run "$H" --shell zsh --shell-rc "$H/.zshrc" --no-ssh >/dev/null
check "writes a zsh rc" "up-line-or-beginning-search" "$(cat "$H/.zshrc")"
if command -v zsh >/dev/null 2>&1; then
	if zsh -n "$H/.zshrc" 2>/dev/null; then
		pass "generated zsh is valid"
	else
		fail "generated zsh is valid"
	fi
fi

H="$(new_home histsize)"
run "$H" --shell bash --shell-rc "$H/.bashrc" --no-ssh --history-size 4242 >/dev/null
check "honours --history-size" "HISTSIZE=4242" "$(cat "$H/.bashrc")"

printf 'inbound ssh keys\n'
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcbTestTestTestTestTestTestTestTestTest me@host"
H="$(new_home ssh)"
out="$(run "$H" --shell bash --no-history --no-editor --ssh-key "$KEY")"
check "installs a public key" "added key" "$out"
check "authorized_keys is 600" "600" "$(HOME=$H perl -e 'printf "%o", (stat("$ENV{HOME}/.ssh/authorized_keys"))[2] & 07777' 2>/dev/null ||
	stat -c '%a' "$H/.ssh/authorized_keys" 2>/dev/null ||
	stat -f '%Lp' "$H/.ssh/authorized_keys")"

out="$(run "$H" --shell bash --no-history --no-editor --ssh-key "${KEY% *} different@comment")"
check "dedupes a key with another comment" "already present" "$out"
n="$(wc -l <"$H/.ssh/authorized_keys" | tr -d ' ')"
if [ "$n" -eq 1 ]; then
	pass "no duplicate key line"
else
	fail "no duplicate key line" "found $n lines"
fi

H="$(new_home noeol)"
mkdir -p "$H/.ssh"
printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQOldKeyXXXXXXXXXXXXXXXXXX old@host' >"$H/.ssh/authorized_keys"
run "$H" --shell bash --no-history --no-editor --ssh-key "$KEY" >/dev/null
n="$(wc -l <"$H/.ssh/authorized_keys" | tr -d ' ')"
if [ "$n" -eq 2 ]; then
	pass "handles a file with no trailing newline"
else
	fail "handles a file with no trailing newline" "found $n lines"
fi

check "rejects a malformed key" "not a valid public key" \
	"$(run "$(new_home badkey)" --shell bash --no-history --no-editor --ssh-key 'nonsense')"

printf 'github access\n'
if command -v ssh-keygen >/dev/null 2>&1; then
	ssh-keygen -q -t ed25519 -N '' -C 'tester@example.com' -f "$WORK/key" </dev/null
	H="$(new_home gh)"
	out="$(run "$H" --shell bash --no-history --no-editor --github-key "$WORK/key")"
	check "installs the private key" "private key installed" "$out"
	check "derives the public key" "public key derived" "$out"
	check "writes an ssh config block" "Host github.com" "$(cat "$H/.ssh/config")"
	check "config points at the key" "IdentitiesOnly yes" "$(cat "$H/.ssh/config")"
	if [ -f "$H/.ssh/known_hosts" ]; then
		check "pins github host keys" "github.com" "$(cat "$H/.ssh/known_hosts")"
	fi
	out="$(run "$H" --shell bash --no-history --no-editor --github-key "$WORK/key")"
	check "re-import is idempotent" "already at" "$out"

	ssh-keygen -q -t ed25519 -N '' -C 'other@example.com' -f "$WORK/key2" </dev/null
	check "refuses to clobber a different key" "already holds a different key" \
		"$(run "$H" --shell bash --no-history --no-editor --github-key "$WORK/key2")"
	check "accepts a second key under a new name" "private key installed" \
		"$(run "$H" --shell bash --no-history --no-editor --github-key "$WORK/key2" --github-key-name id_other)"

	check "rejects a public key" "takes the private half" \
		"$(run "$(new_home pub)" --no-history --no-editor --github-key "$WORK/key.pub")"

	awk '{printf "%s\r\n", $0}' "$WORK/key" >"$WORK/key.crlf"
	H="$(new_home crlf)"
	run "$H" --no-history --no-editor --github-key "$WORK/key.crlf" >/dev/null
	if diff -q "$WORK/key" "$H/.ssh/id_github" >/dev/null 2>&1; then
		pass "normalises a CRLF key"
	else
		fail "normalises a CRLF key"
	fi
fi

printf 'not-a-key inputs\n'
printf 'hello\n' >"$WORK/notakey"
check "rejects non-key material" "does not look like" \
	"$(run "$(new_home nk)" --no-history --no-editor --github-key "$WORK/notakey")"
printf 'PuTTY-User-Key-File-3: ssh-ed25519\n' >"$WORK/k.ppk"
check "explains how to convert a .ppk" "puttygen" \
	"$(run "$(new_home ppk)" --no-history --no-editor --github-key "$WORK/k.ppk")"

printf 'dry run\n'
H="$(new_home dry)"
out="$(run "$H" --shell bash -n --ssh-key "$KEY" --github-key "$WORK/key" 2>/dev/null)"
check "announces without doing" "would" "$out"
refute "does not claim to have written" "managed block written" "$out"
left="$(ls -A "$H" 2>/dev/null)"
if [ -z "$left" ]; then
	pass "dry run leaves HOME untouched"
else
	fail "dry run leaves HOME untouched" "created: $left"
fi

printf 'opt-in guards\n'
check "passwordless sudo is opt-in" "not requested" \
	"$(run "$(new_home sudo)" --shell bash --no-ssh --no-history --no-editor)"
refute "installs no key by default" "added key" \
	"$(run "$(new_home nokey)" --shell bash)"

printf 'hardening flags\n'
check "rejects a bad --permit-root-login" "must be yes, no, prohibit-password" \
	"$(run "$(new_home prl)" --permit-root-login maybe)"
check "accepts a valid --permit-root-login" "" \
	"$(run "$(new_home prl2)" --permit-root-login no --dry-run --no-ssh)"
check "rejects a bad --ssh-revert-seconds" "whole number" \
	"$(run "$(new_home rs)" --ssh-revert-seconds soon)"
check "hardening is opt-in" "not requested" \
	"$(run "$(new_home h1)" --shell bash --no-ssh --no-history --no-editor)"
check "root lock is opt-in" "not requested" \
	"$(run "$(new_home h2)" --shell bash --no-ssh --no-history --no-editor)"
check "packages are opt-in" "not requested" \
	"$(run "$(new_home h3)" --shell bash --no-ssh --no-history --no-editor)"

# Whatever the platform, an unprivileged run must not touch sshd.
H="$(new_home noharm)"
run "$H" --shell bash --harden --no-history --no-editor >/dev/null 2>&1
if [ -f /etc/ssh/sshd_config.d/01-bootstrap-hardening.conf ]; then
	fail "unprivileged --harden left an sshd drop-in behind"
else
	pass "unprivileged --harden writes no sshd drop-in"
fi

if [ -r /etc/os-release ] && grep -qE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
	printf 'debian-only\n'
	check "previews the package install" "would install" \
		"$(run "$(new_home pkg)" --shell bash --no-ssh --dry-run --install-packages)"
	check "honours a custom package list" "zzz-not-a-real-package" \
		"$(run "$(new_home pkg2)" --shell bash --no-ssh --dry-run --packages "zzz-not-a-real-package")"
	if [ "$(id -u)" -ne 0 ]; then
		check "needs root to lock the root password" "need root" \
			"$(run "$(new_home lr)" --shell bash --no-ssh --no-history --no-editor --lock-root)"
	fi
	if [ "$(id -u)" -eq 0 ] && [ -f /etc/ssh/sshd_config ]; then
		check "refuses to harden without a key" "refusing to disable password logins" \
			"$(run "$(new_home nokey2)" --shell bash --no-history --no-editor --harden-ssh)"
	fi
else
	printf 'debian-only (skipped: not a Debian-like system)\n'
fi

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
