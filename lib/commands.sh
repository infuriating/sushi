# ---------------------------------------------------------------- subcommands --

# Everything scan could offer: count|user|host|port, one per line. The ignore
# list is NOT applied here — callers filter, because this runs in a subshell
# (process substitution) and a count set in here would never reach the caller.
scan_candidates() {
  # Three streams into one awk, separated by markers. The ssh config used to
  # arrive via `awk -v cfg="$cfg"`, but onetrueawk — which is what macOS ships —
  # rejects a -v value containing a newline ("newline in string"), so the whole
  # program silently never ran and scan found nothing whenever the config held
  # more than one host. Nothing multi-line goes through -v anywhere now.
  {
    config_hosts
    printf '%s\n' '@@SUSHI_HISTORY@@'
    scan_history
    printf '%s\n' '@@SUSHI_KNOWN_HOSTS@@'
    scan_known_hosts
  } | AWK '
      function boring(h) {
        return (h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0")
      }
      BEGIN { FS = "|"; mode = 0 }
      $0 == "@@SUSHI_HISTORY@@"     { mode = 1; next }
      $0 == "@@SUSHI_KNOWN_HOSTS@@" { mode = 2; next }
      # the ssh config: alias \t hostname \t user \t port
      mode == 0 {
        split($0, f, "\t")
        if (f[1] == "") next
        alias[tolower(f[1])] = 1
        name[tolower(f[2])] = 1
        pair[tolower(f[2]) SUBSEP tolower(f[3])] = 1
        next
      }
      mode == 1 {
        user = $2; host = $3
        if (host == "") next
        h = tolower(host)
        if (boring(h)) next
        if ((h SUBSEP tolower(user)) in pair) next   # same user@host already configured
        if (h in alias) next                         # you ssh to it by alias already
        print $0
        seen[h] = 1
        next
      }
      # known_hosts: bare hostnames, no username recorded, hashed entries already
      # dropped upstream
      mode == 2 {
        host = $1
        if (host == "") next
        h = tolower(host)
        if (boring(h) || h in name || h in alias || h in seen) next
        print "0||" host "||||"
      }
    '
}

# Turn candidate records on stdin into the scan picker's fzf input: three
# tab-separated columns —
#   1 what you see   2 the count|user|host|port record   3 an ignore pattern
# Only column 1 is displayed; 2 is what import consumes, 3 is what ctrl-x feeds
# to `sushi ignore`. Ignored candidates are dropped here.
menu_from_candidates() {
  local line count user host port identity jump
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$SEP" read -r count user host port identity jump _ <<< "$line"
    [ -n "${host:-}" ] || continue
    is_ignored "$user" "$host" && continue
    # One printf per row, no command substitution: this runs for every row on
    # every reload, and `$( )` here cost two forks a row.
    local target extra=""
    # After the target, never inside it: fzf matches on the visible column, and
    # `user@host:port` has to stay one contiguous run.
    [ -n "$identity" ] && extra=" key"
    [ -n "$jump" ] && extra="$extra via ${jump##*@}"
    if [ "$count" = "0" ]; then
      target="$host${port:+:$port}"
      printf '%s%11s%s  %s%s%s%s%s%s\t%s\t%s\n' \
        "$C_HEADING" 'known_hosts' "$C_OFF" "$C_VALUE" "$target" "$C_OFF" \
        "$C_ACCENT" "$extra" "$C_OFF" "$line" "$host"
    else
      target="${user:+$user@}$host${port:+:$port}"
      printf '%s%10sx%s  %s%s%s%s%s%s\t%s\t%s\n' \
        "$C_MUTED" "$count" "$C_OFF" "$C_VALUE" "$target" "$C_OFF" \
        "$C_ACCENT" "$extra" "$C_OFF" "$line" "${user:+$user@}$host"
    fi
  done
}

scan_menu() { scan_candidates | menu_from_candidates; }

# ---- the scan picker's live state -------------------------------------------
#
# ctrl-x used to run `sushi ignore` and then reload by re-scanning from scratch:
# every keypress re-parsed every history file and rewrote the ignore file. That
# is ~900ms a press on a 3000-line history, so dismissing a handful of hosts felt
# broken.
#
# Instead the candidate list is scanned once into SUSHI_SCAN_CACHE, and ctrl-x
# only appends a pattern to SUSHI_SCAN_PENDING. The reload re-reads the cache
# minus the pending lines — no history parse, no config parse, no write. The
# pending patterns are flushed to the ignore file once, after the picker exits.

# Trap-visible: an EXIT trap runs after cmd_scan has returned, so `local`
# variables are gone by then — with `set -u` the trap itself then fails.
SCAN_CACHE=""
SCAN_PENDING=""
cleanup_scan() {
  [ -n "$SCAN_CACHE" ] && rm -f "$SCAN_CACHE"
  [ -n "$SCAN_PENDING" ] && rm -f "$SCAN_PENDING"
  return 0
}

pend_add() {
  local p
  [ -n "${SUSHI_SCAN_PENDING:-}" ] || return 0
  for p in "$@"; do
    [ -n "$p" ] && printf '%s\n' "$p" >> "$SUSHI_SCAN_PENDING"
  done
  return 0
}

menu_from_cache() {
  [ -n "${SUSHI_SCAN_CACHE:-}" ] && [ -r "$SUSHI_SCAN_CACHE" ] || return 0
  menu_from_candidates < "$SUSHI_SCAN_CACHE" \
    | AWK -F'\t' -v pf="${SUSHI_SCAN_PENDING:-/dev/null}" '
        BEGIN { while ((getline l < pf) > 0) if (l != "") gone[l] = 1 }
        !($3 in gone)'
}

cmd_scan() {
  local dry=0
  [ "${1:-}" = "-n" ] || [ "${1:-}" = "--dry-run" ] && dry=1

  local cache pending
  cache="$(mktemp "${TMPDIR:-/tmp}/sushi-scan.XXXXXX")" || die "mktemp failed"
  pending="$(mktemp "${TMPDIR:-/tmp}/sushi-pend.XXXXXX")" || die "mktemp failed"
  SCAN_CACHE="$cache"; SCAN_PENDING="$pending"
  trap cleanup_scan EXIT
  export SUSHI_SCAN_CACHE="$cache" SUSHI_SCAN_PENDING="$pending"

  # one pass over the history; the menu and the hidden tally both come from it
  local menu selected count user host port identity jump hidden=0
  scan_candidates > "$cache"
  menu="$(menu_from_candidates < "$cache")"

  while IFS="$SEP" read -r count user host port identity jump _; do
    [ -n "${host:-}" ] || continue
    is_ignored "$user" "$host" && hidden=$((hidden + 1))
  done < "$cache"

  local hidden_note=""
  [ "$hidden" -gt 0 ] && hidden_note=" · $hidden hidden by the ignore list"
  if [ -z "$menu" ]; then
    printf 'Nothing new found — %s already covers every host in your history.\n' "$CONFIG"
    [ "$hidden" -gt 0 ] && printf '(%s also hidden by %s — see: sushi ignore --list)\n' "$hidden" "$IGNORE"
    return 0
  fi
  [ "$hidden" -gt 0 ] && printf '(%s hidden by %s — see: sushi ignore --list)\n' "$hidden" "$IGNORE"

  if [ "$dry" -eq 1 ] || [ -n "${SUSHI_ALL:-}" ] || ! have fzf || [ ! -t 0 ]; then
    selected="$(printf '%s\n' "$menu" | cut -f2)"
    if [ "$dry" -eq 0 ] && [ -z "${SUSHI_ALL:-}" ]; then
      have fzf || { warn "fzf not found — falling back to importing everything"
                    warn "    for the pick-what-you-want picker: $(fzf_install_cmd)"; }
      [ -t 0 ] || warn "no terminal for interactive selection — importing everything"
    fi
  else
    # ctrl-x only notes the pattern and redraws from the cache; the ignore file is
    # written once, below, after the picker closes.
    selected="$(printf '%s\n' "$menu" | FZF --ansi --multi --delimiter='\t' --with-nth=1 \
      --reverse --border --prompt='import ❯ ' \
      --header="TAB select · ctrl-a all · ENTER import · ctrl-x never show again · ESC cancel
sorted by how often you used them$hidden_note" \
      --bind 'ctrl-a:select-all' \
      --bind "ctrl-x:execute-silent('$SELF' __pend {+3})+reload('$SELF' __menucache)" \
      | cut -f2)"
  fi

  # ---- flush whatever ctrl-x dismissed, whether or not anything was imported
  if [ -s "$pending" ]; then
    local -a pats=()
    local p
    while IFS= read -r p; do
      [ -n "$p" ] && pats+=("$p")
    done < "$pending"
    if [ "${#pats[@]}" -gt 0 ]; then
      printf '\n'
      ignore_add "${pats[@]}"
    fi
  fi

  if [ -z "$selected" ]; then
    [ -s "$pending" ] || printf 'Nothing selected.\n'
    return 0
  fi

  # ---- build stanzas with collision-free aliases
  local additions
  additions="$(mktemp "${TMPDIR:-/tmp}/sushi-add.XXXXXX")" || die "mktemp failed"
  printf '%s\n' "$selected" | build_additions > "$additions"

  printf '\n--- proposed additions ------------------------------------\n'
  cat "$additions"
  printf -- '-----------------------------------------------------------\n'

  if [ "$dry" -eq 1 ]; then
    printf '(dry run — nothing written)\n'
    rm -f "$additions"
    return 0
  fi

  local answer
  printf '[w]rite  [e]dit first  [c]ancel ? '
  read -r answer
  case "$answer" in
    e|E) "${EDITOR:-vi}" "$additions"; install_block "$additions" ;;
    w|W|"") install_block "$additions" ;;
    *) printf 'Cancelled.\n' ;;
  esac
  rm -f "$additions"
}

