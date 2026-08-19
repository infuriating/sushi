#!/usr/bin/env bash
#
# Wires sshui into ~/.zshrc. Idempotent — safe to re-run after moving the repo.
#
#   ./install.sh              install / update
#   ./install.sh --uninstall  remove the block from ~/.zshrc
#
# Nothing is copied anywhere: the sourced file stays in this checkout, so
# `git pull` is all an update takes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BEGIN="# >>> sshui >>>"
END="# <<< sshui <<<"

info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

strip_block() {
  [ -f "$ZSHRC" ] || return 0
  awk -v b="$BEGIN" -v e="$END" '
    index($0, b) { f = 1; next }
    index($0, e) { f = 0; next }
    !f' "$ZSHRC"
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$ZSHRC" ] && grep -Fq "$BEGIN" "$ZSHRC"; then
    cp "$ZSHRC" "$ZSHRC.sshui-backup"
    strip_block > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
    info "removed the sshui block from $ZSHRC (backup: $ZSHRC.sshui-backup)"
    info "open a new shell — your ssh command is back to normal"
  else
    info "nothing to remove: no sshui block in $ZSHRC"
  fi
  exit 0
fi

printf '\nsshui\n\n'

chmod +x "$HERE/sshui"
info "engine:      $HERE/sshui"
info "integration: $HERE/sshui.zsh"

# --- dependency check -------------------------------------------------------
command -v ssh >/dev/null 2>&1 || warn "ssh not found on PATH — that is unusual, check your setup"

if ! command -v fzf >/dev/null 2>&1; then
  warn "fzf not found. The picker needs it:  brew install fzf"
  warn "everything else (scan, list) works without it."
fi

case "${SHELL:-}" in
  *zsh) ;;
  *) warn "your login shell is ${SHELL:-unknown}, not zsh — the ssh wrapper is zsh-only" ;;
esac

# --- wire up ~/.zshrc -------------------------------------------------------
touch "$ZSHRC"
if grep -Fq "$BEGIN" "$ZSHRC"; then
  strip_block > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
  info "replaced the existing sshui block in $ZSHRC"
else
  info "added a sshui block to $ZSHRC"
fi

{
  printf '%s\n' "$BEGIN"
  printf '%s\n' "source \"$HERE/sshui.zsh\""
  printf '%s\n' "$END"
} >> "$ZSHRC"

# --- verify -----------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  if zsh -ic "source '$HERE/sshui.zsh'; [[ \$(whence -w ssh) == 'ssh: function' ]]" 2>/dev/null; then
    info "verified: bare \`ssh\` will open the picker"
  else
    warn "could not verify the wrapper loaded — run:  zsh -ic 'whence -w ssh'"
  fi
fi

cat <<EOF

Next:

  exec zsh
      pick up the change in this shell

  $HERE/sshui scan -n
      dry run — see what it found in your history, writes nothing

  $HERE/sshui scan
      import the hosts you pick into ~/.ssh/config

  ssh
      then just type ssh, with no arguments

\`ssh something\` is untouched — only the bare, argument-less form is intercepted.
Undo any time with:  $HERE/install.sh --uninstall

EOF
