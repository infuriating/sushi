# ---------------------------------------------------------------- share / export / import --
#
# Round-trip sanitized Host stanzas (and optionally sushi settings) as a text
# file. `share` is an alias of `export`. Connections only ever carry Host /
# HostName / User / Port — never IdentityFile, ProxyJump, or private keys.

SHARE_MARK="# sushi-share 1"
SHARE_SETTINGS="@@SUSHI_SETTINGS@@"
SHARE_IGNORE="@@SUSHI_IGNORE@@"
SHARE_THEME="@@SUSHI_THEME@@"
SHARE_HOSTS="@@SUSHI_HOSTS@@"

# Emit sanitized Host stanzas from config_hosts. Optional $1 = newline-separated
# alias filter (empty = every host). Wildcards never appear in config_hosts.
share_emit_hosts() {
  local filter="${1:-}"
  {
    [ -n "$filter" ] && printf '%s\n' "$filter"
    printf '%s\n' '@@SUSHI_FILTER@@'
    config_hosts
  } | AWK -F'\t' '
      BEGIN { mode = 0; n = 0 }
      $0 == "@@SUSHI_FILTER@@" { mode = 1; next }
      mode == 0 { if ($0 != "") want[tolower($0)] = 1; next }
      {
        if ($1 == "") next
        if (length(want) > 0 && !(tolower($1) in want)) next
        print "Host " $1
        print "    HostName " $2
        if ($3 != "") print "    User " $3
        if ($4 != "" && $4 != "22") print "    Port " $4
        print ""
        n++
      }
      END { if (n == 0) exit 1 }
    '
}

# Active sushi knobs worth shipping with --config. MODE falls back to the
# zshrc parse doctor already does. Theme YAML only when it is a user file.
share_emit_settings() {
  local rc mode theme_file clone_themes name
  rc="${SUSHI_RC:-${ZDOTDIR:-$HOME}/.zshrc}"
  mode="${SUSHI_MODE:-}"
  if [ -z "$mode" ] && [ -r "$rc" ]; then
    mode="$(AWK '/SUSHI_MODE:=/ {
      s = $0; sub(/.*SUSHI_MODE:=/, "", s); sub(/\}.*/, "", s); print s; exit
    }' "$rc")"
  fi

  printf '%s\n' "$SHARE_SETTINGS"
  [ -n "${SUSHI_THEME:-}" ] && [ "$SUSHI_THEME" != sushi ] && \
    printf 'SUSHI_THEME=%s\n' "$SUSHI_THEME"
  [ -n "$mode" ] && printf 'SUSHI_MODE=%s\n' "$mode"
  [ -n "${SUSHI_SORT:-}" ] && printf 'SUSHI_SORT=%s\n' "$SUSHI_SORT"
  [ -n "${SUSHI_KEY:-}" ] && [ "$SUSHI_KEY" != '^S' ] && \
    printf 'SUSHI_KEY=%s\n' "$SUSHI_KEY"
  [ -n "${SUSHI_KEY_ACCEPT:-}" ] && [ "$SUSHI_KEY_ACCEPT" != 0 ] && \
    printf 'SUSHI_KEY_ACCEPT=%s\n' "$SUSHI_KEY_ACCEPT"
  [ -n "${SUSHI_EXEC:-}" ] && [ "$SUSHI_EXEC" != 0 ] && \
    printf 'SUSHI_EXEC=%s\n' "$SUSHI_EXEC"
  [ -n "${SUSHI_FZF_OPTS:-}" ] && printf 'SUSHI_FZF_OPTS=%s\n' "$SUSHI_FZF_OPTS"

  if [ -r "$IGNORE" ]; then
    local pats
    pats="$(ignore_entries)"
    if [ -n "$pats" ]; then
      printf '%s\n' "$SHARE_IGNORE"
      printf '%s\n' "$pats"
    fi
  fi

  theme_file="${THEME_FILE:-}"
  clone_themes="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/themes"
  case "$theme_file" in
    "") ;;
    "$clone_themes"/*) ;;
    *)
      if [ -r "$theme_file" ]; then
        name="${THEME_NAME:-custom}"
        case "$name" in ""|none|sushi) name="${theme_file##*/}"; name="${name%.yaml}"; name="${name%.yml}" ;; esac
        printf '%s %s\n' "$SHARE_THEME" "$name"
        cat "$theme_file"
        printf '\n'
      fi
      ;;
  esac
}