# sushi add — import one host by hand, without waiting for it to show up in your
# shell history. The gap this fills: a server you have never ssh'd to yet cannot
# appear as a scan candidate, so before this the only way in was editing the
# config yourself.
#
#   sushi add deploy@web1.example.com
#   sushi add web1.example.com:2222            the form `sushi list` prints
#   sushi add box.example.com -i ~/.ssh/work   any ssh flag scan understands
#   sushi add --as staging deploy@10.20.30.40 -J bastion
#   sushi add -n deploy@web1.example.com       dry run, writes nothing
#
# Everything that is not -n or --as goes to the same parser `scan` runs over your
# history, so the two agree about what a destination is by construction.
cmd_add() {
  local dry=0 forced="" tok
  local -a args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n|--dry-run) dry=1; shift ;;
      --as|-a)      [ "$#" -ge 2 ] || die "--as needs an alias"; forced="$2"; shift 2 ;;
      --as=*)       forced="${1#--as=}"; shift ;;
      --help)
        sed -n '/^# sushi add —/,/^cmd_add/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)            args+=("$1"); shift ;;
    esac
  done
  [ "${#args[@]}" -gt 0 ] || die "add needs a destination, e.g: sushi add deploy@web1.example.com"

  # `sushi list` and the picker both print `user@host:port`, so that is the form
  # people will paste back in — but ssh's command line has no colon-port syntax,
  # so rewrite it into the -p the parser expects. Strict shape, no state: a token
  # with two colons (-L 80:host:80) or a scheme (ssh://) does not match, and an
  # explicit -p earlier on the line still wins, because the parser takes the
  # first port it sees before the destination.
  local -a parsed=()
  for tok in ${args[@]+"${args[@]}"}; do
    if [[ "$tok" =~ ^([A-Za-z0-9._-]+@)?([A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then
      parsed+=("${BASH_REMATCH[1]}${BASH_REMATCH[2]}" -p "${BASH_REMATCH[3]}")
    else
      parsed+=("$tok")
    fi
  done

  local rec
  rec="$(printf 'ssh %s\n' "${parsed[*]}" | extract_stream | sed -n 1p)"
  [ -n "$rec" ] || die "no destination in: ${args[*]}"

  # only the user and host are needed here — build_additions re-reads the record
  # for the rest, so there is no second place that has to agree about the fields
  local user host
  IFS="$SEP" read -r user host _ <<< "$rec"
  [ -n "${host:-}" ] || die "no destination in: ${args[*]}"

  # An ignore pattern and an explicit `add` for the same host contradict each
  # other. The explicit request wins — but say so, or the next `scan` quietly
  # disagreeing with what just happened looks like a bug.
  if is_ignored "$user" "$host"; then
    warn "note: a pattern in $IGNORE matches this host — adding it anyway"
  fi

  if [ -n "$forced" ]; then
    case "$forced" in
      ""|*[!A-Za-z0-9._-]*)
        die "--as: '$forced' is not a usable Host alias (letters, digits, . _ - only)" ;;
    esac
    if config_hosts | AWK -F'\t' -v a="$forced" \
         'tolower($1) == tolower(a) { hit = 1 } END { exit !hit }'; then
      die "the alias '$forced' is already in $CONFIG"
    fi
  else
    # Same user@host twice under two names is almost always a mistake rather than
    # an intention, so it takes an explicit --as to say you meant it.
    local existing
    existing="$(config_hosts | AWK -F'\t' -v h="$host" -v u="$user" \
      'tolower($2) == tolower(h) && tolower($3) == tolower(u) { print $1; exit }')"
    if [ -n "$existing" ]; then
      printf '%s is already in %s as "%s".\n' "${user:+$user@}$host" "$CONFIG" "$existing"
      printf 'Pass --as <alias> to add a second stanza for it anyway.\n'
      return 0
    fi
  fi

  local additions
  additions="$(mktemp "${TMPDIR:-/tmp}/sushi-add.XXXXXX")" || die "mktemp failed"
  # build_additions wants a count field it does not use for a single record
  printf '1%s%s\n' "$SEP" "$rec" | build_additions "$forced" > "$additions"

  printf '\n--- proposed addition -------------------------------------\n'
  cat "$additions"
  printf -- '-----------------------------------------------------------\n'

  if [ "$dry" -eq 1 ]; then
    printf '(dry run — nothing written)\n'
    rm -f "$additions"
    return 0
  fi
  install_block "$additions"
  rm -f "$additions"
}

# The ignore picker's rows: scan candidates you have not imported, plus the
# hosts sushi has already written into ~/.ssh/config.
#
#   <kind>  <what you see>  <payload>
#
# The imported half used to call config_hosts once per managed alias, and
# config_hosts is not cheap — 40 imported hosts meant 40 full config parses and a
# 19-second wait before the menu appeared. One awk over two streams now, the same
# marker trick scan_candidates uses (a multi-line -v would break on macOS awk).
ignore_rows() {
  local line count user host port identity jump target

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$SEP" read -r count user host port identity jump _ <<< "$line"
    # Already dismissed: offering it again in the very picker you dismissed it
    # from is just noise. `sushi ignore --list` and `--remove` are where the
    # ignore list itself is visible.
    is_ignored "$user" "$host" && continue
    target="${user:+$user@}$host"
    printf '%s%-9s%s %s%-42s%s %s\n' \
      "$C_ACCENT" 'scan' "$C_OFF" "$C_VALUE" "$target" "$C_OFF" "$target"
  done < <(scan_candidates)

  {
    config_hosts
    printf '%s\n' '@@SUSHI_ALIASES@@'
    managed_block | AWK '{ l = $0; sub(/^[ \t]+/, "", l)
      if (tolower(l) ~ /^host[ \t]/) { for (i = 2; i <= NF; i++) print $i } }'
  } | AWK -v pink="$C_PROMPT" -v rice="$C_VALUE" -v off="$C_OFF" '
      BEGIN { FS = "\t"; mode = 0 }
      $0 == "@@SUSHI_ALIASES@@" { mode = 1; next }
      mode == 0 {
        if ($1 != "") tgt[$1] = ($3 != "" ? $3 "@" : "") $2
        next
      }
      mode == 1 {
        if ($0 == "") next
        printf "%s%-9s%s %s%-42s%s %s\n", \
          pink, "imported", off, rice, $0 "  (" tgt[$0] ")", off, $0
      }
    '
}

# Turn the ignore picker's selected rows (on stdin) into a tagged instruction
# stream: "P<TAB>pattern" to add to the ignore list, "D<TAB>alias" to delete from
# the managed block. An `imported` row yields both.
#
# config_hosts runs ONCE here, not once per selected row. The `imported` branch
# used to call it inside the caller's read loop, so dismissing 40 imported hosts
# meant 40 full config parses — the same mistake ignore_rows was already fixed
# for, living a second time downstream of it. One awk over both streams,
# marker-separated, the shape used everywhere else in this file.
ignore_split_selection() {
  local sel
  sel="$(cat)"
  { config_hosts
    printf '%s\n' '@@SUSHI_SELECTION@@'
    printf '%s\n' "$sel"
  } | AWK -v esc="$ESC" '
      BEGIN { FS = "\t"; mode = 0 }
      $0 == "@@SUSHI_SELECTION@@" { mode = 1; next }
      mode == 0 { if ($1 != "") tgt[$1] = ($3 != "" ? $3 "@" : "") $2; next }
      {
        line = $0
        # fzf --ansi hands the line back with the colours already stripped; strip
        # again anyway, because a row whose "imported" tag fails to match gets
        # added to the ignore list WITHOUT its stanza being deleted — a silent
        # wrong answer rather than a visible error.
        gsub(esc "\\[[0-9;]*m", "", line)
        if (line == "") next
        kind = line; sub(/ .*/, "", kind)
        rest = line; sub(/^.* /, "", rest)
        if (kind == "imported") {
          print "D\t" rest
          if (rest in tgt) print "P\t" tgt[rest]
        } else {
          print "P\t" rest
        }
      }'
}

# sushi ignore / sushi delete
#
#   sushi ignore                 pick things to stop seeing (and drop imported ones)
#   sushi ignore <pattern>...    add patterns without the picker
#   sushi ignore --list          show the ignore list
#   sushi ignore --remove [pat]  un-ignore (picker if no pattern given)
#   sushi ignore --edit          open the ignore list in $EDITOR
cmd_ignore() {
  case "${1:-}" in
    --list|-l)
      if [ -s "$IGNORE" ]; then
        printf '%s\n' "$IGNORE"
        printf -- '---\n'
        ignore_entries
      else
        printf 'Nothing ignored yet (%s)\n' "$IGNORE"
      fi
      return 0
      ;;
    --edit|-e)
      [ -f "$IGNORE" ] || ignore_add >/dev/null   # create with the header comment
      exec "${EDITOR:-vi}" "$IGNORE"
      ;;
    --remove|-r|--unignore)
      shift
      if [ "$#" -gt 0 ]; then
        ignore_remove "$@"
        return $?
      fi
      local cur sel
      cur="$(ignore_entries)"
      [ -n "$cur" ] || { printf 'Nothing ignored yet (%s)\n' "$IGNORE"; return 0; }
      if have fzf && [ -t 0 ]; then
        sel="$(printf '%s\n' "$cur" | FZF --multi --reverse --border \
          --prompt='un-ignore ❯ ' --header='TAB select · ENTER confirm · ESC cancel' \
          --bind 'ctrl-a:select-all')"
        [ -n "$sel" ] || { printf 'Nothing selected.\n'; return 0; }
      else
        have fzf || warn "fzf not found — install it: $(fzf_install_cmd)"
        warn "no fzf/terminal — pass patterns as arguments instead"
        return 1
      fi
      # shellcheck disable=SC2046  # deliberate word splitting on newlines
      local -a args=()
      while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done <<EOF
