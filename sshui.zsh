# sshui — zsh integration.
#
# Install:
#     SSHUI_MODE=key,enter
#     source /path/to/sshui.zsh      # in ~/.zshrc, AFTER oh-my-zsh if you use it
#
# SSHUI_MODE is a comma-separated list. Default: key,enter
#
#   key     Bind a key (SSHUI_KEY, default ^S) that opens the picker and drops
#           the chosen host onto your command line.
#
#   enter   Pressing ENTER on a line containing nothing but `ssh` opens the
#           picker instead of printing ssh's usage message.
#
#   wrap    Define a shell function named `ssh`, so bare `ssh` opens the picker.
#           NOTE: this shadows the `ssh` command word. Terminals that ship their
#           own ssh completion — Warp, and anything Fig-derived — key off that
#           word and will stop completing hostnames. Prefer `enter`, which gives
#           the same bare-`ssh` behaviour while leaving ssh as a real command.
#
#   off     Load nothing. Use the `sshui` command directly.
#
# Other knobs:
#   SSHUI_KEY=^S            key for `key` mode (zsh bindkey syntax)
#   SSHUI_KEY_ACCEPT=1      run the command immediately instead of leaving it
#                           on the line for you to edit
#   SSHUI_EXEC=1            connect from inside the shell function instead of
#                           putting `ssh <host>` on your prompt. Faster by one
#                           keypress, but the terminal never sees an `ssh`
#                           command line — Warp's native SSH block and anything
#                           else keying off the typed command won't trigger.
#   SSHUI_BIN=/path/to/sshui   override engine autodetection

# Interactive shells only — scripts and cron must always get the real ssh.
[[ -o interactive ]] || return 0

: ${SSHUI_MODE:=key,enter}
: ${SSHUI_KEY:=^S}
: ${SSHUI_KEY_ACCEPT:=0}
: ${SSHUI_EXEC:=0}

# --- locate the engine ------------------------------------------------------
if [[ -z ${SSHUI_BIN:-} ]]; then
  # ${(%):-%x} is the file being sourced; :A resolves symlinks, :h takes the dir
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
typeset -g SSHUI_BIN SSHUI_MODE SSHUI_KEY SSHUI_KEY_ACCEPT SSHUI_EXEC

# Hand a picked host back to the shell as a real command line.
#
# `print -z` pushes it onto the editor buffer stack, so it appears on your next
# prompt and you submit it yourself. That matters: terminals with native SSH
# integration (Warp's session blocks, and anything else keying off the typed
# command) only see `ssh <host>` if the shell actually runs it as a command.
# Connecting from inside this function instead makes ssh invisible to them —
# the terminal saw `sshui`, not `ssh`.
_sshui_dispatch() {
  local target=${1-}
  [[ -n $target ]] || return 0
  if (( SSHUI_EXEC )); then
    print -s -r -- "ssh $target"
    command ssh "$target"
  else
    print -z -r -- "ssh $target"
  fi
}

# `sshui scan`, `sshui list`, ... without needing it on $PATH. Bare `sshui`
# (or `sshui <query>`) opens the picker and routes through _sshui_dispatch,
# rather than letting the script connect on its own.
sshui() {
  case ${1-} in
    scan|list|ls|edit|help|-h|--help|choose|__*)
      "$SSHUI_BIN" "$@"
      return $?
      ;;
  esac
  _sshui_dispatch "$("$SSHUI_BIN" choose "${1-}")"
}

[[ ,$SSHUI_MODE, == *,off,* ]] && return 0

# --- mode: key --------------------------------------------------------------
# Opens the picker and inserts the host at the cursor. Never touches `ssh`.
sshui-insert-host() {
  local target
  target=$("$SSHUI_BIN" choose) || target=""

  if [[ -n $target ]]; then
    if [[ -z $LBUFFER$RBUFFER ]]; then
      # empty line: write the whole command
      LBUFFER="ssh $target"
    else
      # mid-line (`scp file <key>`, `ssh -v <key>`): just the host, spaced
      [[ $LBUFFER == *[[:space:]] || -z $LBUFFER ]] || LBUFFER+=" "
      LBUFFER+="$target"
    fi
    if (( SSHUI_KEY_ACCEPT )); then
      zle accept-line
      return 0
    fi
  fi
  zle reset-prompt
}

# --- mode: enter ------------------------------------------------------------
# A line that is exactly `ssh` becomes `ssh <picked>`. `ssh` stays a real
# command, so terminal-native completion is unaffected.
sshui-accept-line() {
  if [[ ${BUFFER//[[:space:]]/} == ssh ]]; then
    local target
    target=$("$SSHUI_BIN" choose) || target=""
    if [[ -z $target ]]; then
      # cancelled — clear the line rather than running bare ssh
      BUFFER=""
      zle reset-prompt
      return 0
    fi
    BUFFER="ssh $target"
    CURSOR=$#BUFFER
  fi
  zle .accept-line
}

# --- mode: wrap -------------------------------------------------------------
sshui-install-wrapper() {
  # An alias would win over our function at parse time; drop it first.
  unalias ssh 2>/dev/null
  ssh() {
    # Any argument, or a non-terminal stdout, means "just be ssh".
    if (( $# > 0 )) || [[ ! -t 1 ]]; then
      command ssh "$@"
      return $?
    fi
    _sshui_dispatch "$("$SSHUI_BIN" choose)"
  }
}

# --- apply ------------------------------------------------------------------
_sshui_applied=0

if [[ ,$SSHUI_MODE, == *,key,* ]]; then
  # ^S is XOFF under legacy terminal flow control; free it up so it can be bound.
  [[ $SSHUI_KEY == '^S' ]] && stty -ixon 2>/dev/null
  zle -N sshui-insert-host
  bindkey "$SSHUI_KEY" sshui-insert-host
  _sshui_applied=1
fi

if [[ ,$SSHUI_MODE, == *,enter,* ]]; then
  zle -N accept-line sshui-accept-line
  _sshui_applied=1
fi

if [[ ,$SSHUI_MODE, == *,wrap,* ]]; then
  sshui-install-wrapper
  _sshui_applied=1
fi

if (( ! _sshui_applied )); then
  print -u2 "sshui.zsh: SSHUI_MODE='$SSHUI_MODE' matched nothing (want: key, enter, wrap, off)"
fi
unset _sshui_applied

# zsh completion is keyed on the command word, so `ssh <TAB>` keeps using the
# stock _ssh completion in key/enter mode — and so does your terminal's own.
