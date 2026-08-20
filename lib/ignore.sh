# ---------------------------------------------------------------- ignore list --

# Non-empty, non-comment entries, whitespace trimmed.
ignore_entries() {
  [ -r "$IGNORE" ] || return 0
  sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$IGNORE" | grep -v '^$'
}

# The ignore list is read once per process, not once per candidate. It used to
# re-run `ignore_entries` (a sed|grep pipeline) for every row, which is two
# subprocesses per candidate and was a large part of the scan picker's latency.
IGNORE_LOADED=0
IGNORE_PATS=""
ignore_invalidate() { IGNORE_LOADED=0; }

# is_ignored <user> <host> — patterns match `user@host` or the bare host, glob-style
is_ignored() {
  local user="$1" host="$2" pat reglob=0
  if [ "$IGNORE_LOADED" = 0 ]; then
    IGNORE_PATS="$(ignore_entries)"
    IGNORE_LOADED=1
  fi
  [ -n "$IGNORE_PATS" ] || return 1

  # split on newlines only, and with globbing off — the entries ARE globs and
  # must not expand against the filesystem before `case` sees them
  local IFS='
'
  case $- in *f*) ;; *) reglob=1; set -f ;; esac
  for pat in $IGNORE_PATS; do
    # shellcheck disable=SC2254  # unquoted on purpose: entries are glob patterns
    case "$user@$host" in $pat) [ "$reglob" = 1 ] && set +f; return 0 ;; esac
    # shellcheck disable=SC2254
    case "$host" in $pat) [ "$reglob" = 1 ] && set +f; return 0 ;; esac
  done
  [ "$reglob" = 1 ] && set +f
  return 1
}

ignore_add() {
  local added=0 pat existing
  existing="$(ignore_entries)"
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR" 2>/dev/null
  if [ ! -f "$IGNORE" ]; then
    {
      printf '%s\n' "# sushi ignore list — one glob pattern per line, '#' starts a comment."
      printf '%s\n' "# Matched against 'user@host' and against the bare host."
      printf '%s\n' "# Entries here are skipped by 'sushi scan'; ~/.ssh/config is untouched."
      printf '%s\n' "#   root@*            any root login"
      printf '%s\n' "#   *.staging.acme.tld   a whole environment"
      printf '\n'
    } > "$IGNORE"
    chmod 600 "$IGNORE"
  fi
  for pat in "$@"; do
    [ -n "$pat" ] || continue
    if printf '%s\n' "$existing" | grep -Fxq "$pat"; then
      printf '  already ignored: %s\n' "$pat"
      continue
    fi
    printf '%s\n' "$pat" >> "$IGNORE"
    existing="$existing
$pat"
    printf '  ignoring: %s\n' "$pat"
    added=$((added + 1))
  done
  [ "$added" -gt 0 ] && printf '\nWrote %s\n' "$IGNORE"
  ignore_invalidate
  return 0
}

ignore_remove() {
  local pat tmp
  [ -r "$IGNORE" ] || { warn "no ignore list at $IGNORE"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/sushi-ign.XXXXXX")" || die "mktemp failed"
  cp "$IGNORE" "$tmp"
  for pat in "$@"; do
    [ -n "$pat" ] || continue
    AWK -v p="$pat" '
      { line = $0; sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line) }
      line == p { next }
      { print }' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    printf '  no longer ignoring: %s\n' "$pat"
  done
  cat "$tmp" > "$IGNORE" && chmod 600 "$IGNORE"
  rm -f "$tmp"
  printf '\nWrote %s\n' "$IGNORE"
}