$sel
EOF
      ignore_remove "${args[@]}"
      return $?
      ;;
    --help|-h)
      sed -n '/^# sushi ignore \/ sushi delete/,/^cmd_ignore/p' "${BASH_SOURCE[0]}" \
        | sed '$d' | sed 's/^# \{0,1\}//'
      return 0
      ;;
    -*)
      die "unknown option: $1 (try: sushi ignore --help)"
      ;;
    "")
      ;;
    *)
      ignore_add "$@"
      return $?
      ;;
  esac

  # ---- interactive: offer scan candidates AND hosts already in the config
  local rows
  rows="$(ignore_rows)"

  if [ -z "$rows" ]; then
    printf 'Nothing to ignore: no new scan candidates and no sushi-managed hosts.\n'
    [ -s "$IGNORE" ] && \
      printf '(anything already dismissed lives in %s — see: sushi ignore --list)\n' "$IGNORE"
    return 0
  fi

  local sel
  if have fzf && [ -t 0 ]; then
    sel="$(printf '%s\n' "$rows" | FZF --ansi --multi --reverse --border \
      --prompt='ignore ❯ ' \
      --header=$'TAB select · ENTER confirm · ESC cancel\nscan = never offer again · imported = also delete its Host stanza' \
      --bind 'ctrl-a:select-all')"
    [ -n "$sel" ] || { printf 'Nothing selected.\n'; return 0; }
  else
    have fzf || warn "fzf not found — install it: $(fzf_install_cmd)"
    warn "no fzf/terminal — pass patterns as arguments: sushi ignore 'root@*'"
    return 1
  fi

  # ---- split the selection into patterns to ignore and aliases to delete
  local -a pats=() dels=()
  local tag val
  while IFS="$TAB" read -r tag val; do
    [ -n "$val" ] || continue
    case "$tag" in
      D) dels+=("$val") ;;
      P) pats+=("$val") ;;
    esac
  done < <(printf '%s\n' "$sel" | ignore_split_selection)

  printf '\n'
  [ "${#dels[@]}" -gt 0 ] && printf 'Deleting from the managed block: %s\n' "${dels[*]}"
  printf 'Adding to the ignore list:\n'
  ignore_add "${pats[@]}"

  if [ "${#dels[@]}" -gt 0 ]; then
    local names=""
    for alias_ in "${dels[@]}"; do names="$names