# Build a complete share file on stdout. $1 = alias filter (empty = all).
# $2 = 1 to include settings.
share_build() {
  local filter="$1" with_cfg="$2"
  printf '%s\n' "$SHARE_MARK"
  printf '%s\n' "# Sanitized Host stanzas only (Host / HostName / User / Port)."
  printf '%s\n' "# IdentityFile, ProxyJump and private keys are never included —"
  printf '%s\n' "# the recipient sets those on their own machine."
  printf '\n'
  if [ "$with_cfg" = 1 ]; then
    share_emit_settings
    printf '\n'
  fi
  printf '%s\n' "$SHARE_HOSTS"
  share_emit_hosts "$filter"
}

# Rows for the export picker: visible alias+target, hidden alias.
share_export_menu() {
  config_hosts | AWK -F'\t' -v a="$C_VALUE" -v t="$C_MUTED" -v z="$C_OFF" '
    $1 == "" { next }
    {
      tgt = ($3 != "" ? $3 "@" : "") $2 ($4 != "22" ? ":" $4 : "")
      printf "%s%-22s%s %s%s%s\t%s\n", a, $1, z, t, tgt, z, $1
    }'
}

# Parse a share file on stdin into a temp dir:
#   $1/hosts     sanitized Host stanzas (ready for install_block)
#   $1/settings  KEY=value lines (may be empty)
#   $1/ignore    ignore patterns (may be empty)
#   $1/theme     "name" on first line, YAML after (may be absent)
#   $1/has_cfg   "1" if any settings/ignore/theme section was present
#
# Allowlists Host/HostName/User/Port. Drops Match/Include/wildcards/unknowns.
share_parse() {
  local dir="$1"
  mkdir -p "$dir"
  : > "$dir/hosts"
  : > "$dir/settings"
  : > "$dir/ignore"
  : > "$dir/has_cfg"

  AWK -v dir="$dir" "$AWK_KW"'
      function flush(   i, p, wild) {
        if (n == 0) return
        wild = 0
        for (i = 1; i <= n; i++) {
          p = pat[i]
          if (p ~ /[*?!]/) wild = 1
        }
        if (wild || skip) {
          for (i = 1; i <= n; i++)
            printf "sushi: skipping Host %s (wildcard or Match)\n", pat[i] > "/dev/stderr"
          n = 0; hostname = ""; user = ""; port = ""; skip = 0
          return
        }
        for (i = 1; i <= n; i++) {
          print "Host " pat[i] >> (dir "/hosts")
          if (hostname != "") print "    HostName " hostname >> (dir "/hosts")
          if (user != "")     print "    User " user >> (dir "/hosts")
          if (port != "" && port != "22") print "    Port " port >> (dir "/hosts")
          print "" >> (dir "/hosts")
          count++
        }
        n = 0; hostname = ""; user = ""; port = ""; skip = 0
      }
      BEGIN {
        mode = "hosts"   # bare ssh_config until a marker says otherwise
        n = 0; count = 0; skip = 0
        theme_name = ""
      }
      $0 ~ /^@@SUSHI_SETTINGS@@$/ { flush(); mode = "settings"; print "1" > (dir "/has_cfg"); next }
      $0 ~ /^@@SUSHI_IGNORE@@$/   { flush(); mode = "ignore";   print "1" > (dir "/has_cfg"); next }
      $0 ~ /^@@SUSHI_HOSTS@@$/    { flush(); mode = "hosts"; next }
      $0 ~ /^@@SUSHI_THEME@@/ {
        flush()
        mode = "theme"
        print "1" > (dir "/has_cfg")
        theme_name = $0
        sub(/^@@SUSHI_THEME@@[ \t]*/, "", theme_name)
        if (theme_name == "") theme_name = "imported"
        print theme_name > (dir "/theme")
        next
      }
      mode == "settings" {
        if ($0 ~ /^[ \t]*#/ || $0 == "") next
        if ($0 ~ /^SUSHI_[A-Z_]+=/) print $0 >> (dir "/settings")
        next
      }
      mode == "ignore" {
        if ($0 ~ /^[ \t]*#/ || $0 == "") next
        if ($0 !~ /^@@/) print $0 >> (dir "/ignore")
        next
      }
      mode == "theme" {
        # body until the next marker (handled above)
        print $0 >> (dir "/theme")
        next
      }
      mode == "hosts" {
        if ($0 ~ /^# sushi-share/) next
        if ($0 ~ /^[ \t]*#/ || $0 == "") next
        kweq(); k = tolower($1)
        if (k == "host") {
          flush()
          for (i = 2; i <= NF; i++) pat[++n] = $i
          next
        }
        if (k == "match") { flush(); skip = 1; next }
        if (k == "include") {
          printf "sushi: dropping Include (not portable)\n" > "/dev/stderr"
          next
        }
        if (n == 0) next
        if (k == "hostname") { hostname = $2; next }
        if (k == "user")     { user = $2; next }
        if (k == "port")     { port = $2; next }
        printf "sushi: dropping %s (shares only carry Host/HostName/User/Port)\n", $1 > "/dev/stderr"
        next
      }
      END { flush(); if (count == 0) exit 1 }
    '
}

# Stamp # added onto Host stanzas on stdin. One date for the whole batch.
share_stamp() {
  local added
  added="$(date '+%Y-%m-%d %H:%M' 2>/dev/null)"
  AWK -v added="$added" "$AWK_KW"'
      function emit_added() {
        if (inhost && added != "" && !did) {
          print "    # added " added
          did = 1
        }
      }
      {
        kweq(); k = tolower($1)
        if (k == "host") {
          emit_added()
          inhost = 1; did = 0
          print
          next
        }
        if ($0 == "" || NF == 0) { emit_added(); print; next }
        print
      }
      END { emit_added() }
    '
}

# Drop Host stanzas whose alias already exists. Existing aliases on stdin as
# a newline list via the first stream; stanzas via the second.
share_filter_collisions() {
  local existing="$1"
  {
    printf '%s\n' "$existing"
    printf '%s\n' '@@SUSHI_STANSAS@@'
    cat
  } | AWK "$AWK_KW"'
      BEGIN { mode = 0; n = 0; keep = 1 }
      $0 == "@@SUSHI_STANSAS@@" { mode = 1; next }
      mode == 0 { if ($0 != "") taken[tolower($0)] = 1; next }
      {
        kweq(); k = tolower($1)
        if (k == "host") {
          # flush previous kept stanza
          if (n > 0 && keep) for (i = 1; i <= n; i++) print buf[i]
          n = 0; keep = 1
          for (i = 2; i <= NF; i++) {
            if (tolower($i) in taken) {
              printf "sushi: skipping %s — already in config\n", $i > "/dev/stderr"
              keep = 0
            }
          }
        }
        buf[++n] = $0
        next
      }
      END { if (n > 0 && keep) for (i = 1; i <= n; i++) print buf[i] }
    '
}

# Apply settings from a parsed share dir. Theme file + ignore only; MODE etc.
# are printed for the user to set themselves.
share_apply_config() {
  local dir="$1" line key val name dest rc
  if [ -s "$dir/settings" ]; then
    printf '\n--- settings in this share (not written; set them yourself) ---\n'
    cat "$dir/settings"
    printf -- '--------------------------------------------------------------\n'
  fi
  if [ -s "$dir/ignore" ]; then
    local -a pats=()
    while IFS= read -r line; do
      [ -n "$line" ] && pats+=("$line")
    done < "$dir/ignore"
    if [ "${#pats[@]}" -gt 0 ]; then
      ignore_add ${pats[@]+"${pats[@]}"}
    fi
  fi
  if [ -s "$dir/theme" ]; then
    IFS= read -r name < "$dir/theme"
    [ -n "$name" ] || name=imported
    case "$name" in *[!A-Za-z0-9._-]*) name=imported ;; esac
    dest="${XDG_CONFIG_HOME:-$HOME/.config}/sushi/themes"
    mkdir -p "$dest"
    # skip the name line
    AWK 'NR > 1' "$dir/theme" > "$dest/$name.yaml"
    chmod 600 "$dest/$name.yaml" 2>/dev/null
    printf 'Wrote theme %s\n' "$dest/$name.yaml"
    # Persist the choice the same way theme set does, without re-execing.
    rc="${SUSHI_RC:-${ZDOTDIR:-$HOME}/.zshrc}"
    [ -e "$rc" ] || : > "$rc"
    if [ -w "$rc" ]; then
      cp "$rc" "$rc.sushi-backup" 2>/dev/null || true
      local body
      body="$(mktemp "${TMPDIR:-/tmp}/sushi-rc.XXXXXX")" || die "mktemp failed"
      AWK -v b="$THEME_BEGIN" -v e="$THEME_END" '
        index($0, b) { f = 1; next } index($0, e) { f = 0; next }
        f { next }
        /^[ \t]*(export[ \t]+)?SUSHI_THEME=/ { next }
        { print }' "$rc" > "$body"
      AWK -v b="$INSTALL_BEGIN" -v t="$THEME_BEGIN" -v z="$THEME_END" -v n="$name" '
        function block() {
          print t
          print "# `sushi theme set` wrote this. Outside the block below on purpose:"
          print "# install.sh rewrites everything between its own markers."
          print "export SUSHI_THEME=" n
          print z
        }
        index($0, b) && !done { block(); done = 1 }
        { print }
        END { if (!done) { print ""; block() } }
      ' "$body" > "$rc.tmp" && mv "$rc.tmp" "$rc"
      rm -f "$body"
      printf 'Wrote export SUSHI_THEME=%s to %s\n' "$name" "$(tilde "$rc")"
    fi
  fi
}

cmd_export() {
  local dry=0 out="" all=0 with_cfg=0 force=0
  local -a aliases=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n|--dry-run) dry=1; shift ;;
      -o|--output)  [ "$#" -ge 2 ] || die "-o needs a path"; out="$2"; shift 2 ;;
      --output=*)   out="${1#--output=}"; shift ;;
      --all)        all=1; shift ;;
      --config)     with_cfg=1; shift ;;
      --force)      force=1; shift ;;
      -h|--help)
        printf '%s\n' "sushi export — write sanitized Host stanzas to a share file"
        printf '%s\n' "  sushi export              pick hosts (alias: sushi share)"
        printf '%s\n' "  sushi export --all        every host"
        printf '%s\n' "  sushi export ALIAS...     named aliases"
        printf '%s\n' "  sushi export -o FILE      write to FILE (- = stdout)"
        printf '%s\n' "  sushi export --config     also include theme / mode / ignore"
        printf '%s\n' "  sushi export -n           dry run"
        return 0 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *)  aliases+=("$1"); shift ;;
    esac
  done
  while [ "$#" -gt 0 ]; do aliases+=("$1"); shift; done

  local filter="" selected menu
  if [ "$all" = 1 ]; then
    filter=""
  elif [ "${#aliases[@]}" -gt 0 ]; then
    local a missing=0
    for a in ${aliases[@]+"${aliases[@]}"}; do
      if ! config_hosts | AWK -F'\t' -v x="$a" \
           'tolower($1) == tolower(x) { hit = 1 } END { exit !hit }'; then
        warn "no host named $a"
        missing=1
      else
        filter="$filter
