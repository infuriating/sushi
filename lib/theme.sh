# --------------------------------------------------------------------------- theme --
#
# Cyan -> magenta on near-black, taken off the sushi logo:
#   #22c7e8 cyan (top edge)   #8c6fe0 violet (the blend)
#   #ec4899 magenta (body)    #f472b6 rose (the inner swirl)
#   #14101f nori (base)       #fdf7fb rice (the top)
#
# The palette is a YAML file, and SUSHI_THEME says which one:
#
#   SUSHI_THEME=none          no colour at all; your terminal and FZF_DEFAULT_OPTS decide
#   SUSHI_THEME=sushi         the built-in palette below — the default, and reads no file
#   SUSHI_THEME=nord          themes/nord.yaml, looked up by theme_find below
#   SUSHI_THEME=~/mine.yaml   that exact file: anything with a / or a .yaml/.yml suffix
#
# A theme file names any of the six roles below — accent, heading, prompt,
# target, value, muted — plus fzf's own colour keys under `fzf:` and the pointer
# and marker under `symbols:`. Everything it leaves out keeps the built-in
# value. See themes/sushi.yaml.
#
# `sushi theme` prints which one you got and what is in it. SUSHI_FZF_OPTS is
# appended to every fzf call, so it still wins over all of this.
: "${SUSHI_THEME:=sushi}"
: "${SUSHI_FZF_OPTS:=}"

# The built-in theme, precomputed. themes/sushi.yaml is the same palette as YAML
# and is what you copy to make your own — the suite asserts the two render
# identically, so they cannot drift, and the file can be deleted without sushi
# losing its own colours.
#
# It is spelled out here rather than parsed on startup because theme_read costs
# a few milliseconds and *every* invocation would pay them: the fzf preview
# forks sushi once per row you move over. Choosing a theme file opts into that
# cost; the default does not.
theme_builtin() {
  THEME_NAME="sushi"
  C_ACCENT=$'\033[38;2;34;199;232m';    S_ACCENT='#22c7e8'
  C_HEADING=$'\033[38;2;140;111;224m';  S_HEADING='#8c6fe0'
  C_PROMPT=$'\033[38;2;236;72;153m';    S_PROMPT='#ec4899'
  C_TARGET=$'\033[38;2;244;114;182m';   S_TARGET='#f472b6'
  C_VALUE=$'\033[1;38;2;253;247;251m';  S_VALUE='bold "#fdf7fb"'
  C_MUTED=$'\033[38;2;122;110;145m';    S_MUTED='#7a6e91'
  # Only the colour keys every fzf since 0.24 understands: `label` and
  # `preview-border` look better but make older versions exit with a usage
  # error. "-1" leaves that part to the terminal, which is why your background
  # and its transparency show through instead of being painted over.
  FZF_COLORS='fg:#a99fbd,bg:-1,hl:#22c7e8,fg+:#fdf7fb,bg+:#241a33,hl+:#5ad9f5'
  FZF_COLORS="$FZF_COLORS,info:#8c6fe0,prompt:#ec4899,pointer:#ec4899"
  FZF_COLORS="$FZF_COLORS,marker:#22c7e8,border:#5b4a7d,spinner:#8c6fe0"
  FZF_COLORS="$FZF_COLORS,header:#8c6fe0,gutter:-1"
  SYM_POINTER='▍'
  SYM_MARKER='◆'
}

# One theme value -> one SGR sequence, left in $SGR. Empty for none/unset, so
# every call site can interpolate the palette unconditionally.
#   bold #fdf7fb -> ESC[1;38;2;253;247;251m       244 -> ESC[38;5;244m
# The answer goes in a variable rather than on stdout because a command
# substitution is a fork, and a theme file calls this once per role.
SGR=""
theme_sgr() {
  local tok attrs="" colour="" hex r g b
  SGR=""
  for tok in $1; do
    # `value: bold "#fdf7fb"` has to quote the hex — bare # starts a YAML
    # comment — so the quotes arrive here rather than being stripped upstream
    tok="${tok#[\"\']}"; tok="${tok%[\"\']}"
    case "$tok" in
      bold)       attrs="${attrs}1;" ;;
      dim|faint)  attrs="${attrs}2;" ;;
      italic)     attrs="${attrs}3;" ;;
      underline)  attrs="${attrs}4;" ;;
      reverse)    attrs="${attrs}7;" ;;
      *)          colour="$tok" ;;
    esac
  done
  case "$colour" in
    ''|none|default|-1)
      [ -n "$attrs" ] && printf -v SGR '\033[%sm' "${attrs%;}"
      return 0 ;;
    '#'*)
      hex="${colour#\#}"
      # #abc is the same colour as #aabbcc and shorter to type
      if [ "${#hex}" = 3 ]; then
        r="${hex%??}"; g="${hex#?}"; g="${g%?}"; b="${hex#??}"
        hex="$r$r$g$g$b$b"
      fi
      case "${#hex}:$hex" in
        6:*[!0-9a-fA-F]*|6:) warn "theme: not a colour: $colour"; return 0 ;;
        6:*) : ;;
        *) warn "theme: not a colour: $colour"; return 0 ;;
      esac
      r=$((16#${hex%????}))
      g="${hex#??}"; g=$((16#${g%??}))
      b=$((16#${hex#????}))
      printf -v SGR '\033[%s38;2;%d;%d;%dm' "$attrs" "$r" "$g" "$b" ;;
    *[!0-9]*)
      warn "theme: not a colour: $colour" ;;
    *)
      if [ "$colour" -le 255 ]
        then printf -v SGR '\033[%s38;5;%dm' "$attrs" "$colour"
        else warn "theme: colour index out of range: $colour"
      fi ;;
  esac
}

# Set one fzf colour key, replacing any value it already had. A theme file is
# read on top of the built-in one, so without this an overridden key would be
# passed to fzf twice — harmless, since the later one wins, but it makes
# `sushi theme` lie about what is in effect. No forks, and n is fourteen.
fzf_color_set() {
  local rest="$FZF_COLORS" item out=""
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    case "$rest" in *,*) rest="${rest#*,}" ;; *) rest="" ;; esac
    case "$item" in "$1:"*) continue ;; esac
    out="${out:+$out,}$item"
  done
  FZF_COLORS="${out:+$out,}$1:$2"
}