$alias_"; done
    remove_managed_aliases "$names"
  fi
}

cmd_list() {
  local rows h a t z
  rows="$(config_hosts)"
  [ -n "$rows" ] || { printf 'No hosts in %s yet — run: sushi scan\n' "$CONFIG"; return 0; }
  # Colour only when a human is looking; piped or captured output stays plain.
  if [ -t 1 ]; then h="$C_HEADING"; a="$C_VALUE"; t="$C_MUTED"; z="$C_OFF"
  else h=""; a=""; t=""; z=""; fi
  printf '%s\n' "$rows" | sort -f \
    | AWK -F'\t' -v h="$h" -v a="$a" -v t="$t" -v z="$z" '
        BEGIN { printf "%s%-22s %s%s\n", h, "ALIAS", "TARGET", z }
        {
          tgt = ($3 != "" ? $3 "@" : "") $2 ($4 != "22" ? ":" $4 : "")
          printf "%s%-22s%s %s%s%s\n", a, $1, z, t, tgt, z
        }'
}

# What fzf shows in the side panel for the highlighted alias.
cmd_preview() {
  local a="${1:-}" line key val facts
  [ -n "$a" ] || return 0

  # Captured, not piped twice: the target line and the usage block both want it,
  # and host_facts parses the whole config.
  clock_now
  facts="$(host_facts)"

  printf '%s\n' "$facts" | AWK -F'\t' -v a="$a" -v c="$C_TARGET" -v z="$C_OFF" '$1 == a {
    printf "  %s%s%s%s%s\n", c, ($3 != "" ? $3 "@" : ""), $2, ($4 != "22" ? ":" $4 : ""), z
  }'

  if have ssh; then
    printf '\n  %sresolved%s\n' "$C_HEADING" "$C_OFF"
    ssh -F "$CONFIG" -G "$a" 2>/dev/null | while read -r key val; do
      case "$key" in
        hostname|user|port|proxyjump|proxycommand|forwardagent|localforward|remoteforward)
          [ "$val" = "none" ] && continue
          [ "$key" = "forwardagent" ] && [ "$val" = "no" ] && continue
          printf '    %s%-14s%s %s%s%s\n' "$C_MUTED" "$key" "$C_OFF" "$C_VALUE" "$val" "$C_OFF"
          ;;
        identityfile)
          # only keys that actually exist, so the seven ssh defaults stay hidden
          # shellcheck disable=SC2088  # matching a literal ~ in ssh -G output
          case "$val" in "~/"*) [ -f "$HOME/${val#\~/}" ] || continue ;; *) [ -f "$val" ] || continue ;; esac
          printf '    %s%-14s%s %s%s%s\n' "$C_MUTED" "$key" "$C_OFF" "$C_ACCENT" "$val" "$C_OFF"
          ;;
      esac
    done
  fi

  # `added at` is only ever as good as the note in the stanza, `last used at`
  # only as good as the dates your shell keeps, and both say so rather than
  # guessing: "never" means the history has no such host at all, "unknown" means
  # it has one but no date to go with it.
  printf '%s\n' "$facts" | AWK -F'\t' -v a="$a" -v d="$C_MUTED" -v r="$C_VALUE" \
      -v v="$C_HEADING" -v z="$C_OFF" -v now="$NOW" -v tzoff="$TZOFF" "$AWK_TIME"'
      $1 == a {
        ad = iso2epoch($5)
        printf "\n  %susage%s\n", v, z
        printf "    %s%-14s%s %s%s%s\n", d, "added at", z, r, \
          (ad != "" ? $5 "  (" since(ad) ")" : "unknown"), z
        printf "    %s%-14s%s %s%s%s\n", d, "last used at", z, r, \
          ($7 != "" ? when($7) "  (" since($7) ")" : ($6 + 0 > 0 ? "unknown" : "never")), z
      }'

  local disp
  disp="$(tilde "$CONFIG")"
  printf '\n  %sstanza in %s%s\n' "$C_HEADING" "$disp" "$C_OFF"
  flatten_config "$CONFIG" 2>/dev/null | AWK -v a="$a" -v d="$C_MUTED" -v z="$C_OFF" '
    { k = tolower($1) }
    k == "host" { inb = 0; for (i = 2; i <= NF; i++) if ($i == a) inb = 1; if (inb) { print "    " d $0 z }; next }
    k == "match" { inb = 0; next }
    inb && NF { print "    " d $0 z }'
}

