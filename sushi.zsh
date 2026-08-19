# sushi — zsh integration.
#
# Install:
#     SUSHI_MODE=key,enter
#     source /path/to/sushi.zsh      # in ~/.zshrc, AFTER oh-my-zsh if you use it
#
# SUSHI_MODE is a comma-separated list. Default: key,enter
#
#   key     Bind a key (SUSHI_KEY, default ^S) that opens the picker and drops
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
#   off     Load nothing. Use the `sushi` command directly.
#
# Other knobs:
#   SUSHI_KEY=^S            key for `key` mode (zsh bindkey syntax)
#   SUSHI_KEY_ACCEPT=1      run the command immediately instead of leaving it
#                           on the line for you to edit
#   SUSHI_EXEC=1            connect from inside the shell function instead of
#                           putting `ssh <host>` on your prompt. Faster by one
#                           keypress, but the terminal never sees an `ssh`
#                           command line — Warp's native SSH block and anything
#                           else keying off the typed command won't trigger.
#   SUSHI_RETURN=^M         key `enter` mode binds (the RETURN key)
#   SUSHI_BIN=/path/to/sushi   override engine autodetection

# Interactive shells only — scripts and cron must always get the real ssh.
[[ -o interactive ]] || return 0

: ${SUSHI_MODE:=key,enter}
: ${SUSHI_KEY:=^S}
: ${SUSHI_KEY_ACCEPT:=0}
: ${SUSHI_EXEC:=0}
: ${SUSHI_RETURN:=^M}

# --- locate the engine ------------------------------------------------------
if [[ -z ${SUSHI_BIN:-} ]]; then
  # ${(%):-%x} is the file being sourced; :A resolves symlinks, :h takes the dir
  _sushi_dir=${${(%):-%x}:A:h}
  if [[ -x $_sushi_dir/sushi ]]; then
    SUSHI_BIN=$_sushi_dir/sushi
  elif [[ -f $_sushi_dir/sushi ]]; then
    # there but not executable — worth saying so, since "not found" sends you
    # looking for a missing file instead of a missing mode bit
    print -u2 "sushi.zsh: $_sushi_dir/sushi is not executable. Fix with:"
    print -u2 "    chmod +x $_sushi_dir/sushi"
    unset _sushi_dir
    return 1
  else
    SUSHI_BIN=${commands[sushi]:-}
  fi
  unset _sushi_dir
fi

if [[ -z $SUSHI_BIN ]]; then
  print -u2 "sushi.zsh: can't find the sushi script — set SUSHI_BIN=/path/to/sushi"
  return 1
fi
if [[ ! -x $SUSHI_BIN ]]; then
  print -u2 "sushi.zsh: SUSHI_BIN=$SUSHI_BIN is not executable — chmod +x it"
  return 1
fi
typeset -g SUSHI_BIN SUSHI_MODE SUSHI_KEY SUSHI_KEY_ACCEPT SUSHI_EXEC SUSHI_RETURN

# Hand a picked host back to the shell as a real command line.
#
# `print -z` pushes it onto the editor buffer stack, so it appears on your next
# prompt and you submit it yourself. That matters: terminals with native SSH
# integration (Warp's session blocks, and anything else keying off the typed
# command) only see `ssh <host>` if the shell actually runs it as a command.
# Connecting from inside this function instead makes ssh invisible to them —
# the terminal saw `sushi`, not `ssh`.
_sushi_dispatch() {
  local target=${1-}
  [[ -n $target ]] || return 0
  if (( SUSHI_EXEC )); then
    print -s -r -- "ssh $target"
    command ssh "$target"
  else
    print -z -r -- "ssh $target"
  fi
}