$a"
      fi
    done
    [ -n "$filter" ] || die "nothing to export"
    [ "$missing" = 0 ] || warn "continuing with the aliases that exist"
  elif [ -n "${SUSHI_ALL:-}" ] || ! have fzf || [ ! -t 0 ]; then
    filter=""
    if [ -z "${SUSHI_ALL:-}" ]; then
      have fzf || warn_no_fzf
      [ -t 0 ] || warn "no terminal — exporting every host"
    fi
  else
    menu="$(share_export_menu)"
    [ -n "$menu" ] || die "no hosts in $CONFIG — nothing to export"
    selected="$(printf '%s\n' "$menu" | FZF --ansi --multi --delimiter='\t' --with-nth=1 \
      --reverse --border --prompt='export ❯ ' \
      --header=$'TAB select · ctrl-a all · ENTER write share file · ESC cancel' \
      --bind 'ctrl-a:select-all' \
      --preview="'$SELF' __preview {2}" --preview-window=right:50% \
      | cut -f2)"
    [ -n "$selected" ] || { printf 'Nothing selected.\n'; return 0; }
    filter="$selected"
  fi

  local payload
  payload="$(mktemp "${TMPDIR:-/tmp}/sushi-share.XXXXXX")" || die "mktemp failed"
  if ! share_build "$filter" "$with_cfg" > "$payload"; then
    rm -f "$payload"
    die "no hosts to export"
  fi

  if [ "$dry" = 1 ]; then
    cat "$payload"
    printf '(dry run — nothing written)\n' >&2
    rm -f "$payload"
    return 0
  fi

  # Default destination: stdout when piped, else ./sushi-share
  if [ -z "$out" ]; then
    if [ -t 1 ]; then out="./sushi-share"
    else out="-"; fi
  fi

  if [ "$out" = "-" ]; then
    cat "$payload"
    rm -f "$payload"
    return 0
  fi

  if [ -e "$out" ] && [ "$force" != 1 ]; then
    rm -f "$payload"
    die "$out already exists — pass --force to overwrite"
  fi
  cat "$payload" > "$out" || { rm -f "$payload"; die "could not write $out"; }
  chmod 600 "$out"
  rm -f "$payload"
  printf 'Wrote %s\n' "$out"
}