# scan_history, memoised for the picker.
#
# Ordering by usage means the picker needs the history counts, and re-parsing the
# history on every `ssh` press costs ~250ms. The signature is the combined byte
# size of the history files, which changes whenever you run anything; a stale hit
# only means slightly stale *ordering*, so this fails benign.
#
# scan and ignore deliberately do NOT use this: they are explicit actions where a
# fresh read is what you asked for.
scan_history_cached() {
  local dir="${SUSHI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/sushi}"
  local f="$dir/history" sig line
  local -a files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(history_files)
  if [ "${#files[@]}" -eq 0 ]; then
    scan_history
    return 0
  fi
  sig="${#files[@]}:$(wc -c -- "${files[@]}" 2>/dev/null | tail -1 | AWK '{ print $1 }')"

  # The tag is part of the signature: a cache written before the records grew a
  # date column would otherwise read as a perfectly good hit.
  if [ -r "$f" ] && IFS= read -r line < "$f" && [ "$line" = "#sig2 $sig" ]; then
    tail -n +2 "$f"
    return 0
  fi

  local out
  out="$(scan_history)"
  # This file is derived from ~/.ssh/config and your shell history: it lists
  # every user@host:port you have ever reached. Both sources are 0600, so the
  # cache is too — a default umask would leave it 0644 and hand your whole
  # server inventory to every account on the box.
  #
  # `umask` in a subshell rather than a chmod after the fact: a chmod leaves the
  # file world-readable for the window between creation and the fix, and the
  # write is where the contents land.
  if mkdir -p "$dir" 2>/dev/null; then
    chmod 700 "$dir" 2>/dev/null
    if ( umask 077
         { printf '#sig2 %s\n' "$sig"; printf '%s\n' "$out"; } > "$f.tmp" ) 2>/dev/null
    then
      mv "$f.tmp" "$f" 2>/dev/null   # mv keeps the mode the umask gave it
    fi
  fi
  printf '%s\n' "$out"
}

# Every host in the config, with the facts only the history knows bolted on:
#
#   alias \t hostname \t user \t port \t added \t count \t last-used-epoch
#
# Two streams behind a marker, the usual shape — a multi-line `awk -v` breaks on
# macOS awk. Usage is matched on hostname+user, so it survives renaming an alias,
# and on the alias itself, which catches `ssh staging` where the alias IS what
# you typed. `count` and `last` come off the same key, so a host found by its
# alias is dated by those rows too.
host_facts() {
  {
    scan_history_cached
    printf '%s\n' '@@SUSHI_CONFIG@@'
    config_hosts
  } | AWK '
      BEGIN { FS = "|"; mode = 0 }
      $0 == "@@SUSHI_CONFIG@@" { mode = 1; FS = "\t"; next }
      mode == 0 {
        # count|user|host|port|identity|jump|last
        k = tolower($3) SUBSEP tolower($2)
        used[k] += $1
        if ($7 + 0 > lastk[k] + 0) lastk[k] = $7
        b = tolower($3)
        bare[b] += $1
        if ($7 + 0 > lastb[b] + 0) lastb[b] = $7
        next
      }
      mode == 1 {
        split($0, f, "\t")
        if (f[1] == "") next
        k = tolower(f[2]) SUBSEP tolower(f[3])
        n = used[k]; lu = lastk[k]
        if (n == 0) { b = tolower(f[1]); n = bare[b]; lu = lastb[b] }
        print f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5] "\t" n "\t" lu
      }
    '
}

# The width the alias column is padded to, so the two age columns line up: the
# widest alias there is, within reason — a 60-character alias would otherwise
# shove the target off the right edge of every row. run_picker needs the same
# number to line its header up, which is why this is a function and not a
# constant computed inside picker_lines.
alias_width() {
  config_hosts | AWK -F'\t' '
    { if (length($1) > m) m = length($1) }
    END { print (m < 12 ? 12 : (m > 32 ? 32 : m)) }'
}

# ---------------------------------------------------------------------- sort --
#
# Three orderings, cycled with ctrl-s inside the picker:
#
#   used    most recently used first   (the default)
#   added   most recently added first
#   count   most used first
#
# `used` leads because recency is the better predictor: the host you touched an
# hour ago is almost always the one you want next, while a lifetime count keeps
# the server you hammered for a week last spring pinned to the top forever.
# `count` is still one keypress away, and SUSHI_SORT picks the mode you start in
# (`alpha` for plain A-Z, which is outside the cycle — ctrl-s leaves it).
sort_mode_norm() {
  case "${1:-}" in
    added)       printf 'added' ;;
    count|usage) printf 'count' ;;   # `usage` is what SUSHI_SORT called it once
    alpha)       printf 'alpha' ;;
    *)           printf 'used' ;;
  esac
}

# What the header calls the current mode.
sort_mode_label() {
  case "$1" in
    added) printf 'last added' ;;
    count) printf 'most used' ;;
    alpha) printf 'A-Z' ;;
    *)     printf 'last used' ;;
  esac
}

# The mode lives in a file, not a variable: ctrl-s reloads the list by running
# this script again as a child of fzf, and a child cannot hand a variable back.
# Trap-visible for the same reason SCAN_CACHE is — see cleanup_scan.
SORT_STATE=""
cleanup_sort() {
  # the mode, plus one cached feed per ordering visited — see picker_feed
  [ -n "$SORT_STATE" ] && rm -f "$SORT_STATE" "$SORT_STATE".feed.*
  return 0
}

sort_mode_read() {
  local m=""
  [ -n "${SUSHI_SORT_STATE:-}" ] && [ -r "${SUSHI_SORT_STATE:-}" ] &&
    IFS= read -r m < "$SUSHI_SORT_STATE"
  [ -n "$m" ] || m="${SUSHI_SORT:-used}"
  sort_mode_norm "$m"
}

# ctrl-s: step to the next mode and remember it for the reload that follows.
sort_mode_advance() {
  local next
  case "$(sort_mode_read)" in
    used)  next=added ;;
    added) next=count ;;
    *)     next=used ;;    # count, and alpha, which joins the cycle here
  esac
  [ -n "${SUSHI_SORT_STATE:-}" ] || return 0
  printf '%s\n' "$next" > "$SUSHI_SORT_STATE" 2>/dev/null
  return 0
}