# Read a theme from stdin and set the palette from it. A deliberately narrow
# slice of YAML — comments, `key: value`, and one level of indented keys under
# `fzf:` and `symbols:` — parsed in bash rather than handed to awk or a yaml
# tool, because this runs on every invocation including once per row the fzf
# preview draws, and a fork there is felt. An unknown key is a warning, not a
# failure: a theme written for a later sushi should still mostly render.
theme_read() {
  local line bare key val section="" indented
  while IFS= read -r line; do
    line="${line%$'\r'}"
    bare="${line#"${line%%[! $'\t']*}"}"          # without the indent
    case "$bare" in ''|'#'*) continue ;; esac     # blank, or a whole-line comment
    case "$line" in ' '*|$'\t'*) indented=1 ;; *) indented=0 ;; esac
    case "$bare" in
      *:*) key="${bare%%:*}"; val="${bare#*:}" ;;
      *) warn "theme: cannot parse: $bare"; continue ;;
    esac
    key="${key%"${key##*[! $'\t']}"}"
    val="${val#"${val%%[! $'\t']*}"}"
    case "$val" in
      '"'*) val="${val#\"}"; val="${val%%\"*}" ;;
      "'"*) val="${val#\'}"; val="${val%%\'*}" ;;
      '#'*) val="" ;;                            # `fzf:  # opens a section` — all comment
      *)    val="${val%%[ $'\t']#*}"             # a trailing comment
            val="${val%"${val##*[! $'\t']}"}" ;;
    esac
    # A bare `fzf:` with nothing after it opens a section; anything indented
    # under it belongs to that section, and the next unindented key closes it.
    if [ "$indented" = 0 ]; then
      section=""
      [ -n "$val" ] || { section="$key"; continue; }
    fi
    case "$section:$key" in
      :name)     THEME_NAME="$val" ;;
      :accent)   theme_sgr "$val"; C_ACCENT="$SGR";  S_ACCENT="$val" ;;
      :heading)  theme_sgr "$val"; C_HEADING="$SGR"; S_HEADING="$val" ;;
      :prompt)   theme_sgr "$val"; C_PROMPT="$SGR";  S_PROMPT="$val" ;;
      :target)   theme_sgr "$val"; C_TARGET="$SGR";  S_TARGET="$val" ;;
      :value)    theme_sgr "$val"; C_VALUE="$SGR";   S_VALUE="$val" ;;
      :muted)    theme_sgr "$val"; C_MUTED="$SGR";   S_MUTED="$val" ;;
      fzf:*)     [ -n "$val" ] && fzf_color_set "$key" "$val" ;;
      symbols:pointer) SYM_POINTER="$val" ;;
      symbols:marker)  SYM_MARKER="$val" ;;
      *) warn "theme: unknown key: ${section:+$section.}$key" ;;
    esac
  done
}

# Where SUSHI_THEME=<name> is looked for, first hit wins:
#   $SUSHI_THEME_DIR/<name>.yaml        an override for one run or one machine
#   ~/.config/sushi/themes/<name>.yaml  yours, and survives a `git pull`
#   <clone>/themes/<name>.yaml          the ones sushi ships
# XDG_CONFIG_HOME is honoured where it is set.
# The search path, in precedence order, one per line. One definition, so
# theme_find, `sushi themes` and `sushi theme` can never disagree about where
# themes live — a list like this in three places is a list that goes stale.
theme_dirs() {
  [ -n "${SUSHI_THEME_DIR:-}" ] && printf '%s\n' "$SUSHI_THEME_DIR"
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/sushi/themes"
  printf '%s\n' "$(dirname "$SELF")/themes"
}

