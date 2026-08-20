#!/usr/bin/env bash
#
# Wires sushi into ~/.zshrc. Idempotent — safe to re-run after moving the repo
# or changing your mind about the mode.
#
#   ./install.sh                    install with the default mode (key,enter)
#   ./install.sh --mode=wrap        pick a mode explicitly
#   ./install.sh --key='^G'         pick the key for `key` mode
#   ./install.sh --uninstall        remove the block from ~/.zshrc
#
# Modes (see the header of sushi.zsh for the full description):
#   key     a keybinding puts a host on your command line
#   enter   pressing ENTER on a bare `ssh` opens the picker
#   wrap    `ssh` becomes a shell function  — shadows the command word
#   off     load nothing; use the `sushi` command
# Combine with commas: --mode=key,enter
#
# Nothing is copied anywhere: the sourced file stays in this checkout, so
# `git pull` is all an update takes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BEGIN="# >>> sushi >>>"
END="# <<< sushi <<<"

MODE=""
KEY='^S'
ACTION="install"

info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

for arg in "$@"; do
  case "$arg" in
    --uninstall) ACTION="uninstall" ;;
    --mode=*)    MODE="${arg#--mode=}" ;;
    --key=*)     KEY="${arg#--key=}" ;;
    -h|--help)   sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           warn "unknown argument: $arg"; exit 2 ;;
  esac
done

strip_block() {
  [ -f "$ZSHRC" ] || return 0
  awk -v b="$BEGIN" -v e="$END" '
    index($0, b) { f = 1; next }
    index($0, e) { f = 0; next }
    !f' "$ZSHRC"
}

if [ "$ACTION" = "uninstall" ]; then
  if [ -f "$ZSHRC" ] && grep -Fq "$BEGIN" "$ZSHRC"; then
    cp "$ZSHRC" "$ZSHRC.sushi-backup"
    strip_block > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
    info "removed the sushi block from $ZSHRC (backup: $ZSHRC.sushi-backup)"
    info "open a new shell to pick that up"
  else
    info "nothing to remove: no sushi block in $ZSHRC"
  fi
  exit 0
fi

printf '\nsushi\n\n'

chmod +x "$HERE/sushi" "$HERE/install.sh" "$HERE/test/run.sh" 2>/dev/null || true
info "engine:      $HERE/sushi"
info "integration: $HERE/sushi.zsh"

# --- dependencies -----------------------------------------------------------
command -v ssh >/dev/null 2>&1 || warn "ssh not found on PATH — that is unusual, check your setup"

# The picker is the reason most people install sushi, so "fzf not found" the
# first time you press the key is a bad first impression — check for it here
# instead. The install command comes from the engine (`sushi __fzfhint`) rather
# than being spelled out again: hardcoding `brew install fzf` was wrong advice on
# most machines sushi runs on, and wrong advice sends you after the wrong problem.
if command -v fzf >/dev/null 2>&1; then
  info "fzf:         $(command -v fzf)"
else
  FZF_CMD="$("$HERE/sushi" __fzfhint 2>/dev/null || true)"
  warn "fzf not found — the picker needs it."
  warn "everything else (scan, add, list) works without it."
  # Only offer when there is a real command to run and someone to answer. In CI,
  # or piped, this must stay a warning and nothing else.
  if [ -n "$FZF_CMD" ] && [ "${FZF_CMD#see }" = "$FZF_CMD" ] && [ -t 0 ]; then
    printf '  install it now with `%s`? [y/N] ' "$FZF_CMD"
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES)
        if sh -c "$FZF_CMD"; then
          if command -v fzf >/dev/null 2>&1; then
            info "fzf:         $(command -v fzf)"
          else
            warn "that finished, but fzf is still not on PATH — check your shell's PATH"
          fi
        else
          warn "that did not work. Install fzf yourself, then re-run this script."
        fi
        ;;
      *) warn "skipped — install it later with:  $FZF_CMD" ;;
    esac
  else
    warn "install it with:  $FZF_CMD"
  fi
fi

case "${SHELL:-}" in
  *zsh) ;;
  *) warn "your login shell is ${SHELL:-unknown}, not zsh — the integration is zsh-only" ;;
