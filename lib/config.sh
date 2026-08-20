# ---------------------------------------------------------------- ssh_config --

# Print a config file with all `Include` directives expanded inline.
flatten_config() {
  local file="$1" depth="${2:-0}" line tok g
  [ -r "$file" ] || return 0
  [ "$depth" -gt 8 ] && return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # A builtin glob, not `printf | tr`: this runs for every line of every config
    # file, and two forks a line made config_hosts cost ~500ms on a 170-line
    # config — paid again by every preview redraw and every caller.
    case "$line" in
      *[Ii][Nn][Cc][Ll][Uu][Dd][Ee]*)
        if [[ "$line" =~ ^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+(.*)$ ]]; then
          for tok in ${BASH_REMATCH[1]}; do
            tok="${tok%\"}"; tok="${tok#\"}"
            case "$tok" in
              "~"/*) tok="$HOME/${tok#"~"/}" ;;
              /*)    ;;
              *)     tok="$SSH_DIR/$tok" ;;
            esac
            for g in $tok; do
              [ -e "$g" ] && flatten_config "$g" $((depth + 1))
            done
          done
          continue
        fi
        ;;
    esac
    printf '%s\n' "$line"
  done < "$file"
}

# TSV: alias \t hostname \t user \t port \t added
#
# `added` is whatever a `# added <when>` line inside the stanza says — sushi
# writes one into every stanza it generates. Hosts that predate it, and
# hand-written stanzas, simply have nothing there.
config_hosts() {
  [ -r "$CONFIG" ] || return 0
  flatten_config "$CONFIG" | AWK '
    function flush() {
      for (i = 1; i <= n; i++) {
        p = pat[i]
        if (p ~ /[*?!]/) continue
        h = (hostname != "" ? hostname : p)
        print p "\t" h "\t" user "\t" (port != "" ? port : "22") "\t" added
      }
      n = 0; hostname = ""; user = ""; port = ""; added = ""
    }
    BEGIN { n = 0 }
    /^[ \t]*#/ {
      # The one comment worth reading: the provenance note sushi writes itself.
      # Every other comment is still skipped.
      if (n > 0) {
        c = $0
        sub(/^[ \t]*#[ \t]*/, "", c)
        if (tolower(substr(c, 1, 6)) == "added ") {
          added = substr(c, 7)
          sub(/[ \t]+$/, "", added)
          gsub(/\t/, " ", added)
        }
      }
      next
    }
    NF == 0 { next }
    { k = tolower($1); sub(/=$/, "", k) }
    k == "host"     { flush(); for (i = 2; i <= NF; i++) pat[++n] = $i; next }
    k == "match"    { flush(); next }
    n == 0          { next }
    k == "hostname" { hostname = $2; next }
    k == "user"     { user = $2; next }
    k == "port"     { port = $2; next }
    END { flush() }
  '
}


# ------------------------------------------------------------------ config I/O --

# The comment header commit_managed puts at the top of the managed block.
managed_header() {
  printf '%s\n' "# Managed by sushi. Hand-edits are kept; delete a stanza to drop it."
  printf '%s\n' "# Kept at the top of the file: in ssh_config the FIRST value for a"
  printf '%s\n' "# keyword wins, so a later 'Host *' block can't override these."
}

# The body between the markers, WITHOUT that header.
#
# Dropping it here matters: install_block re-submits this body and commit_managed
# writes the header again, so a body that still contained one came back with two.
# Every import stacked another copy — three imports, three headers, forever. Any
# config that already grew them collapses back to one on the next write.
managed_block() {
  [ -r "$CONFIG" ] || return 0
  { managed_header
    printf '%s\n' '@@SUSHI_BODY@@'
    cat "$CONFIG"
  } | AWK -v b="$BEGIN_MARK" -v e="$END_MARK" '
      $0 == "@@SUSHI_BODY@@" { body = 1; next }
      !body { hdr[$0] = 1; next }
      index($0, b) { f = 1; next }
      index($0, e) { f = 0; next }
      f && !($0 in hdr)'
}