# "alias   added   used   user@host:port <TAB> alias" — column 1 is shown,
# column 2 is the payload.
#
# Ordered by the current sort mode, never alphabetically by accident: `bastion`
# being first because it starts with b is not useful. Rows the mode has no date
# or count for fall to the bottom, alphabetically among themselves.
#
# The ages sit between the alias and the target rather than after it: the target
# is the one column here worth fuzzy-matching, so it is never padded and never
# cut, and it is also the only one whose length varies enough to knock everything
# to its right out of line.
#
# $1 = the alias column width, if the caller already worked it out.
# $2 = the sort mode, if the caller already read it.
picker_lines() {
  clock_now
  local aw="${1:-}" mode
  [ -n "$aw" ] || aw="$(alias_width)"
  mode="$(sort_mode_norm "${2:-$(sort_mode_read)}")"
  local -a key
  if [ "$mode" = alpha ]; then
    key=("-k3,3f")
  else
    # have-a-key-or-not, then the key descending, then name — so your live hosts
    # lead and the cold ones trail in A-Z
    key=("-k1,1n" "-k2,2nr" "-k3,3f")
  fi

  host_facts | AWK -F'\t' -v a="$C_VALUE" -v t="$C_MUTED" -v v="$C_HEADING" -v z="$C_OFF" \
      -v aw="$aw" -v now="$NOW" -v tzoff="$TZOFF" -v mode="$mode" "$AWK_TIME"'
      {
        tgt = ($3 != "" ? $3 "@" : "") $2 ($4 != "22" ? ":" $4 : "")
        added = iso2epoch($5)
        if      (mode == "added") k = added + 0
        else if (mode == "count") k = $6 + 0
        else                      k = $7 + 0
        # the first three columns are sort keys, stripped again below
        printf "%d\t%d\t%s\t%s%-*s%s  %s%5s  %5s%s  %s%s%s\t%s\n", \
          (k > 0 ? 0 : 1), k, $1, \
          a, aw, $1, z, v, ago(added), ago($7), z, t, tgt, z, $1
      }
    ' | sort -t"$TAB" "${key[@]}" | cut -f4-
}

# The two lines fzf pins above the list.
#
# They travel down the same pipe as the rows (--header-lines=2) rather than
# through --header, because ctrl-s has to redraw the mode it just changed, and
# a --header string is fixed for the life of the process while reload replaces
# the input wholesale. Header lines are not matchable or selectable, so nothing
# else about the picker changes.
picker_header() {
  local aw="$1" mode="$2"
  printf 'ENTER connect · ctrl-s sort: %s · ctrl-e edit · ctrl-r rescan\n' \
    "$(sort_mode_label "$mode")"
  printf '%-*s  %5s  %5s  %s\n' "$aw" ALIAS ADDED USED TARGET
}

# Header and rows in one stream: what fzf is fed at startup, and what ctrl-s
# reloads. --next steps the mode on first, which is the only thing ctrl-s does.
#
# Each ordering is built at most once per picker. Nothing it is built from can
# change while the picker is up — ctrl-e and ctrl-r both close it before they
# touch the config or the history — so the second visit to an ordering is a
# `cat` of the first, and cycling all the way round costs three builds and then
# nothing. The ages are frozen at the same instant for every mode as a result,
# which is what you want: `2h` must not become `3h` halfway through a cycle.
#
# 0600, like the history cache and for the same reason: these rows are your
# whole server inventory, and a default umask would hand them to every account
# on the box.
picker_feed() {
  local aw mode cache="" feed
  [ "${1:-}" = --next ] && sort_mode_advance
  mode="$(sort_mode_read)"

  [ -n "${SUSHI_SORT_STATE:-}" ] && cache="$SUSHI_SORT_STATE.feed.$mode"
  if [ -n "$cache" ] && [ -s "$cache" ]; then
    cat "$cache"
    return 0
  fi

  aw="$(alias_width)"
  feed="$(picker_header "$aw" "$mode"; picker_lines "$aw" "$mode")"
  [ -n "$feed" ] || return 0
  if [ -n "$cache" ]; then
    ( umask 077; printf '%s\n' "$feed" > "$cache" ) 2>/dev/null
  fi
  printf '%s\n' "$feed"
}

# Which reload action ctrl-s gets.
#
# Plain `reload` runs the command asynchronously: fzf empties the list the
# moment you press the key — and since the header travels down the same pipe,
# the two header lines go with it and everything below jumps up — then fills it
# back in when the child is done. That flash is the "little jump". `reload-sync`
# waits for the complete output and swaps it in one paint instead.
#
# It landed in fzf 0.36, and an action fzf does not know makes it exit with a
# usage error at startup rather than ignore the bind — so on anything older the
# async reload is still the right answer, a flicker being better than no picker.
fzf_reload_action() {
  local v maj min
  v="$(fzf --version 2>/dev/null)"
  v="${v%% *}"          # "0.36.0 (brew)" -> "0.36.0"
  maj="${v%%.*}"
  v="${v#*.}"
  min="${v%%.*}"
  min="${min%%[!0-9]*}" # some distros ship "0.24.4-1"
  case "$maj$min" in
    ''|*[!0-9]*) printf 'reload'; return 0 ;;
  esac
  if [ "$maj" -gt 0 ] || [ "$min" -ge 36 ]
    then printf 'reload-sync'
    else printf 'reload'
  fi
}

# Runs fzf and prints the chosen alias on stdout — nothing else goes to stdout,
# so callers can safely do `target=$(sushi choose)`. fzf draws on /dev/tty, and
# the ctrl-e / ctrl-r side trips send their output to stderr for the same reason.
# Returns 1 when nothing was chosen.
run_picker() {
  local feed out key rec mode rows stty_saved=""

  # ctrl-s reloads under the next ordering; the mode it reads, and the rows it
  # has already built, live here. Set up before the first feed so that feed is
  # cached too — come back round the cycle and it is a `cat`.
  SORT_STATE="$(mktemp "${TMPDIR:-/tmp}/sushi-sort.XXXXXX")" || die "mktemp failed"
  trap cleanup_sort EXIT
  export SUSHI_SORT_STATE="$SORT_STATE"
  mode="$(sort_mode_read)"
  printf '%s\n' "$mode" > "$SORT_STATE"

  # "nothing to pick from" before "install fzf": with an empty config the first
  # is the actionable message, and fzf would have nothing to show either way.
  feed="$(picker_feed)"
  rows=$(( $(printf '%s\n' "$feed" | wc -l) - 2 ))   # minus the header block
  if [ "$rows" -le 0 ]; then
    warn "no hosts in $CONFIG yet — run: sushi scan"
    return 1
  fi
  have fzf || { warn_no_fzf; return 1; }

  # ^S is XOFF under legacy terminal flow control: with ixon on, the tty eats the
  # keypress and freezes the screen instead of letting fzf see it. Freed for the
  # life of the picker and put back after — fzf restores the termios it started
  # with, so this has to be saved outside it.
  stty_saved="$(stty -g < /dev/tty 2>/dev/null)" || stty_saved=""
  [ -n "$stty_saved" ] && stty -ixon < /dev/tty 2>/dev/null

  out="$(printf '%s\n' "$feed" \
    | FZF --ansi --delimiter='\t' --with-nth=1 --reverse --border \
        --prompt='ssh ❯ ' --query="${1:-}" \
        --header-lines=2 \
        --expect=ctrl-e,ctrl-r \
        --bind "ctrl-s:$(fzf_reload_action)('$SELF' __pickerfeed --next)" \
        --preview="'$SELF' __preview {2}" \
        --preview-window='right:45%')"

  [ -n "$stty_saved" ] && stty "$stty_saved" < /dev/tty 2>/dev/null
  cleanup_sort; SORT_STATE=""; unset SUSHI_SORT_STATE

  key="$(printf '%s\n' "$out" | sed -n 1p)"
  rec="$(printf '%s\n' "$out" | sed -n 2p | cut -f2)"

  case "$key" in
    ctrl-e) "${EDITOR:-vi}" "$CONFIG" >&2; return 1 ;;
    ctrl-r) cmd_scan >&2; return 1 ;;
  esac
  [ -n "$rec" ] || return 1
  printf '%s\n' "$rec"
}