esac

# --- choose a mode ----------------------------------------------------------
# Terminals with their own ssh completion break if `ssh` is shadowed by a
# function, so `wrap` is never the default and gets a warning on those.
OWN_COMPLETION=""
case "${TERM_PROGRAM:-}" in
  WarpTerminal) OWN_COMPLETION="Warp" ;;
esac
[ -n "${FIG_TERM:-}" ] && OWN_COMPLETION="${OWN_COMPLETION:-Fig}"

if [ -z "$MODE" ]; then
  MODE="key,enter"
  info "mode:        $MODE (default)"
else
  info "mode:        $MODE"
fi

case ",$MODE," in
  *,wrap,*)
    if [ -n "$OWN_COMPLETION" ]; then
      warn "$OWN_COMPLETION provides its own ssh completion, and \`wrap\` shadows the ssh"
      warn "command word, which disables it. \`--mode=enter\` gives you the same"
      warn "bare-\`ssh\` behaviour with ssh left as a real command."
    fi
    ;;
esac

case ",$MODE," in
  *,key,*|*,enter,*|*,wrap,*|*,off,*) ;;
  *) warn "mode '$MODE' contains nothing recognised (want: key, enter, wrap, off)"; exit 2 ;;
esac

if [ -n "$OWN_COMPLETION" ]; then
  case ",$MODE," in
    *,wrap,*) info "detected:    $OWN_COMPLETION (its ssh completion will be shadowed — see above)" ;;
    *)        info "detected:    $OWN_COMPLETION (its ssh completion is left intact)" ;;
  esac
fi

# --- wire up ~/.zshrc -------------------------------------------------------
touch "$ZSHRC"
if grep -Fq "$BEGIN" "$ZSHRC"; then
  strip_block > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
  info "replaced the existing sushi block in $ZSHRC"
else
  info "added a sushi block to $ZSHRC"
fi

# `: ${VAR:=x}` rather than `VAR=x`, so an exported value wins — that makes
#   SUSHI_MODE=off zsh -i
# a throwaway shell with the integration disabled, without editing anything.
{
  printf '%s\n' "$BEGIN"
  printf '%s\n' ": \${SUSHI_MODE:=$MODE}      # key | enter | wrap | off  (comma-separated)"
  printf '%s\n' ": \${SUSHI_KEY:='$KEY'}"
  printf '%s\n' "source \"$HERE/sushi.zsh\""
  printf '%s\n' "$END"
} >> "$ZSHRC"

# --- verify -----------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  probe="source '$HERE/sushi.zsh'"
  case ",$MODE," in
    *,wrap,*)  check="[[ \$(whence -w ssh) == 'ssh: function' ]]"; what="bare \`ssh\` opens the picker" ;;
    *,key,*)   check="bindkey '$KEY' | grep -q sushi-insert-host"; what="$KEY opens the picker" ;;
    *,enter,*) check="bindkey '^M' | grep -q sushi-accept-line"; what="ENTER on a bare \`ssh\` opens the picker" ;;
    *)         check="true"; what="the sushi command is available" ;;
  esac
  if SUSHI_MODE="$MODE" SUSHI_KEY="$KEY" SHELL_SESSIONS_DISABLE=1 \
     zsh -ic "SAVEHIST=0; $probe; $check" 2>/dev/null; then
    info "verified:    $what"
  else
    warn "could not verify the integration loaded — try:  zsh -ic 'source $HERE/sushi.zsh; bindkey $KEY'"
  fi
fi

cat <<EOF

Next:

  source ~/.zshrc
      pick up the change in this pane. Re-sourcing is a no-op if already loaded.

      Do NOT use \`exec zsh\` in Warp (or any terminal with shell integration):
      it replaces the shell the terminal bootstrapped, and that pane loses the
      terminal's own integration — native SSH blocks, completions and all.
      A brand-new tab or pane is always safe.

  $HERE/sushi scan -n
      dry run — see what it found in your history, writes nothing

  $HERE/sushi scan
      import the hosts you pick into ~/.ssh/config

Change your mind later:  $HERE/install.sh --mode=...
Remove it entirely:      $HERE/install.sh --uninstall

EOF
