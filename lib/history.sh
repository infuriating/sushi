# ------------------------------------------------------------------- history --

# Internal record separator. NOT a tab: bash treats tab as IFS whitespace, so
# `IFS=$'\t' read` collapses `a<TAB><TAB>c` into two fields and empty columns
# (a missing username, a default port) shift everything left.
SEP='|'
# A literal tab, for `IFS="$TAB" read` — writing $'\t' at each call site is easy
# to misread as a two-character string.
TAB=$'\t'

# ESC on its own, deliberately outside the palette below: SUSHI_THEME=none blanks
# every colour variable, and code that *strips* colours still needs the escape.
ESC=$'\033'

# Pull the destination out of one ssh command line.
# $1 = the command line, $2 = the epoch it was run at, if the history knew one.
# echoes: user|host|port|identityfile|proxyjump|epoch  (any but host may be
# empty); returns 1 if the line is not an ssh invocation.
#
# THE SLOW PATH, kept deliberately. extract_stream_awk below is the same grammar
# in awk and is what runs by default: this one is ~160us per call, which on a
# 20k-line history was ~450ms of a ~570ms scan — 80% of it. It stays because it
# is the reference implementation the test suite diffs the awk against, and
# because SUSHI_EXTRACT=bash is a way out if the awk ever disagrees on a history
# nobody thought of. Change one, change both, and the differential test will tell
# you if you did not.
extract_dest() {
  local -a t
  # Deliberate word splitting — with globbing off, so a history line like
  # `ssh host *.log` can't expand against the current directory.
  local reglob=0
  case $- in *f*) ;; *) reglob=1; set -f ;; esac
  # shellcheck disable=SC2206
  t=($1)
  [ "$reglob" = 1 ] && set +f

  local n=${#t[@]} i=0 tok user="" host="" port="" identity="" jump=""
  local ts="${2:-}"
  case "$ts" in *[!0-9]*) ts="" ;; esac

  while [ "$i" -lt "$n" ]; do
    case "${t[$i]}" in
      ssh|*/ssh)              i=$((i + 1)); break ;;
      sudo|command|time|nohup) i=$((i + 1)) ;;
      *) return 1 ;;
    esac
  done
  [ "$i" -gt 0 ] || return 1

  while [ "$i" -lt "$n" ]; do
    tok="${t[$i]}"
    case "$tok" in
      -p)  port="${t[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -p*) port="${tok#-p}";          i=$((i + 1)) ;;
      -l)  user="${t[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -l*) user="${tok#-l}";          i=$((i + 1)) ;;
      # worth keeping rather than skipping: these belong in the imported stanza
      -i)  identity="${t[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -i*) identity="${tok#-i}";          i=$((i + 1)) ;;
      -J)  jump="${t[$((i + 1))]:-}";     i=$((i + 2)) ;;
      -J*) jump="${tok#-J}";              i=$((i + 1)) ;;
      # other options that consume the next argument
      -[bcDEeFLmOoQRSWw]) i=$((i + 2)) ;;
      -*)  i=$((i + 1)) ;;
      *)   host="$tok"; i=$((i + 1)); break ;;
    esac
  done

  # history keeps the quotes you typed: ssh "deploy@host"
  host="${host%\"}"; host="${host#\"}"
  host="${host%\'}"; host="${host#\'}"
  [ -n "$host" ] || return 1

  # OpenSSH also accepts options *after* the destination: `ssh host -p 2222`
  while [ "$i" -lt "$n" ]; do
    tok="${t[$i]}"
    case "$tok" in
      -p)  [ -n "$port" ] || port="${t[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -p*) [ -n "$port" ] || port="${tok#-p}";          i=$((i + 1)) ;;
      -l)  [ -n "$user" ] || user="${t[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -l*) [ -n "$user" ] || user="${tok#-l}";          i=$((i + 1)) ;;
      -i)  [ -n "$identity" ] || identity="${t[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -i*) [ -n "$identity" ] || identity="${tok#-i}";          i=$((i + 1)) ;;
      -J)  [ -n "$jump" ] || jump="${t[$((i + 1))]:-}";         i=$((i + 2)) ;;
      -J*) [ -n "$jump" ] || jump="${tok#-J}";                  i=$((i + 1)) ;;
      -[bcDEeFLmOoQRSWw]) i=$((i + 2)) ;;
      -*)  i=$((i + 1)) ;;
      *)   break ;;   # remote command — stop
    esac
  done

  # ssh://user@host:port/
  case "$host" in
    ssh://*)
      host="${host#ssh://}"; host="${host%%/*}"
      case "$host" in *:*) port="${host##*:}"; host="${host%:*}" ;; esac
      ;;
  esac
  case "$host" in
    *@*) user="${host%@*}"; host="${host##*@}" ;;
  esac
  host="${host%:}"

  # plausibility: no slashes, no globs, sane charset
  case "$host" in
    ""|*/*|*[\*\?\$\`\'\"\(\)\{\}]*|-*|.*) return 1 ;;
  esac
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$user" =~ ^[A-Za-z0-9._-]*$ ]] || user=""
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=""

  # These end up verbatim in ~/.ssh/config, so anything that is not plainly a
  # path / a destination gets dropped rather than written out.
  identity="${identity%\"}"; identity="${identity#\"}"
  case "$identity" in *[!A-Za-z0-9._/~-]*) identity="" ;; esac
  jump="${jump%\"}"; jump="${jump#\"}"
  case "$jump" in *[!A-Za-z0-9._@:-]*) jump="" ;; esac

  printf '%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$user" "$SEP" "$host" "$SEP" "$port" "$SEP" "$identity" "$SEP" "$jump" \
    "$SEP" "$ts"
}

# The extractor, in awk: candidate history lines on stdin, one
# user|host|port|identityfile|proxyjump record out per line that is an ssh
# invocation. Lines that are not are dropped silently, exactly as extract_dest
# returning 1 dropped them.
#
# This is a transcription of extract_dest, not a reinterpretation — including the
# prefix stripping its caller used to do, which had to move in here to keep the
# whole thing one pass. The test suite diffs the two implementations over a
# corpus of ~11k lines and requires byte-identical output, so read the two side
# by side if you touch either.
#
# Why it exists: a bash function call per history line is ~160us, and a shell
# history is mostly not ssh. On a 20k-line history (2.8k lines containing "ssh")
# the bash loop was ~570ms and this is ~55ms.
#
# `-v q=`: the host may arrive wrapped in single quotes, and an awk program lives
# inside a single-quoted shell string, so the character is passed in rather than
# escaped into the source.
# Dates, in both extractors. Every shell keeps them somewhere else, and two of
# them keep them on a *separate* line, so this is a small state machine rather
# than a substitution:
#
#   zsh EXTENDED_HISTORY  ": 1699999999:0;ssh host"   inline, same line
#   bash HISTTIMEFORMAT   "#1699999999"               the line before
#   fish                  "  when: 1699999999"        the line after
#
# fish is the awkward one: by the time the date arrives its record has already
# been printed, so it goes downstream as an `@@TS@@|<epoch>` marker for the
# aggregator to fold into the row above it. Only the exact shape each shell
# writes counts as a date, so a command that merely contains `when:` is still
# parsed as a command. Plain zsh and plain bash write no dates at all.
#
# Both implementations have to agree on every one of these to the byte — the test
# suite diffs them over a corpus that includes all three shapes.
extract_stream_awk() {
  AWK -v q="'" -v sep="$SEP" '
    function optarg(tok) { return (tok ~ /^-[bcDEeFLmOoQRSWw]$/) }
    # index of the LAST occurrence of c, mirroring ${var##*c} / ${var%c*}
    function lastidx(s, c,    k) {
      for (k = length(s); k >= 1; k--) if (substr(s, k, 1) == c) return k
      return 0
    }
    {
      line = $0
      # grep puts this between two runs of context: whatever "#<epoch>" we were
      # holding belonged to a command that is not in this stream
      if (line == "--") { pts = ""; next }
      # bash HISTTIMEFORMAT, dating the command on the NEXT line
      if (line ~ /^#[0-9]/) {
        w = substr(line, 2)
        pts = (w ~ /^[0-9]+$/ ? w : "")
        next
      }
      # fish, dating the command on the PREVIOUS line
      if (line ~ /^(  )?when: [0-9]/) {
        w = line; sub(/^(  )?when: /, "", w)
        if (w ~ /^[0-9]+$/) print "@@TS@@" sep w
        next
      }
      ts = ""
      # zsh EXTENDED_HISTORY:  ": 1699999999:0;cmd"
      if (substr(line, 1, 1) == ":" && index(line, ";") > 0) {
        zt = substr(line, 2, index(line, ";") - 2)
        sub(/^ /, "", zt)
        if (index(zt, ":") > 0) zt = substr(zt, 1, index(zt, ":") - 1)
        if (zt ~ /^[0-9]+$/) ts = zt
        line = substr(line, index(line, ";") + 1)
      }
      if (ts == "") ts = pts
      pts = ""
      # fish:  "- cmd: ssh ..."
      sub(/^- cmd: /, "", line)
      # take the last segment of pipes/&&/; so `foo && ssh bar` still counts.
      # `.*` is greedy, which is what makes these the ${var##*...} they replace.
      sub(/^.*&& /, "", line)
      sub(/^.*; /, "", line)
      sub(/^.*\| /, "", line)

      # bash word splitting ignores leading/trailing IFS and collapses runs;
      # awk split() does not, so trim first or token 1 comes back empty.
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      n = split(line, t, /[ \t]+/)

      # walk past the command word and the wrappers that may precede it
      i = 1; bail = 0
      while (i <= n) {
        if (t[i] == "ssh" || t[i] ~ /\/ssh$/) { i++; break }
        else if (t[i] == "sudo" || t[i] == "command" || t[i] == "time" || t[i] == "nohup") i++
        else { bail = 1; break }
      }
      if (bail || i == 1) next

      user = ""; host = ""; port = ""; id = ""; jump = ""
      while (i <= n) {
        tok = t[i]
        if      (tok == "-p")  { port = t[i+1] "";      i += 2 }
        else if (tok ~ /^-p./) { port = substr(tok, 3); i++ }
        else if (tok == "-l")  { user = t[i+1] "";      i += 2 }
        else if (tok ~ /^-l./) { user = substr(tok, 3); i++ }
        # worth keeping rather than skipping: these belong in the imported stanza
        else if (tok == "-i")  { id   = t[i+1] "";      i += 2 }
        else if (tok ~ /^-i./) { id   = substr(tok, 3); i++ }
        else if (tok == "-J")  { jump = t[i+1] "";      i += 2 }
        else if (tok ~ /^-J./) { jump = substr(tok, 3); i++ }
        # other options that consume the next argument
        else if (optarg(tok))  { i += 2 }
        else if (tok ~ /^-/)   { i++ }
        else                   { host = tok ""; i++; break }
      }

      # history keeps the quotes you typed: ssh "deploy@host"
      sub(/"$/, "", host); sub(/^"/, "", host)
      if (substr(host, length(host), 1) == q) host = substr(host, 1, length(host) - 1)
      if (substr(host, 1, 1) == q) host = substr(host, 2)
      if (host == "") next

      # OpenSSH also accepts options *after* the destination: `ssh host -p 2222`
      while (i <= n) {
        tok = t[i]
        if      (tok == "-p")  { if (port == "") port = t[i+1] "";      i += 2 }
        else if (tok ~ /^-p./) { if (port == "") port = substr(tok, 3); i++ }
        else if (tok == "-l")  { if (user == "") user = t[i+1] "";      i += 2 }
        else if (tok ~ /^-l./) { if (user == "") user = substr(tok, 3); i++ }
        else if (tok == "-i")  { if (id   == "") id   = t[i+1] "";      i += 2 }
        else if (tok ~ /^-i./) { if (id   == "") id   = substr(tok, 3); i++ }
        else if (tok == "-J")  { if (jump == "") jump = t[i+1] "";      i += 2 }
        else if (tok ~ /^-J./) { if (jump == "") jump = substr(tok, 3); i++ }
        else if (optarg(tok))  { i += 2 }
        else if (tok ~ /^-/)   { i++ }
        else break   # remote command — stop
      }

      # ssh://user@host:port/
      if (host ~ /^ssh:\/\//) {
        host = substr(host, 7)
        if (index(host, "/") > 0) host = substr(host, 1, index(host, "/") - 1)
        p = lastidx(host, ":")
        if (p > 0) { port = substr(host, p + 1); host = substr(host, 1, p - 1) }
      }
      p = lastidx(host, "@")
      if (p > 0) { user = substr(host, 1, p - 1); host = substr(host, p + 1) }
      sub(/:$/, "", host)

      # plausibility. The bash original also rejected slashes, globs, quotes and
      # a leading dash or dot separately; this regex is strictly stricter than all
      # of that, so it is the only check needed.
      if (host !~ /^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/) next
      if (user !~ /^[A-Za-z0-9._-]*$/) user = ""
      # ^[0-9]{1,5}$ without an interval expression: onetrueawk has no {n,m}
      if (port !~ /^[0-9]+$/ || length(port) > 5) port = ""

      # These end up verbatim in ~/.ssh/config, so anything that is not plainly a
      # path / a destination gets dropped rather than written out.
      sub(/"$/, "", id); sub(/^"/, "", id)
      if (id ~ /[^A-Za-z0-9._\/~-]/) id = ""
      sub(/"$/, "", jump); sub(/^"/, "", jump)
      if (jump ~ /[^A-Za-z0-9._@:-]/) jump = ""

      print user sep host sep port sep id sep jump sep ts
    }'
}

# The same contract as extract_stream_awk, via the bash extract_dest above.
extract_stream_bash() {
  local line ts pts=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '--') pts=""; continue ;;
      '#'[0-9]*)
        pts="${line#\#}"
        case "$pts" in *[!0-9]*) pts="" ;; esac
        continue
        ;;
      '  when: '[0-9]*|'when: '[0-9]*)
        # the FIRST "when: ", so a line with two of them is not a date to either
        # implementation rather than a date to only one of them
        ts="${line#*when: }"
        case "$ts" in *[!0-9]*) ts="" ;; esac
        [ -n "$ts" ] && printf '@@TS@@%s%s\n' "$SEP" "$ts"
        continue
        ;;
    esac
    ts=""
    # zsh EXTENDED_HISTORY:  ": 1699999999:0;cmd"
    case "$line" in
      ':'*';'*)
        ts="${line%%;*}"; ts="${ts#:}"; ts="${ts# }"; ts="${ts%%:*}"
        case "$ts" in ""|*[!0-9]*) ts="" ;; esac
        line="${line#*;}"
        ;;
    esac
    [ -n "$ts" ] || ts="$pts"
    pts=""
    # fish:  "- cmd: ssh ..."
    case "$line" in '- cmd: '*) line="${line#- cmd: }" ;; esac
    # take the last segment of pipes/&&/; so `foo && ssh bar` still counts
    line="${line##*&& }"; line="${line##*; }"; line="${line##*| }"
    extract_dest "$line" "$ts" 2>/dev/null
  done
  return 0
}

# SUSHI_EXTRACT=bash falls back to the reference implementation. It is ~10x
# slower and exists as an escape hatch, not as a supported mode.
extract_stream() {
  if [ "${SUSHI_EXTRACT:-awk}" = bash ]; then
    extract_stream_bash
  else
    extract_stream_awk
  fi
}

history_files() {
  local f
  for f in "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.history" \
           "$HOME/.local/share/fish/fish_history"; do
    [ -r "$f" ] && printf '%s\n' "$f"
  done
  for f in "$HOME"/.zsh_sessions/*.history; do
    [ -r "$f" ] && printf '%s\n' "$f"
  done
}

# Records: count|user|host|port|identityfile|proxyjump|last  (most-used first)
#
# `last` is the epoch of the newest invocation the history could date, or empty.
# See the note above extract_stream_awk for where each shell keeps it.
scan_history() {
  local line
  local -a files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(history_files)
  [ "${#files[@]}" -gt 0 ] || return 0

  # grep first, so the extractor only ever sees candidate lines: most of a shell
  # history is not ssh, and on a 20k-line history this is the difference between
  # ~2s and ~100ms even with the awk extractor doing the parsing.
  # LC_ALL=C for the same reason as AWK(): GNU grep in a UTF-8 locale can decline
  # to match inside a line whose bytes are not valid encoding, which would drop
  # the ssh command sitting next to a bad paste. "ssh" is ASCII, so byte matching
  # is strictly more inclusive and never less correct.
  # -B1 -A1 because bash and fish keep the date on the line before / after the
  # command, so the date is not on the line grep matched. It is only worth the
  # extra lines because the extractor is awk: three candidate lines where there
  # was one costs ~4ms on a 20k-line history, where a bash-function-per-line
  # parser would have made it ~450ms.
  LC_ALL=C grep -hF -B1 -A1 ssh -- "${files[@]}" 2>/dev/null \
    | extract_stream \
    | AWK -v sep="$SEP" '
        # `sort | uniq -c` cannot do the counting any more: the dates differ line
        # to line, so every row would be unique. Counting here instead is also
        # what lets a trailing fish marker land on the row it dates.
        BEGIN { FS = sep }
        $1 == "@@TS@@" {
          if (pend != "" && $2 + 0 > last[pend] + 0) last[pend] = $2
          pend = ""                      # one marker, one record — the next
          next                           # one belongs to somebody else
        }
        {
          key = $1 "|" $2 "|" $3 "|" $4 "|" $5
          if (!(key in cnt)) order[++m] = key
          cnt[key]++
          if ($6 != "") {
            if ($6 + 0 > last[key] + 0) last[key] = $6
            pend = ""
          } else pend = key
        }
        END {
          for (i = 1; i <= m; i++) print cnt[order[i]] "|" order[i] "|" last[order[i]]
        }' \
    | sort -t"$SEP" -k2 \
    | AWK -F'[|]' '
        # Fold "same user@host, port unknown" rows into the port we did observe,
        # so `ssh -p 2022 x@h` and `ssh x@h` do not become two separate hosts.
        # identityfile / proxyjump: first non-empty wins. Input order is fixed by
        # `sort`, so that is deterministic, and one host rarely has two.
        {
          key = $2 "|" $3
          if ($4 == "") {
            empty[key] += $1
            if ($5 != "" && eid[key] == "") eid[key] = $5
            if ($6 != "" && ejp[key] == "") ejp[key] = $6
            if ($7 + 0 > elast[key] + 0) elast[key] = $7
            next
          }
          pk = key "|" $4
          if (!(pk in cnt)) order[++m] = pk
          cnt[pk] += $1
          if ($5 != "" && id[pk] == "") id[pk] = $5
          if ($6 != "" && jp[pk] == "") jp[pk] = $6
          if ($7 + 0 > lst[pk] + 0) lst[pk] = $7
          if (cnt[pk] > best[key]) { best[key] = cnt[pk]; bestpk[key] = pk }
        }
        END {
          for (k in empty) {
            if (k in bestpk) {
              pk = bestpk[k]
              cnt[pk] += empty[k]
              if (id[pk] == "" && eid[k] != "") id[pk] = eid[k]
              if (jp[pk] == "" && ejp[k] != "") jp[pk] = ejp[k]
              if (elast[k] + 0 > lst[pk] + 0) lst[pk] = elast[k]
            } else {
              pk = k "|"; order[++m] = pk; cnt[pk] = empty[k]
              id[pk] = eid[k]; jp[pk] = ejp[k]; lst[pk] = elast[k]
            }
          }
          for (i = 1; i <= m; i++) {
            pk = order[i]
            split(pk, a, "|")
            print cnt[pk] "|" a[1] "|" a[2] "|" a[3] "|" id[pk] "|" jp[pk] "|" lst[pk]
          }
        }' \
    | sort -rn
}

# ------------------------------------------------------------------ known_hosts --

# Unhashed hostnames only — hashed (|1|...) entries are unrecoverable by design.
scan_known_hosts() {
  local f
  for f in "$SSH_DIR/known_hosts" "$SSH_DIR/known_hosts2"; do
    [ -r "$f" ] || continue
    AWK '{ n = split($1, a, ","); for (i = 1; i <= n; i++) print a[i] }' "$f"
  done | grep -v '^|' | sed 's/^\[\(.*\)\]:.*$/\1/' | sort -u
}

# ------------------------------------------------------------------- aliasing --

# Selected records on stdin (count|user|host|port|identity|jump), the finished
# Host stanzas on stdout, with collision-free aliases.
#
# This used to be a bash loop, and it was by far the slowest thing sushi did:
# a `sanitize_alias` command substitution (two more inside it) plus a
# `printf | grep -Fxq` membership test per candidate — and a second one per
# retry, against a string that grew with every host. Five-ish forks a candidate,
# quadratic in the number of them: a dry run over 604 candidates took 9.5s, most
# of it in the kernel.
#
# awk does it in one pass with a real hash, so nothing forks and nothing is
# quadratic. The alias rules are unchanged: first-wins, then -<user>, then -2, -3.
# $1 (optional) forces the alias instead of deriving one. Only `sushi add` uses
# it, and only ever with a single record — forcing a name for a whole batch would
# give every stanza the same one.
build_additions() {
  local forced="${1:-}" added
  # One `date` per batch, and the picker reads it back out of the stanza —
  # nothing sushi knows about a host lives anywhere but the config. Both `scan`
  # and `add` come through here, so both get the note.
  added="$(date '+%Y-%m-%d %H:%M' 2>/dev/null)"
  { config_hosts | AWK -F'\t' '{ print tolower($1) }'
    printf '%s\n' '@@SUSHI_SELECTED@@'
    cat
  } | AWK -v sep="$SEP" -v forced="$forced" -v added="$added" '
      # ${host%%.*} for a name, srv-1-2-3-4 for a bare IP, then the same
      # lowercase-and-replace-the-rest that `tr A-Z a-z | tr -c a-z0-9._- -` did.
      function sanitize(h,   b) {
        if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
          b = h; gsub(/\./, "-", b); b = "srv-" b
        } else {
          b = h; sub(/\..*/, "", b)
        }
        b = tolower(b)
        gsub(/[^a-z0-9._-]/, "-", b)
        return b
      }
      BEGIN { mode = 0 }
      $0 == "@@SUSHI_SELECTED@@" { mode = 1; FS = sep; next }
      mode == 0 { if ($0 != "") taken[$0] = 1; next }
      {
        user = $2; host = $3; port = $4; id = $5; jump = $6
        if (host == "") next

        if (forced != "") {
          name = forced
        } else {
          base = sanitize(host)
          name = base
          if (name in taken) name = base (user != "" ? "-" user : "")
          i = 2
          while (name in taken) { name = base "-" i; i++ }
        }
        taken[name] = 1

        print "Host " name
        print "    HostName " host
        if (user != "")
          print "    User " user
        else
          print "    # User ?   (none recorded — ssh will fall back to your local login)"
        if (port != "" && port != "22") print "    Port " port
        # Recovered from the command line you actually typed, so a host that needs
        # a specific key or a bastion imports without hand-editing.
        if (id != "")   print "    IdentityFile " id
        if (jump != "") print "    ProxyJump " jump
        if (added != "") print "    # added " added
        print ""
      }'
}