# Standalone use: pick, then become ssh.
cmd_pick() {
  local rec
  rec="$(run_picker "${1:-}")" || return 0
  [ -n "$rec" ] || return 0
  printf '→ ssh %s\n' "$rec" >&2
  exec ssh "$rec"
}

# Every theme on the search path, grouped by directory so precedence is visible
# rather than something you have to know: the first `ansi.yaml` down the list is
# the one you get, and any later one is marked shadowed.
cmd_themes() {
  local dir ext f name seen=" " shadow="" n
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    # List the dir even when it does not exist yet: `sushi themes` is how you
    # find out where to put a file, and ~/.config/sushi/themes is the answer.
    # A glob that matched nothing comes back as itself; skip those below.
    printf '%s%s%s\n' "$C_HEADING" "$(tilde "$dir")" "$C_OFF"
    n=0
    set -- "$dir"/*.yaml "$dir"/*.yml
    for f in "$@"; do
      [ -f "$f" ] || continue
      n=$((n + 1))
      name="${f##*/}"; for ext in .yaml .yml; do name="${name%$ext}"; done
      case "$seen" in
        *" $name "*) shadow=" $(tilde "$(theme_find "$name")")" ;;
        *) seen="$seen$name "; shadow="" ;;
      esac
      if [ "$f" = "$THEME_SOURCE" ] || \
         { [ "$THEME_SOURCE" = built-in ] && [ "$name" = sushi ] && [ -z "$shadow" ]; }; then
        printf '  %s*%s %s%-12s%s %sactive%s\n' \
            "$C_PROMPT" "$C_OFF" "$C_VALUE" "$name" "$C_OFF" "$C_MUTED" "$C_OFF"
      elif [ -n "$shadow" ]; then
        printf '    %s%-12s%s %sshadowed by%s%s\n' \
            "$C_MUTED" "$name" "$C_OFF" "$C_MUTED" "$shadow" "$C_OFF"
      else
        printf '    %s%s%s\n' "$C_VALUE" "$name" "$C_OFF"
      fi
    done
    [ "$n" -eq 0 ] && printf '    %s(empty)%s\n' "$C_MUTED" "$C_OFF"
  done <<EOF
$(theme_dirs)
EOF
  # `SUSHI_THEME=… ssh` only themes the picker in wrap mode. Default is
  # key,enter, where ssh is the real binary and the env var is ignored.
  printf '\n  %ssushi theme set%s to pick one and keep it\n' "$C_ACCENT" "$C_OFF"
  printf '  %sSUSHI_THEME=<name> sushi%s to try one without keeping it\n' \
      "$C_ACCENT" "$C_OFF"
}

# `sushi theme set` with no name: choose one by looking at it. The preview pane
# renders the palette and a few real rows of your own host table in that theme,
# which is the only honest way to answer "does this work in my terminal" —
# a hex value in a list tells you nothing about how it sits next to your
# background. Prints the chosen name; empty when the picker was dismissed.
theme_pick() {
  local out
  have fzf || { warn "no fzf, so no picker — try: sushi theme set <name>"; return 1; }
  out="$(theme_names \
    | FZF --reverse --border \
          --prompt='theme ❯ ' \
          --preview="SUSHI_THEME={} '$SELF' __themepreview" \
          --preview-window='right:60%')" || return 0
  printf '%s\n' "$out"
}

# The preview pane for one theme. Its own subcommand rather than a shell
# one-liner inside the --preview string: quoting a two-command pipeline through
# fzf, sh and bash is how you end up with a preview that silently prints
# nothing, and this is testable.
cmd_theme_preview() {
  local rows
  printf '  %s%s%s\n' "$C_VALUE" "${THEME_NAME:-none}" "$C_OFF"
  case "$THEME_SOURCE" in
    built-in) printf '  %sbuilt in, no file%s\n' "$C_MUTED" "$C_OFF" ;;
    *) printf '  %s%s%s\n' "$C_MUTED" "$(tilde "$THEME_SOURCE")" "$C_OFF" ;;
  esac
  theme_roles '' '' '' '' '' ''
  # the real host table, so you are judging the thing you will actually look at.
  # Column 2 is the record fzf hides with --with-nth=1; hide it here too.
  rows="$(picker_lines "" 2>/dev/null | cut -f1 | head -6)"
  [ -n "$rows" ] || return 0
  printf '\n  %ssample%s\n' "$C_HEADING" "$C_OFF"
  printf '%s\n' "$rows" | sed 's/^/  /'
}

