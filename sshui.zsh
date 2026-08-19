# sshui — zsh integration.
#
# Bare `ssh` opens the fuzzy picker. `ssh` with any argument at all is passed
# through to the real binary untouched, so scripts, scp, rsync, git and your
# muscle memory are unaffected.
#
# Install:
#     source /path/to/sshui.zsh        # in ~/.zshrc, AFTER oh-my-zsh if you use it
#
# The engine (the `sshui` bash script) is found automatically if it sits next to
# this file. Otherwise set SSHUI_BIN=/path/to/sshui before sourcing.

# Interactive shells only — scripts and cron must always get the real ssh.
[[ -o interactive ]] || return 0

if [[ -z ${SSHUI_BIN:-} ]]; then
  # ${(%):-%x} is the file currently being sourced; :A resolves symlinks, :h takes the dir
  _sshui_dir=${${(%):-%x}:A:h}
  if [[ -x $_sshui_dir/sshui ]]; then
    SSHUI_BIN=$_sshui_dir/sshui
  else
    SSHUI_BIN=${commands[sshui]:-}
  fi
  unset _sshui_dir
fi

if [[ -z $SSHUI_BIN || ! -x $SSHUI_BIN ]]; then
  print -u2 "sshui.zsh: can't find the sshui script — set SSHUI_BIN=/path/to/sshui"
  return 1
fi
typeset -g SSHUI_BIN

# A framework or dotfile may have claimed `ssh` already; an alias would win over
# our function at parse time, so drop it first.
unalias ssh 2>/dev/null

ssh() {
  # Any arguments, or a non-terminal stdout, means "just be ssh".
  if (( $# > 0 )) || [[ ! -t 1 ]]; then
    command ssh "$@"
    return $?
  fi

  local target
  target=$("$SSHUI_BIN" choose) || return 0   # cancelled — leave $? clean
  [[ -n $target ]] || return 0

  # Put it in history so up-arrow works and the next `sshui scan` sees it.
  print -s -- "ssh $target"
  command ssh "$target"
}

# `sshui scan`, `sshui list`, ... without needing it on $PATH.
sshui() { "$SSHUI_BIN" "$@" }

# zsh's completion is keyed on the command word, so `ssh <TAB>` still uses the
# stock _ssh completion (which reads ~/.ssh/config) even though ssh is now a
# function. Nothing to do here.

# ---------------------------------------------------------------------------
# Optional: a ctrl-s widget that inserts an alias onto the current command line
# instead of connecting. Uncomment if you want it alongside the wrapper.
#
# sshui-insert-widget() {
#   local target
#   target=$("$SSHUI_BIN" choose) || return 0
#   [[ -n $target ]] || return 0
#   LBUFFER="${LBUFFER}${target}"
#   zle reset-prompt
# }
# zle -N sshui-insert-widget
# bindkey '^S' sshui-insert-widget