# `sushi scan`, `sushi list`, ... without needing it on $PATH. Bare `sushi`
# (or `sushi <query>`) opens the picker and routes through _sushi_dispatch,
# rather than letting the script connect on its own.
# The subcommand list comes from the engine itself (`sushi __subcommands`), not
# from a copy kept here. A hardcoded copy went stale the moment `ignore` was
# added, turning `sushi ignore` into a picker search for the word "ignore".
# Looked up on first use, so no cost at shell startup.
sushi() {
  local sub=${1-}

  # no arguments: the picker
  if [[ -z $sub ]]; then
    _sushi_dispatch "$("$SUSHI_BIN" choose)"
    return
  fi

  # flags, internals, or more than one argument: the engine's business
  if [[ $sub == -* || $sub == __* ]] || (( $# > 1 )); then
    "$SUSHI_BIN" "$@"
    return $?
  fi

  if [[ -z ${_sushi_subs-} ]]; then
    typeset -g _sushi_subs=" $("$SUSHI_BIN" __subcommands | tr '\n' ' ') "
  fi
  if [[ $_sushi_subs == *" $sub "* ]]; then
    "$SUSHI_BIN" "$@"
    return $?
  fi

  # a single unrecognised word is a picker query
  _sushi_dispatch "$("$SUSHI_BIN" choose "$sub")"
}

[[ ,$SUSHI_MODE, == *,off,* ]] && return 0

# --- mode: key --------------------------------------------------------------
# Opens the picker and inserts the host at the cursor. Never touches `ssh`.
sushi-insert-host() {
  local target
  target=$("$SUSHI_BIN" choose) || target=""

  if [[ -n $target ]]; then
    if [[ -z $LBUFFER$RBUFFER ]]; then
      # empty line: write the whole command
      LBUFFER="ssh $target"
    else
      # mid-line (`scp file <key>`, `ssh -v <key>`): just the host, spaced
      [[ $LBUFFER == *[[:space:]] || -z $LBUFFER ]] || LBUFFER+=" "
      LBUFFER+="$target"
    fi
    if (( SUSHI_KEY_ACCEPT )); then
      zle accept-line
      return 0
    fi
  fi
  zle reset-prompt
}

# --- mode: enter ------------------------------------------------------------
# A line that is exactly `ssh` becomes `ssh <picked>`. `ssh` stays a real
# command, so terminal-native completion is unaffected.
#
# This binds the RETURN key rather than redefining the `accept-line` widget.
# accept-line is contested territory — zsh-autosuggestions wraps it (and
# re-wraps on every precmd by default), zsh-syntax-highlighting wraps it, and
# terminals add their own. `zle -N accept-line ...` silently destroys whoever
# held it, and which side loses depends on load order, so the same .zshrc
# behaves differently in different shells. Worse, wrapping a wrapper that has
# already wrapped us builds an infinitely recursive chain.
#
# Binding ^M sidesteps all of it: we never own accept-line, we just delegate to
# whatever owns it *at the time the key is pressed* — by name, not by `.accept-line`,
# so any wrapper in place still runs.
sushi-accept-line() {
  if [[ ${BUFFER//[[:space:]]/} == ssh ]]; then
    local target
    target=$("$SUSHI_BIN" choose) || target=""
    if [[ -z $target ]]; then
      # cancelled — clear the line rather than running bare ssh
      BUFFER=""
      zle reset-prompt
      return 0
    fi
    BUFFER="ssh $target"
    CURSOR=$#BUFFER
  fi
  zle accept-line
}

# --- mode: wrap -------------------------------------------------------------
sushi-install-wrapper() {
  # An alias would win over our function at parse time; drop it first.
  unalias ssh 2>/dev/null
  ssh() {
    # Any argument, or a non-terminal stdout, means "just be ssh".
    if (( $# > 0 )) || [[ ! -t 1 ]]; then
      command ssh "$@"
      return $?
    fi
    _sushi_dispatch "$("$SUSHI_BIN" choose)"
  }
}

# --- apply ------------------------------------------------------------------
_sushi_applied=0

if [[ ,$SUSHI_MODE, == *,key,* ]]; then
  # ^S is XOFF under legacy terminal flow control; free it up so it can be bound.
  [[ $SUSHI_KEY == '^S' ]] && stty -ixon 2>/dev/null
  zle -N sushi-insert-host
  bindkey "$SUSHI_KEY" sushi-insert-host
  _sushi_applied=1
fi

if [[ ,$SUSHI_MODE, == *,enter,* ]]; then
  zle -N sushi-accept-line
  bindkey "$SUSHI_RETURN" sushi-accept-line
  _sushi_applied=1
fi

if [[ ,$SUSHI_MODE, == *,wrap,* ]]; then
  sushi-install-wrapper
  _sushi_applied=1
fi

if (( ! _sushi_applied )); then
  print -u2 "sushi.zsh: SUSHI_MODE='$SUSHI_MODE' matched nothing (want: key, enter, wrap, off)"
fi
unset _sushi_applied

# zsh completion is keyed on the command word, so `ssh <TAB>` keeps using the
# stock _ssh completion in key/enter mode — and so does your terminal's own.