cmd_import() {
  local dry=0 with_cfg=0 file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n|--dry-run) dry=1; shift ;;
      --config)     with_cfg=1; shift ;;
      -h|--help)
        printf '%s\n' "sushi import — merge a share file into ~/.ssh/config"
        printf '%s\n' "  sushi import FILE           merge Host stanzas"
        printf '%s\n' "  sushi import --config FILE  also apply ignore / theme"
        printf '%s\n' "  sushi import -n FILE        dry run"
        return 0 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *)  [ -z "$file" ] || die "import takes one file"; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || die "import needs a file, e.g: sushi import ./sushi-share"
  [ "$file" = "-" ] || [ -r "$file" ] || die "cannot read $file"

  local dir additions existing
  dir="$(mktemp -d "${TMPDIR:-/tmp}/sushi-imp.XXXXXX")" || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" EXIT

  if [ "$file" = "-" ]; then
    share_parse "$dir" || die "no Host stanzas in stdin"
  else
    share_parse "$dir" < "$file" || die "no Host stanzas in $file"
  fi

  if [ -s "$dir/has_cfg" ] && [ "$with_cfg" != 1 ]; then
    printf 'This share has sushi settings — pass --config to apply them.\n'
  fi

  existing="$(config_hosts | AWK -F'\t' '{ print $1 }')"
  additions="$(mktemp "${TMPDIR:-/tmp}/sushi-add.XXXXXX")" || die "mktemp failed"
  share_filter_collisions "$existing" < "$dir/hosts" | share_stamp > "$additions"

  if [ ! -s "$additions" ]; then
    printf 'Nothing new to import — every alias is already in %s.\n' "$CONFIG"
    rm -f "$additions"
    if [ "$with_cfg" = 1 ] && [ "$dry" != 1 ]; then
      share_apply_config "$dir"
    fi
    return 0
  fi

  printf '\n--- proposed additions ------------------------------------\n'
  cat "$additions"
  printf -- '-----------------------------------------------------------\n'

  if [ "$dry" = 1 ]; then
    printf '(dry run — nothing written)\n'
    rm -f "$additions"
    return 0
  fi

  local answer
  printf '[w]rite  [e]dit first  [c]ancel ? '
  read -r answer
  [ -t 0 ] || [ -n "$answer" ] || answer=c
  case "$answer" in
    e|E) "${EDITOR:-vi}" "$additions"; install_block "$additions" ;;
    w|W|"") install_block "$additions" ;;
    *) printf 'Cancelled.\n'; rm -f "$additions"; return 0 ;;
  esac
  rm -f "$additions"

  if [ "$with_cfg" = 1 ]; then
    share_apply_config "$dir"
  fi
}