# Persist a theme choice by writing `export SUSHI_THEME=` into the shell rc.
#
# Two things this has to get right, both learned from the ~/.ssh/config path:
# never destroy what is already in the file, and be idempotent — running it
# twice must leave one line, not two.
#
# The line goes OUTSIDE install.sh'"'"'s `# >>> sushi >>>` block, immediately above
# it. Inside would read more tidily and would be wrong: install.sh rewrites
# everything between its markers on every run, so a theme set today would
# vanish the next time anyone re-ran the installer.
cmd_theme_set() {
  local name="${1:-}" rc file body stray
  case "$name" in
    "") name="$(theme_pick)" || return 1
        [ -n "$name" ] || return 0 ;;    # escaped out of the picker: change nothing
    -*) die "unknown option: $name" ;;
  esac

  # Refuse to persist something that will not resolve tomorrow morning. A path
  # is stored as given (an absolute one, so it still works from anywhere).
  case "$name" in
    none|sushi) : ;;
    */*|*.yaml|*.yml)
      file="${name/#\~/$HOME}"
      [ -r "$file" ] || die "cannot read $file"
      case "$file" in /*) name="$file" ;; *) name="$PWD/$file" ;; esac ;;
    *) theme_find "$name" >/dev/null || die "no theme named $name — try: sushi themes" ;;
  esac

  rc="${SUSHI_RC:-${ZDOTDIR:-$HOME}/.zshrc}"
  [ -e "$rc" ] || : > "$rc" || die "cannot write $rc"
  [ -w "$rc" ] || die "cannot write $rc"
  cp "$rc" "$rc.sushi-backup" || die "could not back up $rc"

  # Any SUSHI_THEME the user set by hand elsewhere in the file would fight this
  # one — silently, since whichever runs last wins. Say so rather than leaving
  # them to find out.
  stray="$(AWK -v b="$THEME_BEGIN" -v e="$THEME_END" '
    index($0, b) { f = 1; next } index($0, e) { f = 0; next }
    !f && /^[ \t]*(export[ \t]+)?SUSHI_THEME=/ { print FNR ": " $0 }' "$rc")"
  [ -n "$stray" ] && printf 'sushi: replacing an existing SUSHI_THEME in %s:\n%s\n' \
      "$(tilde "$rc")" "$stray" >&2

  body="$(mktemp "${TMPDIR:-/tmp}/sushi-rc.XXXXXX")" || die "mktemp failed"
  # strip our own block and any hand-written assignment, then put one back
  AWK -v b="$THEME_BEGIN" -v e="$THEME_END" '
    index($0, b) { f = 1; next } index($0, e) { f = 0; next }
    f { next }
    /^[ \t]*(export[ \t]+)?SUSHI_THEME=/ { next }
    { print }' "$rc" > "$body"

  if [ "$name" = sushi ]; then
    # the built-in is what you get with nothing set, so the honest way to
    # choose it is to leave no line behind
    cat "$body" > "$rc"
    rm -f "$body"
    printf 'Using the built-in theme: removed SUSHI_THEME from %s (backup: %s)\n' \
        "$(tilde "$rc")" "$(tilde "$rc.sushi-backup")"
  else
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
    printf 'Wrote export SUSHI_THEME=%s to %s (backup: %s)\n' \
        "$name" "$(tilde "$rc")" "$(tilde "$rc.sushi-backup")"
  fi
  printf 'New shells pick that up; for this one:  source %s\n\n' "$(tilde "$rc")"

  # Show the result in its own colours — the point of choosing a theme is to
  # look at it, and re-running ourselves is the only way to load one after the
  # palette has already been set up.
  SUSHI_THEME="$name" exec "$SELF" theme
}

# The six roles, each printed in its own colour. $1..$6 are the descriptions, so
# the fzf preview can pass empty ones and stay inside a narrow pane.
theme_roles() {
  printf '\n  %sroles%s\n' "$C_HEADING" "$C_OFF"
  printf '    %s%-9s%s %s%-18s%s %s\n' "$C_MUTED" accent  "$C_OFF" "$C_ACCENT"  "$S_ACCENT"  "$C_OFF" "$1"
  printf '    %s%-9s%s %s%-18s%s %s\n' "$C_MUTED" heading "$C_OFF" "$C_HEADING" "$S_HEADING" "$C_OFF" "$2"
  printf '    %s%-9s%s %s%-18s%s %s\n' "$C_MUTED" prompt  "$C_OFF" "$C_PROMPT"  "$S_PROMPT"  "$C_OFF" "$3"
  printf '    %s%-9s%s %s%-18s%s %s\n' "$C_MUTED" target  "$C_OFF" "$C_TARGET"  "$S_TARGET"  "$C_OFF" "$4"
  printf '    %s%-9s%s %s%-18s%s %s\n' "$C_MUTED" value   "$C_OFF" "$C_VALUE"   "$S_VALUE"   "$C_OFF" "$5"
  printf '    %s%-9s%s %s%-18s%s %s\n' "$C_MUTED" muted   "$C_OFF" "$C_MUTED"   "$S_MUTED"   "$C_OFF" "$6"
}

# Which theme you got, where it came from, and what is in it — the answer to
# "I edited a yaml file and nothing changed", which is nearly always that the
# file is somewhere theme_find does not look, or that SUSHI_THEME still says
# something else.
cmd_theme() {
  local dir
  case "${1:-}" in
    list|--list|-l) cmd_themes; return $? ;;
    set)            shift; cmd_theme_set "${1:-}"; return $? ;;
    "")             : ;;
    *)              die "usage: sushi theme [list | set [<name>]]" ;;
  esac
  printf '%s%s%s\n' "$C_VALUE" "${THEME_NAME:-none}" "$C_OFF"
  printf '  %s%-9s%s %s\n' "$C_MUTED" 'source' "$C_OFF" "$THEME_SOURCE"
  [ "$THEME_SOURCE" = built-in ] || printf '  %s%-9s%s %s\n' \
      "$C_MUTED" '' "$C_OFF" 'read on top of the built-in theme, which fills in whatever it omits'
  if [ "$SUSHI_THEME" = none ]; then
    printf '  %sSUSHI_THEME=none — every colour is left to your terminal%s\n' \
        "$C_MUTED" "$C_OFF"
    return 0
  fi
  theme_roles 'match highlights, markers, key paths' 'headers and section labels' \
              'the `imported` tag' 'the resolved target in the preview' \
              'aliases and values' 'ages, keys, everything secondary'
  printf '\n  %sfzf%s\n' "$C_HEADING" "$C_OFF"
  printf '%s\n' "$FZF_COLORS" | tr ',' '\n' | while IFS=: read -r k v; do
    [ -n "$k" ] || continue
    printf '    %s%-9s%s %s\n' "$C_MUTED" "$k" "$C_OFF" "$v"
  done
  printf '    %s%-9s%s %s   %s%-9s%s %s\n' \
      "$C_MUTED" pointer "$C_OFF" "$SYM_POINTER" "$C_MUTED" marker "$C_OFF" "$SYM_MARKER"
  printf '\n  %ssearched%s\n' "$C_HEADING" "$C_OFF"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    printf '    %s%s%s\n' "$C_MUTED" "$(tilde "$dir")" "$C_OFF"
  done <<EOF
$(theme_dirs)
EOF
  printf '\n  %ssushi theme list%s shows them all, %ssushi theme set%s picks one and keeps it.\n' \
      "$C_ACCENT" "$C_OFF" "$C_ACCENT" "$C_OFF"
}

usage() {
  # The header block, however long it grows — a hardcoded line range goes stale
  # the first time someone documents a new subcommand.
  AWK 'NR >= 3 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$SELF"
}

cmd_version() {
  local rev="" dir
  dir="$(dirname "$SELF")"
  # sushi is installed by `git clone` and updated by `git pull`, with nothing
  # copied anywhere — so in the normal case the commit is a more precise answer
  # than a hand-bumped number, and worth printing alongside it.
  if have git && [ -d "$dir/.git" ]; then
    rev="$(git -C "$dir" describe --always --dirty --tags 2>/dev/null)"
  fi
  if [ -n "$rev" ]; then
    printf 'sushi %s (%s)\n' "$VERSION" "$rev"
  else
    printf 'sushi %s\n' "$VERSION"
  fi
}