# Just the names, deduplicated, for completion. A shadowed duplicate is the
# same word to type, so it appears once.
theme_names() {
  local dir f name ext seen=" "
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    set -- "$dir"/*.yaml "$dir"/*.yml
    for f in "$@"; do
      [ -f "$f" ] || continue
      name="${f##*/}"; for ext in .yaml .yml; do name="${name%$ext}"; done
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      printf '%s\n' "$name"
    done
  done <<EOF
$(theme_dirs)
EOF
  # sushi is the built-in and needs no file to exist; none is always available
  case "$seen" in *" sushi "*) : ;; *) printf 'sushi\n' ;; esac
  printf 'none\n'
}

theme_find() {
  local name="$1" dir ext
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for ext in yaml yml; do
      [ -f "$dir/$name.$ext" ] && { printf '%s\n' "$dir/$name.$ext"; return 0; }
    done
  done <<EOF
$(theme_dirs)
EOF
  return 1
}

THEME_NAME="none"
THEME_SOURCE="built-in"
THEME_FILE=""
C_ACCENT=""; C_HEADING=""; C_PROMPT=""; C_TARGET=""; C_VALUE=""; C_MUTED=""; C_OFF=""
# The spec each colour came from, kept only so `sushi theme` can show you what
# it read rather than what it computed.
S_ACCENT=""; S_HEADING=""; S_PROMPT=""; S_TARGET=""; S_VALUE=""; S_MUTED=""
FZF_COLORS=""
SYM_POINTER=""
SYM_MARKER=""

# SUSHI_THEME=none skips all of it: the palette stays blank, which every call
# site interpolates harmlessly, and fzf is passed no --color at all.
if [ "$SUSHI_THEME" != none ]; then
  case "$SUSHI_THEME" in
    sushi)             THEME_FILE="" ;;
    */*|*.yaml|*.yml)  THEME_FILE="${SUSHI_THEME/#\~/$HOME}" ;;
    *)                 THEME_FILE="$(theme_find "$SUSHI_THEME")" || {
                         warn "no theme named $SUSHI_THEME — using the built-in one"
                         THEME_FILE=""
                       } ;;
  esac
  if [ -n "$THEME_FILE" ] && [ ! -r "$THEME_FILE" ]; then
    warn "cannot read theme $THEME_FILE — using the built-in one"
    THEME_FILE=""
  fi
  # The built-in palette always goes down first and a file is read on top of
  # it, so a theme can be the two lines you actually wanted to change and still
  # leave the rest of the picker looking like something.
  theme_builtin
  if [ -n "$THEME_FILE" ]; then
    THEME_SOURCE="$THEME_FILE"
    theme_read < "$THEME_FILE"
  fi
  C_OFF=$'\033[0m'
fi

# Full screen, not a slice of the current one.
#
# `--height=80%` draws the picker inline, in the bottom 80% of the screen you are
# already looking at, and fzf remembers where that region starts. Shrink the
# terminal while it is up and the top of that region scrolls off into scrollback:
# the remembered origin now points at a row that no longer exists, so the repaint
# that follows the resize clears the wrong lines and lands the window somewhere
# new — leaving the previous frame stranded above it. Shrink again and you get
# another one, until the screen is a stack of half-erased pickers that survives
# the picker exiting.
#
# fzf treats `--height=100%` (like no --height at all) as a different mode: it
# takes the alternate screen, so a resize is a repaint of a buffer it owns
# outright, and quitting puts your terminal back byte for byte with nothing left
# in the scrollback. That is the whole fix — everything below is unchanged.
#
# First on the line, which makes it the weakest thing fzf is handed: a call site
# that wants something else can say so, and SUSHI_FZF_OPTS='--height=80%' still
# buys the inline picker back for anyone who prefers it and does not resize.
FZF_WINDOW_ARGS=(--height=100%)

FZF_THEME_ARGS=()
[ -n "$FZF_COLORS" ]  && FZF_THEME_ARGS+=(--color="$FZF_COLORS")
[ -n "$SYM_POINTER" ] && FZF_THEME_ARGS+=(--pointer="$SYM_POINTER")
[ -n "$SYM_MARKER" ]  && FZF_THEME_ARGS+=(--marker="$SYM_MARKER")

FZF_USER_ARGS=()
if [ -n "$SUSHI_FZF_OPTS" ]; then
  # shellcheck disable=SC2206  # deliberate splitting: this is an option list
  FZF_USER_ARGS=($SUSHI_FZF_OPTS)
fi

# Geometry and theme first (weakest), the call site's own options next, and
# SUSHI_FZF_OPTS last — fzf lets the later flag win, so anything you set
# overrides everything here.
# The `${a[@]+...}` form is for bash 3.2, where "${empty[@]}" trips `set -u`.
FZF() {
  fzf ${FZF_WINDOW_ARGS[@]+"${FZF_WINDOW_ARGS[@]}"} \
      ${FZF_THEME_ARGS[@]+"${FZF_THEME_ARGS[@]}"} \
      "$@" \
      ${FZF_USER_ARGS[@]+"${FZF_USER_ARGS[@]}"}
}