config_without_managed() {
  [ -r "$CONFIG" ] || return 0
  AWK -v b="$BEGIN_MARK" -v e="$END_MARK" \
    'index($0, b) { f = 1; next } index($0, e) { f = 0; next } !f' "$CONFIG"
}

# $1 = file holding the ENTIRE new managed-block body (replaces what's there)
commit_managed() {
  local body="$1" stamp backup tmp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR" 2>/dev/null
  [ -f "$CONFIG" ] || { : > "$CONFIG"; chmod 600 "$CONFIG"; }

  backup="$CONFIG.sushi-backup-$stamp"
  cp "$CONFIG" "$backup" || die "could not back up $CONFIG"

  tmp="$(mktemp "${TMPDIR:-/tmp}/sushi.XXXXXX")" || die "mktemp failed"
  {
    printf '%s\n' "$BEGIN_MARK"
    managed_header
    printf '\n'
    cat "$body"
    printf '%s\n' "$END_MARK"
    printf '\n'
    config_without_managed
  } > "$tmp"

  # collapse runs of blank lines, then validate before committing
  AWK 'NF == 0 { if (blank++) next } NF { blank = 0 } 1' "$tmp" > "$tmp.clean" \
    && mv "$tmp.clean" "$tmp"

  # Validate with `ssh -G` before committing — but only if the *original* config
  # already passes, so an ancient ssh without -G (or a pre-existing error in the
  # user's own config) can't block a legitimate write.
  if have ssh && ssh -F "$backup" -G sushi-probe.invalid >/dev/null 2>&1 \
     && ! ssh -F "$tmp" -G sushi-probe.invalid >/dev/null 2>&1; then
    printf '%s\n' "--- ssh -G said: ---" >&2
    ssh -F "$tmp" -G sushi-probe.invalid 2>&1 >/dev/null | head -5 >&2
    rm -f "$tmp" "$backup"
    die "generated config failed validation; $CONFIG was NOT changed"
  fi

  cat "$tmp" > "$CONFIG" && chmod 600 "$CONFIG"
  rm -f "$tmp"
  printf 'Updated %s (backup: %s)\n' "$CONFIG" "$backup"

  # keep only the 5 most recent backups
  ls -1t "$CONFIG".sushi-backup-* 2>/dev/null | tail -n +6 | while IFS= read -r old; do
    rm -f "$old"
  done
}

# $1 = file holding new Host stanzas to append to the managed block
install_block() {
  local body
  body="$(mktemp "${TMPDIR:-/tmp}/sushi-body.XXXXXX")" || die "mktemp failed"
  { managed_block; cat "$1"; } > "$body"
  commit_managed "$body"
  rm -f "$body"
}

# Drop the named aliases from the managed block. A stanza whose Host line lists
# several patterns loses only the named ones; it survives if any remain.
# $1 = newline-separated alias names
remove_managed_aliases() {
  local names="$1" body flat
  body="$(mktemp "${TMPDIR:-/tmp}/sushi-body.XXXXXX")" || die "mktemp failed"
  # Space-separated on ONE line: onetrueawk (macOS) refuses a -v value with a
  # newline in it, and Host patterns cannot contain whitespace anyway.
  flat="$(printf '%s\n' "$names" | tr '\n' ' ')"
  managed_block | AWK -v names="$flat" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") kill[a[i]] = 1 }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (tolower(line) ~ /^host[ \t]/) {
        split(line, f, "[ \t]+")
        keep = ""
        for (i = 2; i in f; i++) if (f[i] != "" && !(f[i] in kill)) keep = keep " " f[i]
        if (keep == "") { skip = 1; next }
        skip = 0
        print "Host" keep
        next
      }
      if (!skip) print
    }' > "$body"
  commit_managed "$body"
  rm -f "$body"
}
