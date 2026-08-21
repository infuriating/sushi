#!/usr/bin/env bash
#
# sushi test suite. No fzf and no terminal required.
#
#   test/run.sh              run everything
#   test/run.sh -v           show every assertion, not just failures
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUSHI="$ROOT/sushi"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0; FAIL=0; SKIP=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sushi-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# theme_dirs prefers $XDG_CONFIG_HOME over $HOME/.config. CI (and some desktops)
# export it pointing at the real home, which would hide every theme the suite
# plants under its fake HOME. Same idea for SUSHI_THEME: the suite assumes the
# built-in default unless a test sets it.
unset XDG_CONFIG_HOME SUSHI_THEME

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS + 1)); [ "$VERBOSE" = 1 ] && { green "  ok  "; printf '%s\n' "$1"; }; return 0; }
no()   { FAIL=$((FAIL + 1)); red "  FAIL"; printf ' %s\n' "$1"; return 0; }
skip() { SKIP=$((SKIP + 1)); dim "  skip"; printf ' %s (%s)\n' "$1" "$2"; return 0; }

section() { printf '\n%s\n' "$1"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"
    printf '        expected: %s\n' "$(printf '%s' "$2" | head -20)"
    printf '        actual:   %s\n' "$(printf '%s' "$3" | head -20)"
  fi
}

# assert_has <label> <needle> <haystack>
assert_has() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) no "$1"; printf '        missing %s in:\n%s\n' "$2" "$(printf '%s' "$3" | sed 's/^/          /' | head -20)" ;;
  esac
}

# assert_lacks <label> <needle> <haystack>
assert_lacks() {
  case "$3" in
    *"$2"*) no "$1"; printf '        unexpectedly found %s\n' "$2" ;;
    *) ok "$1" ;;
  esac
}

# newhome <name> -> echoes a fresh fake $HOME
newhome() {
  local h="$WORK/$1"
  rm -rf "$h"; mkdir -p "$h/.ssh"
  printf '%s' "$h"
}

# count backup files without piping ls through grep
count_backups() {
  local f n=0
  for f in "$1"/config.sushi-backup-*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# run sushi with a given fake home
run() {
  local h="$1"; shift
  HOME="$h" "$SUSHI" "$@" 2>&1
}

# Run sushi with a fake home under a deadline, echoing its output; returns 124 if
# it had to be killed. macOS has no `timeout`, and the failure this guards
# against — argument parsing that never advances — hangs rather than fails, which
# in CI costs a whole runner instead of one red assertion.
run_bounded() {
  local h="$1" secs="$2"; shift 2
  local out="$WORK/bounded.$$" pid rc i=0 lim
  lim=$((secs * 10))
  ( HOME="$h" "$SUSHI" "$@" >"$out" 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$lim" ]; do
    sleep 0.1; i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$out"
    return 124
  fi
  wait "$pid"; rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

# import everything sushi finds, non-interactively
import_all() {
  local h="$1"
  printf 'w\n' | HOME="$h" SUSHI_ALL=1 "$SUSHI" scan 2>&1
}

# --------------------------------------------------------------------------
section "static checks"

if bash -n "$SUSHI" 2>/dev/null; then ok "sushi parses under bash"; else no "sushi parses under bash"; fi
lib_ok=1
for f in "$ROOT"/lib/*.sh; do
  if ! bash -n "$f" 2>/dev/null; then lib_ok=0; break; fi
done
if [ "$lib_ok" = 1 ]; then ok "lib/*.sh parse under bash"; else no "lib/*.sh parse under bash"; fi

if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$ROOT/sushi.zsh" 2>/dev/null; then ok "sushi.zsh parses under zsh"; else no "sushi.zsh parses under zsh"; fi
else
  skip "sushi.zsh parses under zsh" "zsh not installed"
fi

if command -v shellcheck >/dev/null 2>&1; then
  out="$(shellcheck -S warning -x "$SUSHI" 2>&1)"
  assert_eq "shellcheck clean at warning level" "" "$out"
else
  skip "shellcheck" "not installed"
fi

# git records the exec bit, and a file copied in from elsewhere arrives 0644 —
# committing it that way makes CI fail with "Permission denied" long after the
# working tree looks fine.
if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
  for f in sushi install.sh test/run.sh; do
    mode="$(cd "$ROOT" && git ls-files -s -- "$f" 2>/dev/null | awk '{ print $1 }')"
    if [ -z "$mode" ]; then
      skip "$f is executable in git" "not tracked"
    else
      assert_eq "$f is executable in git" "100755" "$mode"
    fi
  done
else
  skip "tracked exec bits" "not a git checkout"
fi

# a symlink on PATH must still find lib/ next to the real script
LINK="$WORK/sushi-link"
ln -s "$SUSHI" "$LINK"
out="$("$LINK" --version 2>&1)"
assert_has "a symlink to sushi still runs" "sushi " "$out"
assert_lacks "and does not look for lib/ next to the symlink" "No such file" "$out"

# --------------------------------------------------------------------------
section "ssh_config parsing"

H="$(newhome cfg)"
cat > "$H/.ssh/config" <<'EOF'
Host *
    ServerAliveInterval 60

Include conf.d/*.conf

Host prod-web
    HostName 10.20.30.40
    User deploy
    Port 2222

Host bastion legacy-jump
    HostName jump.example.com
    User luca

Host wild-*
    User nobody
EOF
mkdir -p "$H/.ssh/conf.d"
printf 'Host from-include\n    HostName inc.example.com\n    User git\n' > "$H/.ssh/conf.d/w.conf"

out="$(run "$H" list)"
assert_has   "reads a plain stanza"                 "prod-web" "$out"
assert_has   "keeps a non-default port"             "deploy@10.20.30.40:2222" "$out"
assert_has   "expands Include"                      "from-include" "$out"
assert_has   "first alias of a multi-pattern Host"  "bastion" "$out"
assert_has   "second alias of a multi-pattern Host" "legacy-jump" "$out"
assert_lacks "skips the Host * catch-all"           "ServerAlive" "$out"
assert_lacks "skips wildcard patterns"              "wild-" "$out"
# careful: a naive ":22" search also matches ":2222"
n="$(printf '%s\n' "$out" | grep -c ':22$' || true)"
assert_eq "omits :22 for the default port" "0" "$n"

# ssh_config accepts Key=Value as well as Key Value
H="$(newhome cfgeq)"
cat > "$H/.ssh/config" <<'EOF'
Host=eqhost
    HostName=eq.example.com
    User=equser
    Port=2222
Host spaced
    HostName spaced.example.com
EOF
out="$(run "$H" list)"
assert_has "reads Host=name"              "eqhost" "$out"
assert_has "reads HostName= / User= / Port=" "equser@eq.example.com:2222" "$out"
assert_has "space-separated stanzas still work" "spaced" "$out"

# --------------------------------------------------------------------------
section "history parsing"

H="$(newhome hist)"
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh root@203.0.113.9
: 2:0;ssh root@203.0.113.9
: 3:0;ssh -p 2022 deploy@staging.example.com
: 4:0;ssh deploy@staging.example.com
: 5:0;ssh other@late-flag.example.com -p 8022
: 6:0;ssh -i ~/.ssh/id_ed25519 keyed@keys.example.com
: 7:0;ssh -o StrictHostKeyChecking=no opt@opts.example.com
: 8:0;ssh -J jumper@bastion.example.com deep@behind.example.com
: 9:0;ssh -l flaguser flag-l.example.com
: 10:0;ssh "quoted@quotes.example.com"
: 11:0;cd /tmp && ssh chained@chain.example.com
: 12:0;sudo ssh sudoer@sudo.example.com
: 13:0;ssh nouser.example.com
: 14:0;ssh UPPER.Example.COM
: 15:0;echo "ssh is a great tool"
: 16:0;# ssh commented@out.example.com
: 17:0;ssh-keygen -t ed25519
: 18:0;scp thing.txt scpuser@scp.example.com:/tmp/
: 19:0;git push origin main
: 20:0;ssh localhost
EOF
cand="$(run "$H" __candidates)"

assert_has   "counts repeats"                    "2|root|203.0.113.9|"                    "$cand"
assert_has   "-p before the host"                "|deploy|staging.example.com|2022"       "$cand"
assert_has   "-p after the host"                 "1|other|late-flag.example.com|8022"     "$cand"
assert_has   "-i is kept, not skipped"           "1|keyed|keys.example.com||~/.ssh/id_ed25519|" "$cand"
assert_has   "skips -o and its argument"         "1|opt|opts.example.com|"                "$cand"
assert_has   "-J picks the real destination"     "1|deep|behind.example.com|"             "$cand"
assert_has   "-J is kept as the proxy jump"      "1|deep|behind.example.com|||jumper@bastion.example.com" "$cand"
# the jump host must never be mistaken for the destination — check the host
# field itself, since it now legitimately appears in the proxyjump field
hosts="$(printf '%s\n' "$cand" | awk -F'|' '{ print $3 }')"
assert_lacks "the jump host is not a destination" "bastion.example.com" "$hosts"
assert_has   "-l supplies the username"          "1|flaguser|flag-l.example.com|"         "$cand"
assert_has   "strips surrounding quotes"         "1|quoted|quotes.example.com|"           "$cand"
assert_has   "finds ssh after &&"                "1|chained|chain.example.com|"           "$cand"
assert_has   "finds ssh after sudo"              "1|sudoer|sudo.example.com|"             "$cand"
assert_has   "host with no username"             "1||nouser.example.com|"                 "$cand"
assert_has   "preserves hostname case"           "UPPER.Example.COM"                      "$cand"
assert_lacks "ignores ssh inside a quoted string" "great"                                 "$cand"
assert_lacks "ignores commented-out commands"    "out.example.com"                        "$cand"
# `ed25519` now legitimately appears as an identityfile, so check the host field
assert_lacks "ignores ssh-keygen"                "ed25519"                                "$hosts"
assert_lacks "and its flags never become hosts"  "-t"                                     "$hosts"
assert_lacks "ignores scp"                       "scp.example.com"                        "$cand"

# the -p 2022 / no-port pair must collapse into one entry
n="$(printf '%s\n' "$cand" | grep -c 'staging\.example\.com')"
assert_eq "same host with and without a port collapses" "1" "$n"
assert_has "the collapsed entry keeps the port" "2|deploy|staging.example.com|2022" "$cand"

# --------------------------------------------------------------------------
section "history parsing: other shells"

H="$(newhome shells)"
printf 'ssh bashuser@bash.example.com\n' > "$H/.bash_history"
mkdir -p "$H/.local/share/fish"
printf -- '- cmd: ssh fishuser@fish.example.com\n  when: 1\n' > "$H/.local/share/fish/fish_history"
mkdir -p "$H/.zsh_sessions"
printf 'ssh sessuser@session.example.com\n' > "$H/.zsh_sessions/abc.history"
cand="$(run "$H" __candidates)"
assert_has "reads .bash_history"           "bashuser|bash.example.com"      "$cand"
assert_has "reads fish_history"            "fishuser|fish.example.com"      "$cand"
assert_has "reads .zsh_sessions/*.history" "sessuser|session.example.com"   "$cand"

# --------------------------------------------------------------------------
section "history parsing: globbing safety"

H="$(newhome glob)"
touch "$H/aaa.log" "$H/bbb.log"
printf ': 1:0;ssh globber@globs.example.com *.log\n' > "$H/.zsh_history"
cand="$(cd "$H" && HOME="$H" "$SUSHI" __candidates 2>&1)"
assert_has   "an unquoted glob in history does not expand" "1|globber|globs.example.com|" "$cand"
assert_lacks "no filenames leak in from the cwd"           "aaa.log"                      "$cand"

# --------------------------------------------------------------------------
section "history parsing: the awk extractor matches the bash one"

# extract_stream_awk is a transcription of extract_dest, and the only thing that
# makes rewriting the most load-bearing function in the tool safe is proving the
# two agree. Build a corpus of every shape that has ever mattered plus the
# combinatorial neighbourhood around it, and require byte-identical output.
#
# SUSHI_EXTRACT=bash selects the reference implementation.
CORPUS="$WORK/corpus"
{
  cat <<'EOF'
ssh deploy@web1.example.com
ssh -p 2022 deploy@staging.example.com
ssh other@late-flag.example.com -p 8022
ssh -i ~/.ssh/id_ed25519 keyed@keys.example.com
ssh -o StrictHostKeyChecking=no opt@opts.example.com
ssh -J jumper@bastion.example.com deep@behind.example.com
ssh -l flaguser flag-l.example.com
ssh "quoted@quotes.example.com"
ssh 'singlequoted@sq.example.com'
cd /tmp && ssh chained@chain.example.com
foo; ssh semi@semi.example.com
foo | ssh pipe@pipe.example.com
sudo ssh sudoer@sudo.example.com
command time nohup ssh stacked@stack.example.com
/usr/bin/ssh abs@abs.example.com
./ssh rel@rel.example.com
ssh ssh://u@url.example.com:2200/
ssh ssh://url2.example.com/
ssh trailing.example.com:
ssh u@v@double.example.com
ssh -p2222 attached@att.example.com
ssh -lbob attachedl.example.com
ssh -i~/k attachedi.example.com
ssh -Jj@b attachedj.example.com
ssh -p 999999 badport.example.com
ssh -p abc alsobad.example.com
ssh -i 'quoted path' quotedkey.example.com
ssh -J 'x;y' badjump.example.com
ssh -tt cmd.example.com 'sudo -i'
ssh -F /dev/null dashf.example.com
ssh -W -b -O -Q noargs.example.com
ssh -- dashdash.example.com
ssh -weird
ssh .dotted.example.com
ssh under_score.example.com
ssh 1.2.3.4
ssh UPPER.Example.COM
ssh -6 user@[2001:db8::1]
ssh user@2001:db8::1
ssh *.glob.example.com
ssh host?
ssh $VAR
ssh a(b)
ssh trailing-
ssh -
ssh h
ssh
sudo
sudo ssh
ssh -p
ssh-keygen -t ed25519
ssh-add -l
sshfs host:/mnt /mnt
scp file.txt user@scp.example.com:/tmp/
rsync -av ./d user@rsync.example.com:/srv/
echo "ssh is a great tool"
# ssh commented@out.example.com
: 1699999999:0;ssh ts@stamped.example.com
: 1699999999;ssh nodur@nodur.example.com
: abc:0;ssh badstamp@bad.example.com
- cmd: ssh fish@fish.example.com
  when: 1700000002
when: 1700000003
  when: notanumber
#1700000004
ssh bashstamped@bs.example.com
#not-a-stamp
# ssh hashcomment@out.example.com
--
:no-semicolon ssh nosemi.example.com
   ssh    padded@pad.example.com
EOF
  # the combinatorial neighbourhood: prefixes x flags x destination shapes
  for pre in '' 'sudo ' 'time ' 'nohup ' '/usr/bin/'; do
    for flag in '' '-v ' '-p 22 ' '-p2222 ' '-l bob ' '-i ~/k ' '-J j@b ' '-o X=y ' '-4 ' '-W ' '- '; do
      for dest in 'h.example.com' 'u@h.example.com' 'u@v@h.example.com' '"q@h.example.com"' \
                  'ssh://u@h.example.com:2200/' 'h.example.com:' '-weird' '.dot.com' '1.2.3.4' ''; do
        for post in '' ' ls -la' ' -p 2022' ' -l alice' ' -i ~/k2' ' -J q@r' " 'sudo -i'" ' -W'; do
          printf '%sssh %s%s%s\n' "$pre" "$flag" "$dest" "$post"
        done
      done
    done
  done
} > "$CORPUS"

n_corpus="$(wc -l < "$CORPUS" | tr -d ' ')"
"$SUSHI" __extract < "$CORPUS" > "$WORK/ex.awk.out" 2>"$WORK/ex.awk.err"
SUSHI_EXTRACT=bash "$SUSHI" __extract < "$CORPUS" > "$WORK/ex.bash.out" 2>"$WORK/ex.bash.err"
assert_eq "the awk extractor is byte-identical to the bash one over $n_corpus lines" \
          "$(cat "$WORK/ex.bash.out")" "$(cat "$WORK/ex.awk.out")"
assert_eq "and says nothing on stderr" "" "$(cat "$WORK/ex.awk.err")"
# a corpus that parsed nothing would make the comparison above vacuous
n_rec="$(wc -l < "$WORK/ex.awk.out" | tr -d ' ')"
if [ "$n_rec" -gt 200 ]; then ok "the corpus actually exercises the parser ($n_rec records)"
else no "the corpus actually exercises the parser (only $n_rec records)"; fi

# --------------------------------------------------------------------------
section "history parsing: bytes that are not valid UTF-8"

# onetrueawk — macOS's /usr/bin/awk — aborts the ENTIRE program on the first
# input byte sequence that is not valid encoding in the current locale:
#
#     awk: towc: multibyte conversion failure on: '...'
#
# It does it mid-stream, so hosts after the offending line vanish silently. A
# shell history reliably contains such bytes (a truncated paste is enough), and
# this cost a real user every host below the bad line. Every awk in sushi runs
# under LC_ALL=C now; this is the test that keeps it that way.
H="$(newhome badbytes)"
{
  printf ': 1:0;ssh first@one.example.com\n'
  printf ': 2:0;echo ssh \xe2\x80 truncated multibyte paste\n'
  printf ': 3:0;ssh second@two.example.com\n'
  printf ': 4:0;ssh third\xff\xfe@three.example.com\n'
  printf ': 5:0;ssh fourth@four.example.com\n'
} > "$H/.zsh_history"

for loc in C en_US.UTF-8; do
  out="$(HOME="$H" LANG="$loc" LC_ALL="$loc" "$SUSHI" __candidates 2>"$WORK/bb.err")"
  assert_has   "[$loc] a host before the bad bytes survives" "one.example.com"  "$out"
  assert_has   "[$loc] and one between two bad lines"        "two.example.com"  "$out"
  assert_has   "[$loc] and one after them"                  "four.example.com" "$out"
  assert_eq    "[$loc] with nothing on stderr" "" "$(cat "$WORK/bb.err")"
done

# the whole pipeline, not just the extractor
out="$(HOME="$H" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$SUSHI" scan -n 2>&1)"
assert_has   "scan still proposes hosts past the bad bytes" "four.example.com" "$out"
assert_lacks "and never mentions a conversion failure"      "towc"             "$out"

# a UTF-8 hostname is not a crash either — it is just not a valid host
out="$(HOME="$H" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$SUSHI" list 2>&1)"
assert_lacks "list is clean too" "towc" "$out"

# --------------------------------------------------------------------------
section "known_hosts"

H="$(newhome kh)"
cat > "$H/.ssh/known_hosts" <<'EOF'
|1|c2FsdA==|aGFzaA== ssh-ed25519 AAAAC3Nz
plain.example.com,198.51.100.7 ssh-rsa AAAAB3Nz
[bracketed.example.com]:2222 ssh-ed25519 AAAAC3Nz
EOF
out="$(run "$H" scan -n)"
assert_has   "unhashed known_hosts name is offered"  "HostName plain.example.com"      "$out"
assert_has   "comma-separated alias is offered"      "HostName 198.51.100.7"           "$out"
assert_has   "[host]:port form is unwrapped"         "HostName bracketed.example.com"  "$out"
assert_lacks "hashed entries are skipped"            "|1|"                             "$out"
assert_has   "no username is flagged, not invented"  "# User ?"                        "$out"

# --------------------------------------------------------------------------
section "scan: writing to ~/.ssh/config"

H="$(newhome write)"
cat > "$H/.ssh/config" <<'EOF'
Host *
    ServerAliveInterval 60

Host mine-by-hand
    HostName hand.example.com
    User luca
EOF
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh -p 2222 deploy@web1.example.com
: 2:0;ssh dba@db.example.com
EOF
out="$(import_all "$H")"
cfg="$(cat "$H/.ssh/config")"

assert_has "reports the file it wrote"        "Updated"                    "$out"
assert_has "imports a discovered host"        "Host web1"                  "$cfg"
assert_has "carries the username over"        "User deploy"                "$cfg"
assert_has "carries a non-default port over"  "Port 2222"                  "$cfg"
n="$(printf '%s\n' "$cfg" | grep -cE '^[[:space:]]*Port 22$' || true)"
assert_eq "does not write a redundant Port 22" "0" "$n"
assert_has "keeps hand-written stanzas"       "Host mine-by-hand"          "$cfg"
assert_has "keeps the Host * block"           "ServerAliveInterval 60"     "$cfg"

# the managed block must come first, or a leading `Host *` would win in ssh_config
first_marker="$(grep -n 'sushi managed hosts' "$H/.ssh/config" | head -1 | cut -d: -f1)"
first_host="$(grep -n '^Host ' "$H/.ssh/config" | head -1 | cut -d: -f1)"
if [ -n "$first_marker" ] && [ "$first_marker" -lt "$first_host" ]; then
  ok "managed block is above every pre-existing Host"
else
  no "managed block is above every pre-existing Host"
fi

perm="$(ls -l "$H/.ssh/config" | cut -c1-10)"
assert_eq "config stays mode 600" "-rw-------" "$perm"

n="$(count_backups "$H/.ssh")"
if [ "$n" -ge 1 ]; then ok "a backup was written"; else no "a backup was written"; fi

# --------------------------------------------------------------------------
section "scan: idempotency"

out="$(run "$H" scan -n)"
assert_has "a second scan finds nothing new" "Nothing new found" "$out"

hosts_before="$(run "$H" list)"
import_all "$H" >/dev/null
hosts_after="$(run "$H" list)"
assert_eq "re-importing does not duplicate anything" "$hosts_before" "$hosts_after"

printf ': 3:0;ssh later@added-later.example.com\n' >> "$H/.zsh_history"
import_all "$H" >/dev/null
out="$(run "$H" list)"
assert_has "a newly used host is picked up later"  "added-later.example.com" "$out"
assert_has "earlier imports survive the new one"   "web1"                    "$out"
assert_has "hand-written stanzas still survive"    "mine-by-hand"            "$out"

# --------------------------------------------------------------------------
section "scan: a pipe is not consent to write"

H="$(newhome pipeeof)"
printf ': 1:0;ssh piped@pipe.example.com\n' > "$H/.zsh_history"
out="$(true | HOME="$H" "$SUSHI" scan 2>&1)"
assert_has "EOF on a pipe cancels rather than writes" "Cancelled" "$out"
assert_lacks "and leaves ~/.ssh/config unwritten" "Host pipe" \
             "$(cat "$H/.ssh/config" 2>/dev/null)"
out="$(printf 'w\n' | HOME="$H" "$SUSHI" scan 2>&1)"
assert_has "an explicit w on a pipe still writes" "Host pipe" "$(cat "$H/.ssh/config")"

# --------------------------------------------------------------------------
section "scan: does not re-add what config already covers"

H="$(newhome covered)"
printf 'Host prod\n    HostName prod.example.com\n    User deploy\n' > "$H/.ssh/config"
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh deploy@prod.example.com
: 2:0;ssh prod
EOF
out="$(run "$H" scan -n)"
assert_has "skips a user@host already in config" "Nothing new found" "$out"

H="$(newhome covered2)"
printf 'Host prod\n    HostName prod.example.com\n    User deploy\n' > "$H/.ssh/config"
printf ': 1:0;ssh someoneelse@prod.example.com\n' > "$H/.zsh_history"
out="$(run "$H" scan -n)"
assert_has "but a different user on the same host is new" "User someoneelse" "$out"

# --------------------------------------------------------------------------
section "alias generation"

H="$(newhome alias)"
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh a@10.0.0.1
: 2:0;ssh one@dup.example.com
: 3:0;ssh two@dup.example.net
: 4:0;ssh three@dup.example.org
EOF
out="$(run "$H" scan -n)"
assert_has "IP addresses get a readable alias" "Host srv-10-0-0-1" "$out"
assert_has "first of a name collision"         "Host dup"          "$out"
n="$(printf '%s\n' "$out" | grep -c '^Host dup')"
assert_eq "colliding names all get distinct aliases" "3" "$n"
n_uniq="$(printf '%s\n' "$out" | grep '^Host ' | sort -u | wc -l | tr -d ' ')"
n_all="$(printf '%s\n' "$out" | grep -c '^Host ')"
assert_eq "no duplicate aliases at all" "$n_all" "$n_uniq"

H="$(newhome alias2)"
printf 'Host web1\n    HostName old.example.com\n' > "$H/.ssh/config"
printf ': 1:0;ssh new@web1.example.com\n' > "$H/.zsh_history"
out="$(run "$H" scan -n)"
assert_lacks "never reuses an alias that already exists" "Host web1
" "$out"

# --------------------------------------------------------------------------
section "scan: fresh machine with no ~/.ssh"

H="$WORK/bare"; rm -rf "$H"; mkdir -p "$H"
printf ': 1:0;ssh admin@fresh.example.com\n' > "$H/.zsh_history"
import_all "$H" >/dev/null
if [ -f "$H/.ssh/config" ]; then ok "creates ~/.ssh/config when absent"; else no "creates ~/.ssh/config when absent"; fi
perm="$(ls -ld "$H/.ssh" | cut -c1-10)"
assert_eq "creates ~/.ssh as mode 700" "drwx------" "$perm"
assert_has "and imports into it" "fresh.example.com" "$(run "$H" list)"

# --------------------------------------------------------------------------
section "scan: refuses to write a config ssh cannot parse"

if command -v ssh >/dev/null 2>&1; then
  H="$(newhome badwrite)"
  printf 'Host keeper\n    HostName keep.example.com\n' > "$H/.ssh/config"
  printf ': 1:0;ssh someone@new.example.com\n' > "$H/.zsh_history"
  before="$(cat "$H/.ssh/config")"

  ed="$WORK/bad-editor"
  printf '#!/bin/sh\nprintf "Host oops\\n    NotARealSshOption yes\\n" >> "$1"\n' > "$ed"
  chmod +x "$ed"

  out="$(printf 'e\n' | HOME="$H" SUSHI_ALL=1 EDITOR="$ed" "$SUSHI" scan 2>&1)"
  after="$(cat "$H/.ssh/config")"

  assert_has "reports the validation failure" "NOT changed" "$out"
  assert_eq  "leaves the config byte-identical" "$before" "$after"
  assert_eq "cleans up the unused backup" "0" "$(count_backups "$H/.ssh")"
else
  skip "config validation" "ssh not installed"
fi

# --------------------------------------------------------------------------
section "IdentityFile and ProxyJump"

H="$(newhome ij)"
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh -i ~/.ssh/deploy_ed25519 deploy@keyed.example.com
: 2:0;ssh -J bastion@jump.example.com deep@behind.example.com
: 3:0;ssh -i ~/.ssh/id_rsa -J admin@edge.example.com -p 2222 root@both.example.com
: 4:0;ssh plain@plain.example.com
: 5:0;ssh -i$HOME/.ssh/unexpanded glued@glued.example.com
: 6:0;ssh -i '/tmp/has space/key' spaced@spaced.example.com
EOF

cand="$(run "$H" __candidates)"
assert_has "records the identity file"     "|deploy|keyed.example.com||~/.ssh/deploy_ed25519|" "$cand"
assert_has "records the jump host"         "|deep|behind.example.com|||bastion@jump.example.com" "$cand"
assert_has "both at once, alongside -p"    "|root|both.example.com|2222|~/.ssh/id_rsa|admin@edge.example.com" "$cand"
assert_has "and a plain host stays plain"  "|plain|plain.example.com|||" "$cand"

# these end up verbatim in ~/.ssh/config, so anything not plainly a path is dropped
assert_lacks "an unexpanded \$HOME is not written out" "unexpanded" "$cand"
assert_lacks "nor a path containing spaces"           "has space"  "$cand"

out="$(run "$H" scan -n)"
assert_has "the stanza carries IdentityFile" "IdentityFile ~/.ssh/deploy_ed25519" "$out"
assert_has "the stanza carries ProxyJump"    "ProxyJump bastion@jump.example.com" "$out"
n="$(printf '%s\n' "$out" | grep -c 'IdentityFile')"
assert_eq "only the hosts that had one" "2" "$n"

# the scan row flags them without breaking the contiguous target
menu="$(run "$H" __scanmenu)"
row="$(printf '%s\n' "$menu" | grep both | cut -f1 | sed 's/\x1b\[[0-9;]*m//g')"
assert_has "the row still matches on user@host:port" "root@both.example.com:2222" "$row"
assert_has "and flags the key"                        "key"  "$row"
assert_has "and the bastion"                          "via edge.example.com" "$row"

# and ssh itself has to accept the result
import_all "$H" > /dev/null
if command -v ssh >/dev/null 2>&1; then
  resolved="$(HOME="$H" ssh -F "$H/.ssh/config" -G both 2>/dev/null)"
  assert_has "ssh -G resolves the proxyjump" "proxyjump admin@edge.example.com" "$resolved"
  assert_has "ssh -G resolves the identityfile" "identityfile ~/.ssh/id_rsa" "$resolved"
else
  skip "ssh -G accepts the generated stanza" "ssh not installed"
fi


# --------------------------------------------------------------------------
section "picker ordering"

H="$(newhome sortpick)"
cat > "$H/.ssh/config" <<'EOF'
Host alpha
    HostName alpha.example.com
    User luca
Host zulu
    HostName zulu.example.com
    User luca
Host mike
    HostName mike.example.com
    User deploy
Host cold
    HostName cold.example.com
    User luca
EOF
{
  i=0; while [ "$i" -lt 20 ]; do printf ': %s:0;ssh luca@zulu.example.com\n' "$i"; i=$((i + 1)); done
  i=0; while [ "$i" -lt 6 ];  do printf ': 1%s:0;ssh deploy@mike.example.com\n' "$i"; i=$((i + 1)); done
  printf ': 90:0;ssh alpha\n'
} > "$H/.zsh_history"

export XDG_CACHE_HOME="$WORK/cache"

# the alias column of `__lines`, in order, colours stripped
aliases() { cut -f1 | sed 's/\x1b\[[0-9;]*m//g' | awk '{ print $1 }'; }

# default: most recently used first. alpha's `ssh alpha` is dated 90, zulu's
# newest is 19, mike's 15 — so recency and frequency disagree here on purpose.
order="$(run "$H" __lines | aliases)"
assert_eq "last-used host first"   "alpha" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "then the next"          "zulu"  "$(printf '%s\n' "$order" | sed -n 2p)"
assert_eq "a bare \`ssh alias\` counts for that alias" "alpha" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "never-used hosts trail" "cold"  "$(printf '%s\n' "$order" | sed -n 4p)"

# hostname+user AND the alias both contribute — a newer `ssh alias` must not
# lose to an older `ssh user@hostname` just because the pair already had a hit
Hmix="$(newhome sortmix)"
cat > "$Hmix/.ssh/config" <<'EOF'
Host staging
    HostName real.example.com
    User deploy
Host other
    HostName other.example.com
    User deploy
EOF
printf ': 100:0;ssh deploy@real.example.com\n: 900:0;ssh staging\n: 200:0;ssh deploy@other.example.com\n' \
  > "$Hmix/.zsh_history"
order="$(XDG_CACHE_HOME="$WORK/mix-cache" HOME="$Hmix" SUSHI_THEME=none "$SUSHI" __lines 2>&1 | aliases)"
assert_eq "a newer ssh-by-alias beats an older user@host" "staging" \
          "$(printf '%s\n' "$order" | sed -n 1p)"

order="$(run "$H" __lines count | aliases)"
assert_eq "sort=count is most-used first" "zulu" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "...then the next"              "mike" "$(printf '%s\n' "$order" | sed -n 2p)"
assert_eq "...and unused still trails"    "cold" "$(printf '%s\n' "$order" | sed -n 4p)"

# SUSHI_SORT picks the mode you start in, and `usage` is what count used to be
order="$(HOME="$H" SUSHI_SORT=usage "$SUSHI" __lines | aliases)"
assert_eq "SUSHI_SORT=usage still means most-used" "zulu" "$(printf '%s\n' "$order" | sed -n 1p)"
order="$(HOME="$H" SUSHI_SORT=alpha "$SUSHI" __lines | aliases)"
assert_eq "SUSHI_SORT=alpha is plain A-Z" "alpha" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "...second"                     "cold"  "$(printf '%s\n' "$order" | sed -n 2p)"
order="$(HOME="$H" SUSHI_SORT=nonsense "$SUSHI" __lines | aliases)"
assert_eq "an unknown SUSHI_SORT falls back to last-used" "alpha" \
          "$(printf '%s\n' "$order" | sed -n 1p)"

# sort=added reads the `# added` dates out of the stanzas
Hadd="$(newhome sortadded)"
cat > "$Hadd/.ssh/config" <<'EOF'
Host old
    HostName old.example.com
    # added 2026-01-02 09:00
Host newest
    HostName newest.example.com
    # added 2026-08-14 09:00
Host middle
    HostName middle.example.com
    # added 2026-05-05 09:00
Host undated
    HostName undated.example.com
EOF
order="$(run "$Hadd" __lines added | aliases)"
assert_eq "sort=added is newest first"        "newest" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "...then the one before it"         "middle" "$(printf '%s\n' "$order" | sed -n 2p)"
assert_eq "...then the oldest"                "old"    "$(printf '%s\n' "$order" | sed -n 3p)"
assert_eq "...and a host with no date trails" "undated" "$(printf '%s\n' "$order" | sed -n 4p)"

# the picker feed: two header lines naming the mode, then the rows
feed="$(run "$H" __pickerfeed)"
assert_has "the feed header names the sort mode" "ctrl-s sort: last used" \
           "$(printf '%s\n' "$feed" | sed -n 1p)"
assert_has "the feed header still names the columns" "ALIAS" \
           "$(printf '%s\n' "$feed" | sed -n 2p)"
assert_eq "the feed is the header plus every row" \
          "$(( $(run "$H" __lines | wc -l) + 2 ))" \
          "$(printf '%s\n' "$feed" | wc -l | tr -d ' ')"

# ctrl-s: each press advances the mode kept in the state file
SORTSTATE="$WORK/sortstate"
: > "$SORTSTATE"
cycle=""
for _ in 1 2 3 4; do
  cycle="$cycle$(HOME="$H" SUSHI_SORT_STATE="$SORTSTATE" SUSHI_THEME=none \
                 "$SUSHI" __pickerfeed --next | sed -n 1p | sed 's/.*sort: //; s/ · .*//')
"
done
assert_eq "ctrl-s cycles used -> added -> count -> used" \
          "last added
most used
last used
last added" "$(printf '%s' "$cycle" | sed '/^$/d')"
printf 'alpha\n' > "$SORTSTATE"
assert_has "ctrl-s steps out of A-Z into the cycle" "sort: last used" \
           "$(HOME="$H" SUSHI_SORT_STATE="$SORTSTATE" SUSHI_THEME=none "$SUSHI" __pickerfeed --next | sed -n 1p)"

# Each ordering is built once per picker and re-read after that: a press that
# goes back to a mode you have seen must not pay for the awk and the sort again.
rm -f "$SORTSTATE" "$SORTSTATE".feed.*
printf 'used\n' > "$SORTSTATE"
feed="$(HOME="$H" SUSHI_SORT_STATE="$SORTSTATE" SUSHI_THEME=none "$SUSHI" __pickerfeed)"
if [ -s "$SORTSTATE.feed.used" ]; then
  ok "the feed for a mode is cached"
else
  no "the feed for a mode is cached"
fi
assert_eq "the cache holds exactly what was shown" "$feed" "$(cat "$SORTSTATE.feed.used")"
# a sentinel proves the second call reads the cache instead of rebuilding
printf 'SENTINEL\n' > "$SORTSTATE.feed.used"
assert_eq "a cached mode is served from the cache" "SENTINEL" \
          "$(HOME="$H" SUSHI_SORT_STATE="$SORTSTATE" SUSHI_THEME=none "$SUSHI" __pickerfeed)"
HOME="$H" SUSHI_SORT_STATE="$WORK/perm" SUSHI_THEME=none "$SUSHI" __pickerfeed >/dev/null
assert_eq "the cache is 0600 — it lists every host you have" "-rw-------" \
          "$(ls -l "$WORK/perm.feed.used" | awk '{ print substr($1, 1, 10) }')"
# cycling round the whole cycle leaves one cache per ordering, and no more
rm -f "$SORTSTATE" "$SORTSTATE".feed.*
printf 'used\n' > "$SORTSTATE"
for _ in 1 2 3; do
  HOME="$H" SUSHI_SORT_STATE="$SORTSTATE" SUSHI_THEME=none "$SUSHI" __pickerfeed --next >/dev/null
done
assert_eq "one cache per ordering visited" "added count used" \
          "$(ls "$SORTSTATE".feed.* | sed 's/.*\.feed\.//' | sort | tr '\n' ' ' | sed 's/ $//')"

# ctrl-s repaints the list in one go where fzf can do that. Plain `reload` is
# asynchronous: fzf blanks the list — header lines included, since they arrive
# on the same pipe — until the child answers, and that flash is visible.
fakefzf() {   # $1 = what `fzf --version` should say
  mkdir -p "$WORK/fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$WORK/fakebin/fzf"
  chmod +x "$WORK/fakebin/fzf"
  PATH="$WORK/fakebin:$PATH" "$SUSHI" __fzfreload
}
assert_eq "fzf 0.36 gets reload-sync"      "reload-sync" "$(fakefzf '0.36.0 (brew)')"
assert_eq "a current fzf gets reload-sync" "reload-sync" "$(fakefzf '0.74.3 (Homebrew)')"
assert_eq "a distro build parses too"      "reload-sync" "$(fakefzf '0.38.0-1 (debian)')"
assert_eq "fzf 0.35 keeps the async reload" "reload" "$(fakefzf '0.35.1')"
assert_eq "fzf 0.24 keeps the async reload" "reload" "$(fakefzf '0.24.4-1')"
assert_eq "an unreadable version keeps the async reload" "reload" "$(fakefzf 'unknown')"
rm -rf "$WORK/fakebin"

# The picker must ask fzf for the whole screen, not a slice of it.
#
# `--height=80%` draws inline, and fzf then remembers where that region begins:
# shrink the terminal while the picker is up and the top of the region scrolls
# into scrollback, so the post-resize repaint clears the wrong rows and strands
# the old frame above the new one — one more stacked, half-erased picker per
# resize, still there after the picker exits. `--height=100%` puts fzf on the
# alternate screen, where a resize is its own buffer's problem and quitting
# restores the terminal untouched.
mkdir -p "$WORK/fakebin"
ARGV="$WORK/fzf.argv"
cat > "$WORK/fakebin/fzf" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { printf '0.74.3 (test)\n'; exit 0; }
for a in "$@"; do printf '%s\n' "$a"; done >> "$FZF_ARGV"
exit 1
STUB
chmod +x "$WORK/fakebin/fzf"
: > "$ARGV"
HOME="$H" FZF_ARGV="$ARGV" PATH="$WORK/fakebin:$PATH" "$SUSHI" choose >/dev/null 2>&1
assert_has "the picker asks for the full screen" "--height=100%" "$(cat "$ARGV")"
assert_eq "and asks for exactly one height" "--height=100%" \
          "$(grep '^--height=' "$ARGV" | sort -u | tr '\n' ' ' | sed 's/ $//')"

# ...but the default is the weakest of the three groups, so anyone who prefers
# the inline picker can still have it.
: > "$ARGV"
HOME="$H" FZF_ARGV="$ARGV" SUSHI_FZF_OPTS='--height=80%' PATH="$WORK/fakebin:$PATH" \
  "$SUSHI" choose >/dev/null 2>&1
assert_eq "SUSHI_FZF_OPTS still wins on height" "--height=80%" \
          "$(grep '^--height=' "$ARGV" | tail -1)"
rm -rf "$WORK/fakebin"

# The other three pickers — scan, ignore, un-ignore — need a terminal to reach,
# so they are checked at the source: no call site may name an inline height.
assert_eq "no picker hardcodes an inline height" "" \
          "$(grep -h -v '^[[:space:]]*#' "$SUSHI" "$ROOT"/lib/*.sh | grep -o -- '--height=[0-9]*%' \
             | grep -v '^--height=100%$' | sort -u | tr '\n' ' ' | sed 's/ $//')"

# no history: every host is unused, so A-Z
rm -f "$H/.zsh_history"
rm -rf "$XDG_CACHE_HOME"
order="$(run "$H" __lines | aliases)"
assert_eq "with no history it falls back to A-Z" "alpha" "$(printf '%s\n' "$order" | sed -n 1p)"

# the payload column stays clean under both orderings
assert_eq "payload is still the bare alias" "alpha" "$(run "$H" __lines | sed -n 1p | cut -f2)"

# the cache must not change what you see, only how fast
H="$(newhome sortcache)"
printf 'Host one\n    HostName one.example.com\n' > "$H/.ssh/config"
printf ': 1:0;ssh one\n' > "$H/.zsh_history"
rm -rf "$XDG_CACHE_HOME"
first="$(run "$H" __lines)"
second="$(run "$H" __lines)"
assert_eq "a warm cache gives identical output" "$first" "$second"
if [ -f "$XDG_CACHE_HOME/sushi/history" ]; then
  ok "the history cache is written"
else
  no "the history cache is written"
fi
# appending to history must invalidate it
printf ': 2:0;ssh two@two.example.com\n' >> "$H/.zsh_history"
run "$H" scan -n > /dev/null
assert_has "appending to history busts the cache" "two.example.com" \
           "$(run "$H" __lines >/dev/null; cat "$XDG_CACHE_HOME/sushi/history")"
unset XDG_CACHE_HOME

# --------------------------------------------------------------------------
section "ignore list"

H="$(newhome ign)"
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh root@203.0.113.9
: 2:0;ssh deploy@web1.example.com
: 3:0;ssh root@198.51.100.5
: 4:0;ssh admin@db.staging.acme.tld
: 5:0;ssh admin@app.staging.acme.tld
: 6:0;ssh luca@keep.example.com
EOF

out="$(run "$H" scan -n)"
assert_has "before ignoring, everything is offered" "203.0.113.9" "$out"

run "$H" ignore 'root@*' '*.staging.acme.tld' >/dev/null
out="$(run "$H" scan -n)"
assert_lacks "a user glob hides matching candidates"  "203.0.113.9"    "$out"
assert_lacks "the second match of that glob is gone"  "198.51.100.5"   "$out"
assert_lacks "a host glob hides a whole domain"       "staging.acme"   "$out"
assert_has   "unrelated candidates are untouched"     "keep.example.com" "$out"
assert_has   "it says how many it hid"                "hidden by"      "$out"

perm="$(ls -l "$H/.ssh/sushi-ignore" | cut -c1-10)"
assert_eq "the ignore file is mode 600" "-rw-------" "$perm"

out="$(run "$H" ignore --list)"
assert_has "--list shows the entries" "root@*" "$out"

out="$(run "$H" ignore 'root@*')"
assert_has "adding an existing pattern is a no-op" "already ignored" "$out"

run "$H" ignore --remove 'root@*' >/dev/null
out="$(run "$H" scan -n)"
assert_has   "--remove brings candidates back"   "203.0.113.9"  "$out"
assert_lacks "and leaves the other entry alone"  "staging.acme" "$out"

# comments and blank lines must not match anything
H="$(newhome ign2)"
printf ': 1:0;ssh a@only.example.com\n' > "$H/.zsh_history"
printf '# a comment\n\n   \n# root@*\n' > "$H/.ssh/sushi-ignore"
out="$(run "$H" scan -n)"
assert_has "comments and blank lines are not patterns" "only.example.com" "$out"

printf 'a@only.example.com   # trailing comment\n' >> "$H/.ssh/sushi-ignore"
out="$(run "$H" scan -n)"
assert_lacks "an entry with a trailing comment still matches" "only.example.com" "$out"

# --------------------------------------------------------------------------
section "scan picker: dismissing rows"

H="$(newhome scanmenu)"
cat > "$H/.zsh_history" <<'EOF'
: 1:0;ssh root@203.0.113.9
: 2:0;ssh root@203.0.113.9
: 3:0;ssh deploy@web1.example.com
: 4:0;ssh junk@decommissioned.example.com
EOF
printf 'kh.example.com ssh-ed25519 AAAAC3Nz\n' > "$H/.ssh/known_hosts"

menu="$(run "$H" __scanmenu)"
n="$(printf '%s\n' "$menu" | awk -F'\t' 'NF != 3' | wc -l | tr -d ' ')"
assert_eq "every menu line has three columns" "0" "$n"

# column 2 is what import consumes, column 3 is what ctrl-x hands to `ignore`
row="$(printf '%s\n' "$menu" | grep decommissioned)"
assert_has "column 1 is the display text" "junk@decommissioned.example.com" "$(printf '%s' "$row" | cut -f1)"
assert_has "column 2 is the raw record"   "junk|decommissioned.example.com" "$(printf '%s' "$row" | cut -f2)"
assert_eq  "column 3 is the ignore pattern" "junk@decommissioned.example.com" "$(printf '%s' "$row" | cut -f3)"

# a known_hosts row has no username, so its pattern is the bare host
row="$(printf '%s\n' "$menu" | grep kh.example.com)"
assert_eq "a username-less row yields a bare-host pattern" "kh.example.com" "$(printf '%s' "$row" | cut -f3)"

# what ctrl-x actually runs: `sushi ignore <column 3>`, then reload
pat="$(printf '%s\n' "$menu" | grep decommissioned | cut -f3)"
run "$H" ignore "$pat" >/dev/null
menu2="$(run "$H" __scanmenu)"
assert_lacks "the dismissed row is gone after reload" "decommissioned" "$menu2"
assert_has   "the other rows survive"                 "web1.example.com" "$menu2"
assert_has   "and it stays gone in later scans"       "hidden by"        "$(run "$H" scan -n)"

# multi-select: ctrl-x passes several patterns at once ({+3})
H="$(newhome scanmenu2)"
printf ': 1:0;ssh a@one.example.com\n: 2:0;ssh b@two.example.com\n: 3:0;ssh c@three.example.com\n' \
  > "$H/.zsh_history"
pats="$(run "$H" __scanmenu | cut -f3 | grep -E 'one|two')"
# shellcheck disable=SC2046  # deliberate splitting: several patterns, as fzf's {+3} passes them
run "$H" ignore $(printf '%s ' $pats) >/dev/null
menu="$(run "$H" __scanmenu)"
assert_lacks "multi-select dismisses the first"  "one.example.com"   "$menu"
assert_lacks "multi-select dismisses the second" "two.example.com"   "$menu"
assert_has   "and leaves the rest"               "three.example.com" "$menu"

# dismissing must not import anything
assert_has "nothing was written to the config" "No hosts in" "$(run "$H" list)"

# ---- the cache/pending layer that keeps ctrl-x responsive -------------------
# ctrl-x must not re-scan: it appends to a pending file and the reload re-reads a
# cache. Re-scanning per keypress cost ~900ms on a 3000-line history.
H="$(newhome cache)"
printf ': 1:0;ssh a@one.example.com\n: 2:0;ssh b@two.example.com\n: 3:0;ssh c@three.example.com\n' \
  > "$H/.zsh_history"

CACHE="$WORK/scan.cache"
PEND="$WORK/scan.pend"
run "$H" __candidates > /dev/null            # sanity: history parses
"$SUSHI" __scanmenu > /dev/null 2>&1 || true  # no cache set: must not blow up

# with no cache configured, the reload path is a no-op rather than an error
out="$(HOME="$H" "$SUSHI" __menucache 2>&1)"
assert_eq "reload without a cache is silent" "" "$out"

# build a cache the way cmd_scan does, then drive the reload path directly
HOME="$H" SUSHI_SCAN_CACHE="$CACHE" "$SUSHI" __scanmenu | cut -f2 > "$CACHE"
: > "$PEND"
menu="$(HOME="$H" SUSHI_SCAN_CACHE="$CACHE" SUSHI_SCAN_PENDING="$PEND" "$SUSHI" __menucache)"
n="$(printf '%s\n' "$menu" | wc -l | tr -d ' ')"
assert_eq "the cached reload lists every candidate" "3" "$n"

pat="$(printf '%s\n' "$menu" | grep two | cut -f3)"
HOME="$H" SUSHI_SCAN_PENDING="$PEND" "$SUSHI" __pend "$pat"
assert_has "__pend records the pattern" "$pat" "$(cat "$PEND")"

menu="$(HOME="$H" SUSHI_SCAN_CACHE="$CACHE" SUSHI_SCAN_PENDING="$PEND" "$SUSHI" __menucache)"
assert_lacks "the reload drops a pending row"   "two.example.com"   "$menu"
assert_has   "and keeps the others"             "one.example.com"   "$menu"
n="$(printf '%s\n' "$menu" | wc -l | tr -d ' ')"
assert_eq "exactly one row went away" "2" "$n"

# crucially, pending is NOT the ignore file: nothing is written until the flush
assert_lacks "pending dismissals are not yet persisted" "two.example.com" \
             "$(run "$H" ignore --list)"
assert_has   "so a fresh scan still offers them"        "two.example.com" \
             "$(run "$H" scan -n)"

# multi-select passes several patterns in one go, as fzf's {+3} does
HOME="$H" SUSHI_SCAN_PENDING="$PEND" "$SUSHI" __pend "a@one.example.com" "c@three.example.com"
menu="$(HOME="$H" SUSHI_SCAN_CACHE="$CACHE" SUSHI_SCAN_PENDING="$PEND" "$SUSHI" __menucache)"
assert_eq "all pending rows are dropped" "" "$menu"

# a scan run must not leave its temp files behind
before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'sushi-scan.*' -o -maxdepth 1 -name 'sushi-pend.*' 2>/dev/null | wc -l | tr -d ' ')"
run "$H" scan -n > /dev/null
after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'sushi-scan.*' -o -maxdepth 1 -name 'sushi-pend.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "scan cleans up its temp files" "$before" "$after"

# the EXIT trap runs after cmd_scan has returned, when its locals are gone —
# under `set -u` a trap referring to them fails and taints every scan run
err="$(HOME="$H" "$SUSHI" scan -n 2>&1 >/dev/null)"
assert_eq "a scan run writes nothing to stderr" "" "$err"

# --------------------------------------------------------------------------
section "deleting managed stanzas"

H="$(newhome del)"
printf 'Host handwritten\n    HostName hand.example.com\n    User luca\n' > "$H/.ssh/config"
printf ': 1:0;ssh a@one.example.com\n: 2:0;ssh b@two.example.com\n' > "$H/.zsh_history"
import_all "$H" >/dev/null

out="$(run "$H" list)"
assert_has "imported both" "one" "$out"

run "$H" __rmalias two >/dev/null
out="$(run "$H" list)"
assert_lacks "deletes the named stanza"          "two"         "$out"
assert_has   "leaves the other import alone"     "one"         "$out"
assert_has   "leaves hand-written stanzas alone" "handwritten" "$out"

# refuses to touch anything outside the managed block
run "$H" __rmalias handwritten >/dev/null
assert_has "will not delete a stanza outside the managed block" "handwritten" "$(run "$H" list)"

# a Host line with several patterns loses only the named one
H="$(newhome del2)"
cat > "$H/.ssh/config" <<'EOF'
# >>> sushi managed hosts >>>
Host alpha beta
    HostName ab.example.com
    User x

Host gamma
    HostName g.example.com
# <<< sushi managed hosts <<<
EOF
run "$H" __rmalias alpha >/dev/null
out="$(run "$H" list)"
assert_lacks "drops the named pattern from a multi-alias Host" "alpha" "$out"
assert_has   "the sibling alias survives"                      "beta"  "$out"
assert_has   "and so does its target"                          "x@ab.example.com" "$out"
run "$H" __rmalias beta >/dev/null
out="$(run "$H" list)"
assert_lacks "removing the last pattern drops the stanza" "ab.example.com" "$out"
assert_has   "other stanzas are unaffected"              "gamma"          "$out"

# deletion goes through the same safety path as import
n="$(count_backups "$H/.ssh")"
if [ "$n" -ge 1 ]; then ok "deletion writes a backup too"; else no "deletion writes a backup too"; fi

# --------------------------------------------------------------------------
section "portability: onetrueawk (what macOS ships)"

# macOS's /usr/bin/awk is onetrueawk, not gawk. It refuses a -v assignment whose
# value contains a newline ("newline in string") — the program then never runs at
# all. That silently emptied the managed block on delete, and made scan find
# nothing whenever ~/.ssh/config held more than one host. Both were invisible on
# Linux CI, so run the awk-sensitive paths against onetrueawk where it exists.
#
# Debian/Ubuntu: apt-get install original-awk
if command -v original-awk >/dev/null 2>&1; then
  SHIM="$WORK/awkshim"
  mkdir -p "$SHIM"
  ln -sf "$(command -v original-awk)" "$SHIM/awk"

  oldawk() { PATH="$SHIM:$PATH" HOME="$1" "$SUSHI" "${@:2}" 2>&1; }

  H="$(newhome otawk)"
  cat > "$H/.ssh/config" <<'EOF'
# >>> sushi managed hosts >>>
Host alpha beta
    HostName ab.example.com
    User x

Host gamma
    HostName g.example.com
    User y
# <<< sushi managed hosts <<<

Host handwritten
    HostName hand.example.com
EOF
  printf ': 1:0;ssh new@fresh.example.com\n: 2:0;ssh y@g.example.com\n' > "$H/.zsh_history"

  out="$(oldawk "$H" list)"
  assert_has "reads a multi-host config"    "alpha" "$out"
  assert_has "including the last stanza"    "gamma" "$out"
  assert_has "and hand-written ones"        "handwritten" "$out"

  # a multi-line config used to go through `awk -v cfg=...` and kill the program
  out="$(oldawk "$H" scan -n)"
  assert_has   "scan still finds new hosts"          "fresh.example.com" "$out"
  assert_lacks "and still skips already-configured"  "g.example.com"     "$out"

  # deletion used to empty the whole managed block
  oldawk "$H" __rmalias alpha > /dev/null
  out="$(oldawk "$H" list)"
  assert_lacks "delete drops only the named pattern" "alpha" "$out"
  assert_has   "the sibling alias survives"          "beta"  "$out"
  assert_has   "other managed stanzas survive"       "gamma" "$out"
  assert_has   "hand-written stanzas survive"        "handwritten" "$out"

  # the ignore list and the picker feed
  oldawk "$H" ignore 'root@*' > /dev/null
  assert_has "the ignore list round-trips" "root@*" "$(oldawk "$H" ignore --list)"
  n="$(oldawk "$H" __lines | wc -l | tr -d ' ')"
  assert_eq "the picker lists the three survivors" "3" "$n"
  assert_has "the preview renders" "ab.example.com" "$(oldawk "$H" __preview beta)"

  # Everything below moved into awk after the section above was written, so it is
  # newly exposed to onetrueawk's quirks: no {n,m} intervals, byte-oriented
  # regexes, and an abort on invalid multibyte input.
  out="$(oldawk "$H" add -n deploy@otawk.example.com -p 2222 -i /tmp/k -J bastion)"
  assert_has "add builds a stanza"     "Host otawk"          "$out"
  assert_has "with the port"           "Port 2222"           "$out"
  assert_has "the key"                 "IdentityFile /tmp/k" "$out"
  assert_has "and the jump host"       "ProxyJump bastion"   "$out"
  out="$(oldawk "$H" add -n 10.0.0.7)"
  assert_has "and an IP still gets the srv- alias" "Host srv-10-0-0-7" "$out"

  # the port check is ^[0-9]{1,5}$ written without an interval expression
  out="$(printf 'ssh -p 999999 sixdigits.example.com
ssh -p 65000 fivedigits.example.com
'          | PATH="$SHIM:$PATH" HOME="$H" "$SUSHI" __extract)"
  assert_has "a six-digit port is dropped"  "|sixdigits.example.com||"  "$out"
  assert_has "a five-digit one is kept"     "|fivedigits.example.com|65000|" "$out"

  # the two extractors must still agree under onetrueawk
  ex_awk="$(PATH="$SHIM:$PATH" HOME="$H" "$SUSHI" __extract < "$CORPUS")"
  ex_bash="$(PATH="$SHIM:$PATH" HOME="$H" SUSHI_EXTRACT=bash "$SUSHI" __extract < "$CORPUS")"
  assert_eq "the extractors agree under onetrueawk too" "$ex_bash" "$ex_awk"

  # and invalid multibyte input must not abort the run
  BH="$(newhome otawkbytes)"
  { printf ': 1:0;ssh first@one.example.com
'
    printf ': 2:0;echo ssh \xff\xfe bad bytes
'
    printf ': 3:0;ssh second@two.example.com
'; } > "$BH/.zsh_history"
  out="$(PATH="$SHIM:$PATH" HOME="$BH" LC_ALL=en_US.UTF-8 "$SUSHI" __candidates 2>&1)"
  assert_has   "onetrueawk survives invalid multibyte input" "two.example.com" "$out"
  assert_lacks "with no conversion failure"                  "towc"            "$out"
else
  skip "onetrueawk portability" "original-awk not installed"
fi

# --------------------------------------------------------------------------
section "picker plumbing"

H="$(newhome pick)"
cat > "$H/.ssh/config" <<'EOF'
Host alpha
    HostName a.example.com
    User one
Host beta
    HostName b.example.com
    User two
    Port 2020
EOF
lines="$(run "$H" __lines)"
n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
assert_eq "one fzf line per host" "2" "$n"

# column 2 (after the tab) is the payload fzf hands back
payload="$(printf '%s\n' "$lines" | sed -n 2p | cut -f2)"
assert_eq "payload column is the bare alias" "beta" "$payload"
display="$(printf '%s\n' "$lines" | sed -n 2p | cut -f1)"
assert_has "display column shows user@host:port" "two@b.example.com:2020" "$display"

prev="$(run "$H" __preview beta)"
assert_has "preview shows the target"     "two@b.example.com:2020" "$prev"
assert_has "preview shows the stanza"     "Host beta"              "$prev"
if command -v ssh >/dev/null 2>&1; then
  assert_has "preview shows resolved values" "hostname" "$prev"
  assert_lacks "preview hides ssh's default identityfiles" "id_dsa" "$prev"
else
  skip "preview resolved values" "ssh not installed"
fi

out="$(run "$H" __preview does-not-exist)"
if [ -n "$out" ]; then ok "preview of an unknown alias does not crash"; else ok "preview of an unknown alias is empty"; fi

# --------------------------------------------------------------------------
section "ignore picker rows"

H="$(newhome ignrows)"
cat > "$H/.ssh/config" <<'EOF'
# >>> sushi managed hosts >>>
Host alpha
    HostName a.example.com
    User one
Host beta gamma
    HostName bg.example.com
    User two
# <<< sushi managed hosts <<<

Host handwritten
    HostName hand.example.com
    User three
EOF
printf ': 1:0;ssh new@fresh.example.com\n' > "$H/.zsh_history"

rows="$(run "$H" __ignoremenu)"
assert_has "offers un-imported candidates"      "scan"     "$rows"
assert_has "with the candidate as the payload"  "new@fresh.example.com" "$rows"
assert_has "offers imported hosts"              "imported" "$rows"
first="$(printf '%s\n' "$rows" | sed 's/\x1b\[[0-9;]*m//g' | head -1 | awk '{ print $1 }')"
assert_eq "scan candidates come before imported" "scan" "$first"
assert_has "showing what an alias resolves to"  "one@a.example.com" "$rows"
assert_has "every managed pattern, not just the first" "gamma" "$rows"
assert_lacks "and nothing hand-written"         "handwritten" "$rows"

# the target lookup used to run config_hosts once per alias
n="$(printf '%s\n' "$rows" | grep -c 'imported')"
assert_eq "one row per managed pattern" "3" "$n"

# each row's last field is the payload the picker acts on: a pattern or an alias
last="$(printf '%s\n' "$rows" | grep 'imported' | grep 'alpha' | awk '{ print $NF }')"
assert_eq "the imported payload is the bare alias" "alpha" "$last"

# already-dismissed candidates must not come back in the picker you dismissed
# them from — `--list` and `--remove` are where the ignore list is visible
run "$H" ignore 'new@fresh.example.com' > /dev/null
rows="$(run "$H" __ignoremenu)"
assert_lacks "an ignored candidate is not offered again" "fresh.example.com" "$rows"
assert_has   "imported hosts are still offered"          "imported"          "$rows"
assert_has   "and it is still listed as ignored"         "fresh.example.com" \
             "$(run "$H" ignore --list)"

# a glob hides everything it matches, not just an exact entry
H="$(newhome ignrows2)"
printf ': 1:0;ssh root@a.example.com\n: 2:0;ssh root@b.example.com\n: 3:0;ssh me@c.example.com\n' \
  > "$H/.zsh_history"
run "$H" ignore 'root@*' > /dev/null
rows="$(run "$H" __ignoremenu)"
assert_lacks "a glob hides the first match"  "a.example.com" "$rows"
assert_lacks "and the second"                "b.example.com" "$rows"
assert_has   "leaving the rest"              "c.example.com" "$rows"

# with everything dismissed and nothing imported, say so and point at the list
run "$H" ignore 'me@c.example.com' > /dev/null
out="$(run "$H" ignore)"
assert_has "reports having nothing left to offer" "Nothing to ignore" "$out"
assert_has "and points at the ignore list"        "already dismissed" "$out"


# --------------------------------------------------------------------------
section "the history cache"

# The picker memoises the history scan so `ssh` stays instant. The file is
# derived from the same data as ~/.ssh/config — every user@host:port you have
# ever reached — and used to be written with the default umask, i.e. 0644 in a
# 0755 directory, handing your server inventory to every account on the box.
H="$(newhome cache)"
printf ': 1:0;ssh cached@c1.example.com\n: 2:0;ssh cached@c2.example.com\n' > "$H/.zsh_history"
printf 'Host c1\n    HostName c1.example.com\n    User cached\n' > "$H/.ssh/config"
CDIR="$H/.cache/sushi"
HOME="$H" SUSHI_CACHE_DIR="$CDIR" "$SUSHI" __lines >/dev/null 2>&1

if [ -f "$CDIR/history" ]; then
  ok "the picker writes a cache"
  assert_eq "the cache file is 0600"      "-rw-------"  "$(ls -l "$CDIR/history" | cut -c1-10)"
  assert_eq "the cache directory is 0700" "drwx------"  "$(ls -ld "$CDIR" | cut -c1-10)"
else
  no "the picker writes a cache"
fi

# a warm read must return what the cold one did, minus the signature line
cold="$(HOME="$H" SUSHI_CACHE_DIR="$WORK/nocache-$$" "$SUSHI" __lines 2>/dev/null)"
warm="$(HOME="$H" SUSHI_CACHE_DIR="$CDIR" "$SUSHI" __lines 2>/dev/null)"
assert_eq "a cache hit produces the same picker rows" "$cold" "$warm"
assert_lacks "and never leaks the signature line into them" "#sig" "$warm"

# appending to the history changes its byte size, which is the signature
printf ': 3:0;ssh cached@c3.example.com\n' >> "$H/.zsh_history"
HOME="$H" SUSHI_CACHE_DIR="$CDIR" "$SUSHI" __lines >/dev/null 2>&1
assert_has "new history invalidates the cache" "c3.example.com" \
           "$(cat "$CDIR/history")"

# --------------------------------------------------------------------------
section "the managed block header is written once"

# managed_block used to hand the header comments back to commit_managed, which
# wrote its own on top — so every import stacked another copy, forever.
H="$(newhome hdr)"
for host in one two three; do
  printf ': 1:0;ssh x@%s.example.com\n' "$host" >> "$H/.zsh_history"
  import_all "$H" >/dev/null
done
n="$(grep -c 'Managed by sushi' "$H/.ssh/config")"
assert_eq "three imports leave one header" "1" "$n"
out="$(run "$H" list)"
for host in one two three; do
  assert_has "and every host survived: $host" "$host" "$out"
done

# a config that already grew duplicates collapses on the next write
H="$(newhome hdr2)"
{
  printf '%s\n' "# >>> sushi managed hosts >>>"
  printf '%s\n' "# Managed by sushi. Hand-edits are kept; delete a stanza to drop it."
  printf '%s\n' "# Managed by sushi. Hand-edits are kept; delete a stanza to drop it."
  printf '%s\n' "# Managed by sushi. Hand-edits are kept; delete a stanza to drop it."
  printf 'Host old\n    HostName old.example.com\n'
  printf '%s\n' "# <<< sushi managed hosts <<<"
} > "$H/.ssh/config"
printf ': 1:0;ssh new@fresh.example.com\n' > "$H/.zsh_history"
import_all "$H" >/dev/null
assert_eq "an already-duplicated header collapses to one" "1" \
          "$(grep -c 'Managed by sushi' "$H/.ssh/config")"
assert_has "without losing the existing stanza" "old" "$(run "$H" list)"

# --------------------------------------------------------------------------
section "ignore picker: splitting the selection"

# The `imported` branch used to call config_hosts once per selected row, so
# dismissing 40 hosts meant 40 full config parses (the same mistake ignore_rows
# had already been fixed for). One pass now, and this asserts the mapping it
# produces: P = pattern to ignore, D = alias to delete.
H="$(newhome ignsplit)"
cat > "$H/.ssh/config" <<'EOF'
# >>> sushi managed hosts >>>
Host alpha
    HostName a.example.com
    User one
Host beta
    HostName b.example.com
# <<< sushi managed hosts <<<
EOF
out="$(printf 'imported  alpha  (one@a.example.com)   alpha\n' | run "$H" __ignoresplit)"
assert_has "an imported row yields the alias to delete"  "D	alpha"             "$out"
assert_has "and the target to start ignoring"            "P	one@a.example.com" "$out"
out="$(printf 'scan      new@fresh.example.com   new@fresh.example.com\n' | run "$H" __ignoresplit)"
assert_has   "a scan row yields only a pattern" "P	new@fresh.example.com" "$out"
assert_lacks "and nothing to delete"            "D	"                      "$out"
# a managed host with no User must not produce a stray "@"
out="$(printf 'imported  beta  (b.example.com)   beta\n' | run "$H" __ignoresplit)"
assert_has   "a userless host ignores the bare hostname" "P	b.example.com" "$out"
assert_lacks "with no empty username glued on"           "P	@"             "$out"
# the real rows carry colour; the tag must still be recognised
out="$(run "$H" __ignoremenu | run "$H" __ignoresplit)"
assert_has "coloured rows straight from the picker still split" "D	alpha" "$out"

# --------------------------------------------------------------------------
section "sushi export / import / share"

H="$(newhome share)"
mkdir -p "$H/.ssh"
chmod 700 "$H/.ssh"
{
  printf '%s\n' '# >>> sushi managed hosts >>>'
  printf '%s\n' '# Managed by sushi.'
  printf '\n'
  printf '%s\n' 'Host alpha'
  printf '%s\n' '    HostName a.example.com'
  printf '%s\n' '    User alice'
  printf '%s\n' '    Port 2222'
  printf '%s\n' '    IdentityFile ~/.ssh/id_alpha'
  printf '%s\n' '    ProxyJump bastion'
  printf '\n'
  printf '%s\n' 'Host beta'
  printf '%s\n' '    HostName b.example.com'
  printf '%s\n' '    User bob'
  printf '\n'
  printf '%s\n' '# <<< sushi managed hosts <<<'
  printf '\n'
  printf '%s\n' '# hand-written below'
  printf '%s\n' 'Host handmade'
  printf '%s\n' '    HostName hand.example.com'
} > "$H/.ssh/config"
chmod 600 "$H/.ssh/config"

# --all sanitizes
out="$(run "$H" export --all -o - 2>/dev/null)"
assert_has   "export --all emits Host alpha"     "Host alpha"              "$out"
assert_has   "and HostName"                      "HostName a.example.com"  "$out"
assert_has   "and User"                          "User alice"              "$out"
assert_has   "and non-22 Port"                   "Port 2222"               "$out"
assert_lacks "no IdentityFile keyword line"      $'\n    IdentityFile'     "$out"
assert_lacks "no ProxyJump keyword line"         $'\n    ProxyJump'         "$out"
assert_has   "handmade hosts are included"       "Host handmade"           "$out"
assert_has   "share file carries the marker"     "# sushi-share 1"         "$out"

# named alias subset
out="$(run "$H" export beta -o - 2>/dev/null)"
assert_has   "named export keeps beta"   "Host beta"  "$out"
assert_lacks "and drops the others"      "Host alpha" "$out"

# share == export
out_share="$(run "$H" share --all -o - 2>/dev/null)"
out_exp="$(run "$H" export --all -o - 2>/dev/null)"
assert_eq "share matches export" "$out_exp" "$out_share"

# -o file + refuse clobber
SHAREF="$WORK/sushi-share-out"
rm -f "$SHAREF"
out="$(cd "$WORK" && HOME="$H" "$SUSHI" export --all -o "$SHAREF" 2>&1)"
assert_has "writes the named file" "Wrote" "$out"
mode="$(ls -l "$SHAREF" | cut -c1-10)"
assert_eq "share file mode looks private" "-rw-------" "$mode"
if HOME="$H" "$SUSHI" export --all -o "$SHAREF" >/dev/null 2>&1; then
  no "refuses to clobber without --force"
else
  ok "refuses to clobber without --force"
fi
out="$(HOME="$H" "$SUSHI" export --all --force -o "$SHAREF" 2>&1)"
assert_has "force overwrites" "Wrote" "$out"

# dry run writes nothing new
rm -f "$WORK/dry-share"
out="$(HOME="$H" "$SUSHI" export --all -n -o "$WORK/dry-share" 2>&1)"
assert_has "dry run says so" "dry run" "$out"
if [ -e "$WORK/dry-share" ]; then no "dry run leaves no file"; else ok "dry run leaves no file"; fi

# import merges; unmanaged content survives
H2="$(newhome share-imp)"
mkdir -p "$H2/.ssh"; chmod 700 "$H2/.ssh"
{
  printf '%s\n' '# keep me'
  printf '%s\n' 'Host keep'
  printf '%s\n' '    HostName keep.example.com'
} > "$H2/.ssh/config"
chmod 600 "$H2/.ssh/config"
printf 'w\n' | HOME="$H2" "$SUSHI" import "$SHAREF" >/dev/null 2>&1
cfg="$(cat "$H2/.ssh/config")"
assert_has "import adds alpha"              "Host alpha"         "$cfg"
assert_has "import adds beta"               "Host beta"          "$cfg"
assert_has "unmanaged content survives"     "Host keep"          "$cfg"
assert_has "and the keep comment"           "# keep me"          "$cfg"
assert_has "lands inside the managed block" "sushi managed"      "$cfg"
assert_lacks "imported without IdentityFile" "IdentityFile"      "$cfg"
assert_has "stamps # added"                 "# added "           "$cfg"
n="$(count_backups "$H2/.ssh")"
assert_eq "import took a backup" "1" "$n"
assert_eq "config stays 0600" "-rw-------" "$(ls -l "$H2/.ssh/config" | cut -c1-10)"

# collision: existing alias skipped; same host under new alias kept
{
  printf '%s\n' 'Host alpha'
  printf '%s\n' '    HostName elsewhere.example.com'
  printf '\n'
  printf '%s\n' 'Host fresh'
  printf '%s\n' '    HostName a.example.com'
  printf '%s\n' '    User alice'
} > "$WORK/collide.txt"
out="$(printf 'w\n' | HOME="$H2" "$SUSHI" import "$WORK/collide.txt" 2>&1)"
assert_has   "skips existing alias"     "skipping alpha" "$out"
assert_has   "keeps a new alias"        "Host fresh"     "$(cat "$H2/.ssh/config")"
assert_has   "even for the same host"   "fresh"          "$(HOME="$H2" "$SUSHI" list)"

# refuse Match / Include / IdentityFile / wildcards
{
  printf '%s\n' 'Host star'
  printf '%s\n' '    HostName star.example.com'
  printf '%s\n' '    IdentityFile ~/.ssh/nope'
  printf '\n'
  printf '%s\n' 'Host *.evil'
  printf '%s\n' '    HostName evil.example.com'
  printf '\n'
  printf '%s\n' 'Match host foo'
  printf '%s\n' '    HostName matched.example.com'
  printf '\n'
  printf '%s\n' 'Include /etc/ssh/ssh_config'
} > "$WORK/nasty.txt"
H3="$(newhome share-nasty)"
mkdir -p "$H3/.ssh"; chmod 700 "$H3/.ssh"
out="$(printf 'w\n' | HOME="$H3" "$SUSHI" import "$WORK/nasty.txt" 2>&1)"
cfg="$(cat "$H3/.ssh/config" 2>/dev/null || true)"
assert_has   "keeps a clean Host"           "Host star"       "$cfg"
assert_lacks "drops IdentityFile on import" "IdentityFile"    "$cfg"
assert_lacks "drops wildcard Host"          "Host *.evil"     "$cfg"
assert_has   "warns about IdentityFile"     "dropping"        "$out"

# raw ssh_config without markers
{
  printf '%s\n' 'Host raw'
  printf '%s\n' '    HostName raw.example.com'
  printf '%s\n' '    User rawuser'
} > "$WORK/raw.txt"
out="$(printf 'w\n' | HOME="$H3" "$SUSHI" import "$WORK/raw.txt" 2>&1)"
assert_has "raw ssh_config imports" "Host raw" "$(cat "$H3/.ssh/config")"

# pipe is not consent
H4="$(newhome share-pipe)"
mkdir -p "$H4/.ssh"; chmod 700 "$H4/.ssh"
: > "$H4/.ssh/config"; chmod 600 "$H4/.ssh/config"
out="$(printf '' | HOME="$H4" "$SUSHI" import "$WORK/raw.txt" 2>&1)"
assert_has   "a pipe cancels"          "Cancelled" "$out"
assert_lacks "and writes nothing"      "Host raw"  "$(cat "$H4/.ssh/config")"

# -n writes nothing
out="$(printf 'w\n' | HOME="$H4" "$SUSHI" import -n "$WORK/raw.txt" 2>&1)"
assert_has   "import -n says dry run"  "dry run"  "$out"
assert_lacks "and leaves config empty" "Host raw" "$(cat "$H4/.ssh/config")"

# --config round-trip for ignore + custom theme
H5="$(newhome share-cfg)"
mkdir -p "$H5/.ssh" "$H5/.config/sushi/themes"
chmod 700 "$H5/.ssh"
{
  printf '%s\n' '# >>> sushi managed hosts >>>'
  printf '%s\n' 'Host solo'
  printf '%s\n' '    HostName solo.example.com'
  printf '%s\n' '# <<< sushi managed hosts <<<'
} > "$H5/.ssh/config"
chmod 600 "$H5/.ssh/config"
printf 'root@*\n*.staging.example.com\n' > "$H5/.ssh/sushi-ignore"
chmod 600 "$H5/.ssh/sushi-ignore"
printf 'name: mine\naccent: "#112233"\n' > "$H5/.config/sushi/themes/mine.yaml"
CFGS="$WORK/with-cfg.txt"
out="$(HOME="$H5" SUSHI_THEME=mine SUSHI_MODE=enter "$SUSHI" export --all --config -o "$CFGS" 2>&1)"
assert_has "config export wrote a file" "Wrote" "$out"
body="$(cat "$CFGS")"
assert_has "includes ignore section"   "@@SUSHI_IGNORE@@" "$body"
assert_has "includes root@*"           "root@*"           "$body"
assert_has "includes theme section"    "@@SUSHI_THEME@@"  "$body"
assert_has "includes SUSHI_MODE"       "SUSHI_MODE=enter" "$body"

H6="$(newhome share-cfg-in)"
mkdir -p "$H6/.ssh"; chmod 700 "$H6/.ssh"
: > "$H6/.ssh/config"; chmod 600 "$H6/.ssh/config"
# without --config: hosts land, settings noted
out="$(printf 'w\n' | HOME="$H6" SUSHI_RC="$H6/.zshrc" "$SUSHI" import "$CFGS" 2>&1)"
assert_has "notes settings without --config" "pass --config" "$out"
assert_has "still imports the host"          "Host solo"     "$(cat "$H6/.ssh/config")"
assert_lacks "does not write ignore yet"     "root@"         "$(cat "$H6/.ssh/sushi-ignore" 2>/dev/null || true)"

# with --config: ignore + theme applied
H7="$(newhome share-cfg-apply)"
mkdir -p "$H7/.ssh"; chmod 700 "$H7/.ssh"
: > "$H7/.ssh/config"; chmod 600 "$H7/.ssh/config"
out="$(printf 'w\n' | HOME="$H7" SUSHI_RC="$H7/.zshrc" "$SUSHI" import --config "$CFGS" 2>&1)"
assert_has "applies ignore patterns" "root@*" "$(cat "$H7/.ssh/sushi-ignore")"
assert_has "writes the theme file"   "mine"   "$(ls "$H7/.config/sushi/themes/")"
assert_has "persists SUSHI_THEME"    "SUSHI_THEME=mine" "$(cat "$H7/.zshrc")"

# subcommands advertised
subs="$("$SUSHI" __subcommands)"
assert_has "__subcommands lists export" "export" "$subs"
assert_has "__subcommands lists share"  "share"  "$subs"
assert_has "__subcommands lists import" "import" "$subs"
assert_has "__subcommands lists update" "update" "$subs"
assert_has "__subcommands lists upgrade" "upgrade" "$subs"

# --------------------------------------------------------------------------
section "sushi add"

H="$(newhome add)"
out="$(run "$H" add deploy@web1.example.com)"
assert_has "adds a host that was never in the history" "Host web1" "$out"
assert_has "with the user it was given"                "User deploy" "$out"
assert_has "and it lands in the config"                "web1" "$(run "$H" list)"
assert_eq  "and the config is still 0600" "-rw-------" "$(ls -l "$H/.ssh/config" | cut -c1-10)"

# the form sushi itself prints, pasted straight back in
out="$(run "$H" add -n 'web2.example.com:2222')"
assert_has "accepts the user@host:port form it prints" "HostName web2.example.com" "$out"
assert_has "turning the colon into a Port"             "Port 2222"                 "$out"
assert_lacks "and writes nothing on -n"                "Updated"                   "$out"
assert_lacks "so the host is not in the config"        "web2"                      "$(run "$H" list)"

# any flag the history parser understands
out="$(run "$H" add -n keyed.example.com -i /tmp/k -J bastion -p 2200 -l bob)"
assert_has "passes -i through" "IdentityFile /tmp/k" "$out"
assert_has "passes -J through" "ProxyJump bastion"   "$out"
assert_has "passes -p through" "Port 2200"           "$out"
assert_has "passes -l through" "User bob"            "$out"

# --as names the stanza
out="$(run "$H" add --as staging deploy@10.20.30.40)"
assert_has "--as sets the alias"       "Host staging" "$out"
assert_has "and it is what gets used"  "staging"      "$(run "$H" list)"
out="$(run "$H" add --as=inline other.example.com)"
assert_has "--as=NAME works too" "Host inline" "$out"

# an IP with no --as still gets the readable alias scan would have given it
out="$(run "$H" add -n 192.168.1.254)"
assert_has "an IP gets the srv- alias" "Host srv-192-168-1-254" "$out"

# refusing the obvious mistakes
out="$(run "$H" add deploy@web1.example.com)"
assert_has "a second add of the same target is refused" "already in" "$out"
assert_has "naming the alias that covers it"            "web1"       "$out"
n="$(printf '%s\n' "$(run "$H" list)" | grep -c 'web1.example.com')"
assert_eq  "and nothing is written twice" "1" "$n"
out="$(run "$H" add --as web1again deploy@web1.example.com)"
assert_has "but --as says you meant it" "Host web1again" "$out"

if run "$H" add --as 'not an alias' x.example.com >/dev/null 2>&1; then
  no "an unusable --as name is refused"
else
  ok "an unusable --as name is refused"
fi
if run "$H" add --as staging y.example.com >/dev/null 2>&1; then
  no "an --as name already in the config is refused"
else
  ok "an --as name already in the config is refused"
fi
if run "$H" add >/dev/null 2>&1; then
  no "add with no destination is refused"
else
  ok "add with no destination is refused"
fi
if run "$H" add -n -- >/dev/null 2>&1; then
  no "add with nothing that parses is refused"
else
  ok "add with nothing that parses is refused"
fi
# --as with no name must not spin: `shift 2` with one argument left does not
# shift, and a loop that does not advance never ends
run_bounded "$H" 5 add --as >/dev/null 2>&1; rc=$?
case "$rc" in
  0)   no "add --as with no name is refused" ;;
  124) no "add --as with no name is refused (it hung instead)" ;;
  *)   ok "add --as with no name is refused" ;;
esac

# an ignore pattern and an explicit add contradict each other: the add wins,
# but it has to say so
run "$H" ignore 'root@*' >/dev/null
out="$(run "$H" add -n root@rooted.example.com)"
assert_has "add notes an ignore pattern that matches" "matches this host" "$out"
assert_has "and adds it anyway"                       "Host rooted"       "$out"

# the written config must still parse
if command -v ssh >/dev/null 2>&1; then
  if ssh -F "$H/.ssh/config" -G probe.invalid >/dev/null 2>&1; then
    ok "everything add wrote parses under ssh -G"
  else
    no "everything add wrote parses under ssh -G"
  fi
fi

# --------------------------------------------------------------------------
section "sushi --version"

out="$(run "$H" --version)"
assert_has "reports a version"            "sushi 0" "$out"
assert_eq  "on one line"                  "1"       "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq  "and version is the same"      "$out"    "$(run "$H" version)"
# usage() reads its own header, so it must not be pinned to a line range
out="$(run "$H" help)"
assert_has "usage lists add"        "sushi add"     "$out"
assert_has "usage lists --version"  "sushi --version" "$out"
assert_has "usage still lists scan" "sushi scan"    "$out"
assert_has "usage lists doctor"     "sushi doctor"  "$out"
assert_has "usage lists update"     "sushi update"  "$out"
assert_has "usage lists export"     "sushi export"  "$out"
assert_has "usage lists import"     "sushi import"  "$out"
assert_lacks "and stops at the code" "set -uo"      "$out"

# --------------------------------------------------------------------------
section "sushi doctor"

DH="$(newhome doctor)"
chmod 700 "$DH/.ssh"
drun() { SHELL=/bin/zsh HOME="$DH" SUSHI_RC="$DH/.zshrc" SUSHI_THEME=none "$SUSHI" doctor "$@"; }

out="$(drun 2>&1)"
assert_has "doctor prints the version"              "sushi 0"           "$out"
assert_has "and ssh"                                "ssh"               "$out"
assert_has "and awk"                                "awk"               "$out"
assert_has "a missing config is a warning"          "none yet"          "$out"
assert_has "a missing integration is a warning"     "install.sh"        "$out"
assert_has "and empty history is a warning"         "scan will be empty" "$out"
assert_eq  "warnings are not a failure"             "0"                 "$(drun >/dev/null 2>&1; echo $?)"
assert_has "doctor --help is one line" "sushi doctor" "$(drun --help)"
assert_lacks "and is not the picker empty-state" "no hosts in" "$(drun --help)"

printf 'Host box\n    HostName box.example.com\n' > "$DH/.ssh/config"
chmod 600 "$DH/.ssh/config"
printf ': 1:0;ssh box.example.com\n' > "$DH/.zsh_history"
{
  printf '%s\n' '# >>> sushi >>>'
  printf '%s\n' ': ${SUSHI_MODE:=key,enter}'
  printf '%s\n' 'source "/x/sushi.zsh"'
  printf '%s\n' '# <<< sushi <<<'
} > "$DH/.zshrc"
out="$(drun 2>&1)"
assert_has "a readable config is counted"           "1 host"            "$out"
assert_has "and marked parseable"                   "parses"            "$out"
assert_has "history files are named"                ".zsh_history"      "$out"
assert_has "the sourced rc is integration ok"       "key,enter"         "$out"
assert_eq  "a healthy machine exits 0"              "0"                 "$(drun >/dev/null 2>&1; echo $?)"

printf 'Host box\n    NotARealSshOption yes\n' > "$DH/.ssh/config"
out="$(drun 2>&1)"
assert_has "an unparseable config is a failure"     "cannot parse"      "$out"
assert_eq  "and doctor exits 1"                     "1"                 "$(drun >/dev/null 2>&1; echo $?)"

# --------------------------------------------------------------------------
section "sushi update"

out="$("$SUSHI" update --help)"
assert_has "update --help is one line" "sushi update" "$out"
assert_lacks "and is not the picker empty-state" "no hosts in" "$out"
assert_eq "upgrade is the same command" \
  "$("$SUSHI" update --help)" "$("$SUSHI" upgrade --help)"

NG="$WORK/update-nongit"
mkdir -p "$NG/lib"
cp "$SUSHI" "$NG/sushi"
cp "$ROOT"/lib/*.sh "$NG/lib/"
chmod +x "$NG/sushi"
out="$("$NG/sushi" update 2>&1)" || true
assert_has "a copy with no .git says so" "not a git checkout" "$out"
assert_eq  "and exits 1" "1" "$("$NG/sushi" update >/dev/null 2>&1; echo $?)"

if ! command -v git >/dev/null 2>&1; then
  skip "update talks to a git remote" "git not installed"
else
  # Local origin + clone. The engine is planted in the clone so SELF's
  # directory is the git root — the same layout as `git clone … ~/sushi`.
  VER="$(awk -F'"' '/^VERSION=/{print $2; exit}' "$SUSHI")"
  NEWER="$(printf '%s\n' "$VER" | awk -F. '{ print $1 "." $2 "." ($3 + 1) }')"

  git_ident() {
    git -C "$1" config user.email "sushi@test"
    git -C "$1" config user.name "sushi"
  }
  plant_engine() {
    mkdir -p "$1/lib"
    cp "$SUSHI" "$1/sushi"
    cp "$ROOT"/lib/*.sh "$1/lib/"
    chmod +x "$1/sushi"
  }

  ORIGIN="$WORK/update-origin.git"
  SRC="$WORK/update-src"
  mkdir -p "$SRC"
  git init --quiet "$SRC"
  git_ident "$SRC"
  printf 'x\n' > "$SRC/x"
  git -C "$SRC" add x
  git -C "$SRC" commit -q -m init
  git -C "$SRC" branch -M main
  git -C "$SRC" tag "$VER"
  git init --quiet --bare "$ORIGIN"
  git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
  git -C "$SRC" remote add origin "$ORIGIN"
  git -C "$SRC" push -q -u origin main
  git -C "$SRC" push -q origin "$VER"

  CLONE="$WORK/update-clone"
  git clone -q "$ORIGIN" "$CLONE"
  plant_engine "$CLONE"
  ENGINE="$CLONE/sushi"

  out="$("$ENGINE" update 2>&1)"
  rc=$?
  assert_eq  "a clone at HEAD is up to date" "0" "$rc"
  assert_has "and says so"                   "up to date" "$out"
  assert_has "names the commit"              "commit"     "$out"
  assert_has "names the release"             "$VER"       "$out"
  assert_lacks "and does not suggest a pull" "git pull"   "$out"

  # Newer tag on the same commit: a release, not a new commit.
  git -C "$SRC" tag "$NEWER"
  git -C "$SRC" push -q origin "$NEWER"
  out="$("$ENGINE" update 2>&1)"
  rc=$?
  assert_eq  "a newer tag is an available update" "1" "$rc"
  assert_has "and names the release"              "$NEWER"          "$out"
  assert_has "and still has the old version"      "have $VER"       "$out"
  assert_has "flags the release"                  "new   release"   "$out"
  assert_lacks "commit is unchanged"              "new   commit"    "$out"
  assert_has "tells you to pull"                  "git pull"        "$out"

  # Then a new commit on origin, still not pulled.
  printf 'y\n' >> "$SRC/x"
  git -C "$SRC" commit -q -am next
  git -C "$SRC" push -q origin main
  out="$("$ENGINE" update 2>&1)"
  rc=$?
  assert_eq  "a new commit is an available update" "1" "$rc"
  assert_has "and counts it"                       "1 commit on"   "$out"
  assert_has "flags the commit"                    "new   commit"  "$out"
  assert_has "release is still newer"              "$NEWER"        "$out"
  assert_has "still tells you to pull"             "git pull"      "$out"
fi

# --------------------------------------------------------------------------
section "added at / last used at"

# TZ is pinned so the rendered dates are the same everywhere, and the epochs are
# fixed: 1700000000 is 2023-11-14 22:13 UTC.
H="$(newhome dates)"
cat > "$H/.ssh/config" <<'EOF'
Host dated
    HostName dated.example.com
    User d
    # added 2023-11-14 22:13
Host undated
    HostName undated.example.com
    User u
Host never
    HostName never.example.com
EOF
printf ': 1700000000:0;ssh d@dated.example.com\n' > "$H/.zsh_history"
printf 'ssh u@undated.example.com\n' > "$H/.bash_history"

DCACHE="$WORK/dates-cache"
drun() { TZ=UTC XDG_CACHE_HOME="$DCACHE" HOME="$H" SUSHI_THEME=none "$SUSHI" "$@" 2>&1; }

prev="$(drun __preview dated)"
assert_has "the preview dates the import"   "added at       2023-11-14 22:13" "$prev"
assert_has "...and the last connection"     "last used at   2023-11-14 22:13" "$prev"
assert_has "both carry a rough age"         "ago)"                            "$prev"

# A host the history knows but cannot date is not the same as one it has never
# heard of, and neither is an invented date.
prev="$(drun __preview undated)"
assert_has   "a dateless history says so"       "last used at   unknown"  "$prev"
assert_lacks "and does not invent a date"       "1970"                    "$prev"
prev="$(drun __preview never)"
assert_has "a host with no history reads never" "last used at   never"    "$prev"
assert_has "an unnoted stanza reads unknown"    "added at       unknown"  "$prev"

# the picker's own columns
lines="$(drun __lines)"
assert_has "the row carries both ages" "d@dated.example.com" "$lines"
row="$(printf '%s\n' "$lines" | grep '^dated ' | cut -f1)"
# the ages themselves move with the calendar, so only their shape is pinned
assert_eq  "alias, the two ages, then the target" "dated age age d@dated.example.com" \
           "$(printf '%s' "$row" | awk '
              function shape(c) { return (c ~ /^([0-9]+[mhdy]|now)$/ ? "age" : c) }
              { print $1, shape($2), shape($3), $4 }')"
assert_eq  "and nothing after the target" "4" "$(printf '%s' "$row" | awk '{ print NF }')"
row="$(printf '%s\n' "$lines" | grep '^never ' | cut -f1)"
assert_eq  "an unknown age is a dash, not a blank" "- -" "$(printf '%s' "$row" | awk '{ print $2, $3 }')"

# the two extra columns must not disturb what fzf hands back
n="$(printf '%s\n' "$lines" | awk -F'\t' 'NF != 2' | wc -l | tr -d ' ')"
assert_eq "still exactly two columns" "0" "$n"
assert_eq "the payload column is still the bare alias" "dated" \
          "$(printf '%s\n' "$lines" | grep '^dated ' | cut -f2)"

# ...under either ordering
alpha="$(TZ=UTC XDG_CACHE_HOME="$DCACHE" HOME="$H" SUSHI_THEME=none SUSHI_SORT=alpha "$SUSHI" __lines 2>&1)"
assert_eq "SUSHI_SORT=alpha keeps the columns" "4" \
          "$(printf '%s\n' "$alpha" | grep '^dated ' | cut -f1 | awk '{ print NF }')"
assert_eq "...and is still A-Z" "dated" "$(printf '%s\n' "$alpha" | sed -n 1p | cut -f2)"

# the alias column sizes itself to the widest alias, so the ages stay in line
H="$(newhome datewidth)"
printf 'Host a\n    HostName a.example.com\nHost %s\n    HostName b.example.com\n' \
  "a-very-long-alias-indeed" > "$H/.ssh/config"
# the target is the last field, so where it starts is where the ages ended
col="$(XDG_CACHE_HOME="$WORK/dw-cache" HOME="$H" SUSHI_THEME=none "$SUSHI" __lines 2>&1 \
       | cut -f1 | awk '{ print index($0, $NF) }' | sort -u | wc -l | tr -d ' ')"
assert_eq "the columns start at the same offset on every row" "1" "$col"

# every shell keeps the date somewhere else: zsh inline, bash on the line before,
# fish on the line after
H="$(newhome dateformats)"
mkdir -p "$H/.local/share/fish"
printf ': 1700000000:0;ssh z@zsh.example.com\n' > "$H/.zsh_history"
printf '#1700000001\nssh b@bash.example.com\n' > "$H/.bash_history"
printf -- '- cmd: ssh f@fish.example.com\n  when: 1700000002\n' > "$H/.local/share/fish/fish_history"
cand="$(run "$H" __candidates)"
assert_has "zsh EXTENDED_HISTORY dates a host" "z|zsh.example.com||||1700000000"  "$cand"
assert_has "bash HISTTIMEFORMAT dates a host"  "b|bash.example.com||||1700000001" "$cand"
assert_has "fish dates a host"                 "f|fish.example.com||||1700000002" "$cand"

# a date belonging to the command next door must not be borrowed
H="$(newhome datefish)"
mkdir -p "$H/.local/share/fish"
printf -- '- cmd: ssh a@one.example.com\n  when: 100\n- cmd: ls\n  when: 1700000000\n- cmd: ssh b@two.example.com\n  when: 1700000009\n' \
  > "$H/.local/share/fish/fish_history"
cand="$(run "$H" __candidates)"
assert_has "the host keeps its own date"    "a|one.example.com||||100"        "$cand"
assert_has "and the next one keeps its own" "b|two.example.com||||1700000009" "$cand"

# the newest wins, not the first or the last seen
H="$(newhome datemax)"
printf ': 1700000000:0;ssh m@many.example.com\n: 1600000000:0;ssh m@many.example.com\n' > "$H/.zsh_history"
assert_has "the newest date wins" "2|m|many.example.com||||1700000000" "$(run "$H" __candidates)"

# a shell that keeps no dates at all still counts, it just cannot date
H="$(newhome nodates)"
printf 'ssh p@plain.example.com\nssh p@plain.example.com\n' > "$H/.zsh_history"
assert_has "an undated history still counts hosts" "2|p|plain.example.com|||" \
           "$(run "$H" __candidates)"

# both extractors have to make the same sense of every one of those shapes
H="$(newhome dateextract)"
STAMPS="$WORK/stamps"
printf -- '#1700000001\nssh b@bs.example.com\n- cmd: ssh f@fs.example.com\n  when: 1700000002\n: 1700000003:0;ssh z@zs.example.com\n--\n#1700000004\nssh c@cs.example.com\n' \
  > "$STAMPS"
assert_eq "the extractors agree about dates" \
          "$(SUSHI_EXTRACT=bash "$SUSHI" __extract < "$STAMPS")" \
          "$("$SUSHI" __extract < "$STAMPS")"

# import writes the note the picker reads back
H="$(newhome addednote)"
printf ': 1700000000:0;ssh deploy@fresh.example.com\n' > "$H/.zsh_history"
out="$(import_all "$H")"
assert_has "the stanza records when it was imported" "# added " "$out"
assert_has "...and it lands in the config" "# added " "$(cat "$H/.ssh/config")"
prev="$(XDG_CACHE_HOME="$WORK/added-cache" HOME="$H" SUSHI_THEME=none "$SUSHI" __preview fresh 2>&1)"
assert_lacks "the imported host knows its own age" "added at       unknown" "$prev"
# the note is a comment, so nothing else may notice it
assert_lacks "the note is not mistaken for a host" "added" "$(run "$H" list | tail -n +2)"
run "$H" __rmalias fresh > /dev/null
assert_lacks "deleting the host takes its note with it" "# added" "$(cat "$H/.ssh/config")"

# `sushi add` comes through the same builder, so it is dated too
H="$(newhome addeddate)"
out="$(run "$H" add luca@byhand.example.com -n)"
assert_has "sushi add dates its stanza too" "# added " "$out"

# --------------------------------------------------------------------------
section "theme"

H="$(newhome theme)"
printf 'Host alpha\n    HostName a.example.com\n    User one\n    Port 2020\n' > "$H/.ssh/config"
printf ': 1:0;ssh two@b.example.com\n' > "$H/.zsh_history"

esc="$(printf '\033')"

# Colours must never break the tab-delimited contract fzf depends on, and the
# payload columns have to stay clean — they get passed back to ssh and to
# `sushi ignore`.
line="$(run "$H" __lines)"
assert_has "picker rows are coloured"        "${esc}[" "$line"
n="$(printf '%s\n' "$line" | awk -F'\t' 'NF != 2' | wc -l | tr -d ' ')"
assert_eq  "still exactly two columns" "0" "$n"
assert_eq  "the payload column has no escapes" "alpha" "$(printf '%s' "$line" | cut -f2)"
assert_has "and the visible column is still greppable" "one@a.example.com:2020" \
           "$(printf '%s' "$line" | cut -f1)"

menu="$(run "$H" __scanmenu)"
n="$(printf '%s\n' "$menu" | awk -F'\t' 'NF != 3' | wc -l | tr -d ' ')"
assert_eq  "scan rows still have three columns" "0" "$n"
assert_eq  "the ignore-pattern column is clean" "two@b.example.com" \
           "$(printf '%s' "$menu" | cut -f3)"
assert_has "the target stays contiguous for matching" "two@b.example.com" \
           "$(printf '%s' "$menu" | cut -f1)"

# SUSHI_THEME=none must leave everything byte-plain, for anyone who themes fzf
# themselves or pipes the output around
plain="$(HOME="$H" SUSHI_THEME=none "$SUSHI" __lines 2>&1)"
assert_lacks "SUSHI_THEME=none emits no escapes"  "${esc}[" "$plain"
plain="$(HOME="$H" SUSHI_THEME=none "$SUSHI" __scanmenu 2>&1)"
assert_lacks "...in the scan menu either"         "${esc}[" "$plain"
plain="$(HOME="$H" SUSHI_THEME=none "$SUSHI" __preview alpha 2>&1)"
assert_lacks "...nor the preview"                 "${esc}[" "$plain"

# list is captured by scripts far more often than it is read, so it only colours
# itself on a terminal
assert_lacks "list is plain when piped" "${esc}[" "$(run "$H" list)"

# the preview is rendered by fzf, so it always colours
assert_has "the preview is coloured" "${esc}[" "$(run "$H" __preview alpha)"

# a bad SUSHI_FZF_OPTS must not wedge anything that does not use fzf
out="$(HOME="$H" SUSHI_FZF_OPTS='--nonsense' "$SUSHI" list 2>&1)"
assert_has "SUSHI_FZF_OPTS does not affect non-fzf commands" "alpha" "$out"

# --------------------------------------------------------------------------
section "theming"

TH="$WORK/themes"; mkdir -p "$TH"
theme() { TH_FILE="$1"; shift; HOME="$H" SUSHI_THEME="$TH_FILE" "$SUSHI" "$@" 2>&1; }

# themes/sushi.yaml is documented as the built-in palette written out as YAML,
# and it is what everyone copies to make their own. The built-in is precomputed
# rather than parsed — that is the only reason the picker does not pay for the
# parser on every invocation — so nothing but this test keeps the two in step.
strip_source() { grep -v 'source\|read on top'; }
assert_eq  "themes/sushi.yaml renders exactly like the built-in theme" \
           "$(HOME="$H" "$SUSHI" theme 2>&1 | strip_source)" \
           "$(HOME="$H" SUSHI_THEME="$ROOT/themes/sushi.yaml" "$SUSHI" theme 2>&1 | strip_source)"
assert_eq  "...down to the bytes on the picker rows" \
           "$(HOME="$H" "$SUSHI" __lines 2>&1)" \
           "$(HOME="$H" SUSHI_THEME="$ROOT/themes/sushi.yaml" "$SUSHI" __lines 2>&1)"

# the default reads no file at all, so a clone with no themes/ still has colour
assert_has "the built-in theme needs no file" "built-in" "$(theme sushi theme)"
assert_has "and names itself"                 "sushi"    "$(theme sushi theme)"

# every shipped theme has to parse cleanly — a warning here is a broken theme
for f in "$ROOT"/themes/*.yaml; do
  out="$(HOME="$H" SUSHI_THEME="$f" "$SUSHI" __lines 2>&1 >/dev/null)"
  assert_eq "themes/$(basename "$f") parses without complaint" "" "$out"
done

# hex, the #abc shorthand, palette indexes and attributes
cat > "$TH/full.yaml" <<'YAML'
name: full
accent: "#010203"
heading: "#f0a"
prompt: 244
target: bold "#ffffff"
value: underline
muted: dim italic 8
YAML
out="$(theme "$TH/full.yaml" theme)"
assert_has "#rrggbb becomes a truecolour escape" "${esc}[38;2;1;2;3m"       "$out"
assert_has "#abc expands to #aabbcc"             "${esc}[38;2;255;0;170m"   "$out"
assert_has "a number is a palette index"         "${esc}[38;5;244m"         "$out"
assert_has "attributes come before the colour"   "${esc}[1;38;2;255;255;255m" "$out"
assert_has "an attribute on its own is allowed"  "${esc}[4m"                "$out"
assert_has "several attributes and an index"     "${esc}[2;3;38;5;8m"       "$out"

# "none" is how you switch one role off without switching the theme off
printf 'value: none\n' > "$TH/off.yaml"
assert_lacks "a role set to none is not coloured" "${esc}[1;38;2;253;247;251m" \
             "$(theme "$TH/off.yaml" __lines)"

# a partial theme is the common case: change two colours, inherit the rest
printf 'name: two\naccent: 2\nfzf:\n  hl: 2\n' > "$TH/two.yaml"
out="$(theme "$TH/two.yaml" theme)"
assert_has "a partial theme keeps the built-in heading" "#8c6fe0" "$out"
assert_has "and its own accent"                        "38;5;2"   "$out"
plainout="$(printf '%s\n' "$out" | sed "s/${esc}\[[0-9;]*m//g;s/^ *//;s/  *$//")"
assert_eq  "an overridden fzf key is passed once, not twice" "1" \
           "$(printf '%s\n' "$plainout" | grep -c '^hl  *2$' | tr -d ' ')"
assert_eq  "and the built-in value for it is gone"           "0" \
           "$(printf '%s\n' "$plainout" | grep -c '^hl  *#22c7e8$' | tr -d ' ')"

# a comment where the value would be is still a section header, which is how
# anyone annotating their own theme file will write it
cat > "$TH/cmt.yaml" <<'YAML'
# a whole-line comment
accent: "#010203"   # and a trailing one
fzf:                # including here, where a section opens
  hl: 2
symbols:
  pointer: ">"
YAML
out="$(theme "$TH/cmt.yaml" theme 2>&1)"
assert_lacks "comments never look like values"  "unknown key"            "$out"
assert_has   "a trailing comment is not colour" "${esc}[38;2;1;2;3m"     "$out"
assert_has   "and the section under one is read" "hl"                    "$out"

# the yaml actually reaches the rows, not just `sushi theme`
lines="$(theme "$TH/two.yaml" __lines)"
assert_has "a theme colours the picker rows" "${esc}[" "$lines"
printf 'value: "#010203"\n' > "$TH/acc.yaml"
assert_has "and the colour in the file is the colour in the preview" \
           "${esc}[38;2;1;2;3m" "$(theme "$TH/acc.yaml" __preview alpha)"

# a broken theme has to say so and keep working: sushi is how you reach a server
cat > "$TH/bad.yaml" <<'YAML'
accent: "#zzzzzz"
heading: 300
bogus: 1
this line has no colon
YAML
out="$(theme "$TH/bad.yaml" __lines)"
assert_has "a bad colour is named"        "not a colour: #zzzzzz"     "$out"
assert_has "so is an out-of-range index"  "index out of range: 300"   "$out"
assert_has "so is an unknown key"         "unknown key: bogus"        "$out"
assert_has "so is a line it cannot parse" "cannot parse: this line"   "$out"
assert_has "and the host list still comes out" "alpha" "$out"

# a name is looked up in SUSHI_THEME_DIR, then ~/.config, then the clone
printf 'name: fromdir\naccent: 4\n' > "$TH/mine.yaml"
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_THEME=mine "$SUSHI" theme 2>&1)"
assert_has "SUSHI_THEME=<name> finds SUSHI_THEME_DIR/<name>.yaml" "mine.yaml" "$out"
mkdir -p "$H/.config/sushi/themes"
printf 'name: fromconfig\n' > "$H/.config/sushi/themes/mine.yaml"
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_THEME=mine "$SUSHI" theme 2>&1)"
assert_has "SUSHI_THEME_DIR wins over ~/.config" "$TH/mine.yaml" "$out"
out="$(HOME="$H" SUSHI_THEME=mine "$SUSHI" theme 2>&1)"
assert_has "the config dir under $HOME is searched" "$H/.config/sushi/themes/mine.yaml" "$out"
printf 'name: fromyml\n' > "$TH/short.yml"
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_THEME=short "$SUSHI" theme 2>&1)"
assert_has ".yml is accepted too" "short.yml" "$out"
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_THEME=nosuchtheme "$SUSHI" __lines 2>&1)"
assert_has "an unknown theme name says so"     "no theme named nosuchtheme" "$out"
assert_has "and falls back to the built-in"    "alpha"                      "$out"
out="$(theme "$TH/nothere.yaml" __lines)"
assert_has "an unreadable theme file says so"  "cannot read theme"          "$out"

# --------------------------------------------------------------------------
# `sushi theme list` / `sushi themes`

printf 'name: only-here\n' > "$TH/only.yaml"
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" "$SUSHI" themes 2>&1)"
assert_has "themes lists what it found"        "only"   "$out"
assert_has "and the directory it came from"    "$TH"    "$out"
assert_has "and the shipped ones"              "ansi"   "$out"
assert_eq  "sushi themes == sushi theme list" \
           "$(HOME="$H" SUSHI_THEME_DIR="$TH" "$SUSHI" themes 2>&1)" \
           "$(HOME="$H" SUSHI_THEME_DIR="$TH" "$SUSHI" theme list 2>&1)"

# the active one is marked, wherever it came from
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_THEME=only "$SUSHI" themes 2>&1 \
       | sed "s/${esc}\[[0-9;]*m//g" | grep only)"
assert_has "the active theme is marked" "active" "$out"
out="$(HOME="$H" "$SUSHI" themes 2>&1 | sed "s/${esc}\[[0-9;]*m//g" | grep ' sushi')"
assert_has "and the built-in counts as active" "active" "$out"

# precedence is shown, not just applied: a name found twice is called shadowed
cp "$TH/only.yaml" "$H/.config/sushi/themes/only.yaml"
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" "$SUSHI" themes 2>&1 | sed "s/${esc}\[[0-9;]*m//g")"
assert_has "a shadowed duplicate says so"      "shadowed by" "$out"
assert_eq  "and the name is still offered once" "1" \
           "$(HOME="$H" SUSHI_THEME_DIR="$TH" "$SUSHI" __themes | grep -c '^only$' | tr -d ' ')"
rm -rf "$H/.config/sushi/themes"
out="$(HOME="$H" "$SUSHI" themes 2>&1 | sed "s/${esc}\[[0-9;]*m//g")"
assert_has "the user theme dir is listed even when missing" ".config/sushi/themes" "$out"
assert_has "and marked empty, so you know to put a file there" "(empty)" "$out"
assert_has "try-without-keeping it uses sushi, not ssh" "SUSHI_THEME=<name> sushi" "$out"
assert_lacks "because SUSHI_THEME=… ssh is a no-op in key,enter mode" \
             "SUSHI_THEME=<name> ssh" "$out"

# --------------------------------------------------------------------------
# `sushi theme set`

RC="$WORK/rc"
rcset() { HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_RC="$RC" "$SUSHI" theme set "$@" 2>&1; }
newrc() {
  printf 'export KEEP=1\n%s\n: ${SUSHI_MODE:=key,enter}\nsource "/x/sushi.zsh"\n%s\n' \
      '# >>> sushi >>>' '# <<< sushi <<<' > "$RC"
}

newrc
out="$(rcset ansi)"
assert_has "theme set says what it wrote"   "SUSHI_THEME=ansi" "$out"
assert_has "and where the backup went"      "rc.sushi-backup"  "$out"
assert_has "and how to pick it up now"      "source"           "$out"
assert_has "export SUSHI_THEME lands in the rc" "export SUSHI_THEME=ansi" "$(cat "$RC")"
assert_has "the rest of the file survives"      "export KEEP=1"           "$(cat "$RC")"
assert_has "so does the install.sh block"       ": \${SUSHI_MODE:=key,enter}" "$(cat "$RC")"

# the line has to sit ABOVE install.sh's block: install.sh rewrites everything
# between its own markers, so a theme set inside it would vanish on re-install
theme_at="$(grep -n 'export SUSHI_THEME=' "$RC" | cut -d: -f1)"
block_at="$(grep -n '# >>> sushi >>>' "$RC" | cut -d: -f1)"
assert_eq "the theme line is outside install.sh's block" "yes" \
          "$([ "$theme_at" -lt "$block_at" ] && echo yes || echo no)"

# and prove it: re-running install.sh must not take the theme with it
IH2="$(newhome rcinstall)"; cp "$RC" "$IH2/.zshrc"
HOME="$IH2" "$ROOT/install.sh" >/dev/null 2>&1
assert_has "install.sh leaves the theme line alone" "export SUSHI_THEME=ansi" "$(cat "$IH2/.zshrc")"
assert_eq  "and there is still exactly one of it" "1" \
           "$(grep -c 'export SUSHI_THEME=' "$IH2/.zshrc" | tr -d ' ')"
HOME="$IH2" "$ROOT/install.sh" --uninstall >/dev/null 2>&1
assert_lacks "uninstall removes the theme block too" "SUSHI_THEME" "$(cat "$IH2/.zshrc")"
assert_lacks "and every other sushi marker" "sushi" "$(cat "$IH2/.zshrc")"
assert_has   "without taking the rest of the file" "export KEEP=1" "$(cat "$IH2/.zshrc")"

# idempotent, like every other write in this project
rcset ansi >/dev/null; rcset only >/dev/null
assert_eq "setting it twice leaves one line" "1" \
          "$(grep -c 'export SUSHI_THEME=' "$RC" | tr -d ' ')"
assert_eq "and it is the last one set" "export SUSHI_THEME=only" \
          "$(grep 'export SUSHI_THEME=' "$RC")"
assert_eq "with one marker block, not two" "1" \
          "$(grep -c '>>> sushi theme >>>' "$RC" | tr -d ' ')"

# a hand-written assignment elsewhere in the file would fight ours, silently
newrc; printf 'export SUSHI_THEME=handwritten\n' >> "$RC"
out="$(rcset ansi)"
assert_has "a hand-written SUSHI_THEME is reported" "replacing an existing" "$out"
assert_eq  "and removed, so only one wins" "1" \
           "$(grep -c 'export SUSHI_THEME=' "$RC" | tr -d ' ')"

# `set sushi` means "the built-in", which is what no line at all means
rcset sushi >/dev/null
assert_lacks "set sushi removes the line rather than writing a redundant one" \
             "SUSHI_THEME" "$(cat "$RC")"
assert_has   "and the file is otherwise intact" "export KEEP=1" "$(cat "$RC")"

# none is a real choice and has to be storable
rcset none >/dev/null
assert_has "set none is written like any other" "export SUSHI_THEME=none" "$(cat "$RC")"

# a path is stored absolute, so it still resolves from another directory
newrc; rcset "$TH/only.yaml" >/dev/null
assert_has "a path is stored as an absolute path" "export SUSHI_THEME=$TH/only.yaml" "$(cat "$RC")"

# refuse to persist something that will not resolve tomorrow
newrc
out="$(rcset nosuchtheme)"
assert_has  "an unknown name is refused"      "no theme named" "$out"
assert_lacks "and nothing is written"         "SUSHI_THEME"    "$(cat "$RC")"
out="$(rcset "$TH/missing.yaml")"
assert_has  "an unreadable file is refused"   "cannot read"    "$out"
assert_lacks "and still nothing is written"   "SUSHI_THEME"    "$(cat "$RC")"

# no rc file yet is not an error — that is a fresh machine
rm -f "$RC"
rcset ansi >/dev/null
assert_has "a missing rc file is created" "export SUSHI_THEME=ansi" "$(cat "$RC")"

# the picker's preview pane has to render without a terminal or fzf
out="$(HOME="$H" SUSHI_THEME_DIR="$TH" SUSHI_THEME=only "$SUSHI" __themepreview 2>&1)"
assert_has "the preview names the theme"        "only"   "$out"
assert_has "and shows the roles"                "accent" "$out"
assert_has "and real rows to judge it by"       "alpha"  "$out"
assert_lacks "with the hidden record column cut" "$(printf '\t')" "$out"

# --------------------------------------------------------------------------
# SUSHI_THEME=none still wins over everything, including a file that exists
out="$(HOME="$H" SUSHI_THEME=none "$SUSHI" theme 2>&1)"
assert_lacks "SUSHI_THEME=none emits no escapes from theme" "${esc}[" "$out"

# --------------------------------------------------------------------------
section "empty state"

H="$(newhome empty)"
out="$(run "$H" list)"
assert_has "list explains what to do next" "run: sushi scan" "$out"
out="$(run "$H" help)"
assert_has "help lists the scan command" "sushi scan" "$out"

# --------------------------------------------------------------------------
section "zsh integration"

if command -v zsh >/dev/null 2>&1; then
  H="$(newhome zsh)"
  printf 'Host zhost\n    HostName z.example.com\n' > "$H/.ssh/config"
  Z="$ROOT/sushi.zsh"

  # zprobe <mode> <zsh snippet> -> last line of output
  # SAVEHIST=0: macOS ships an /etc/zshrc that sets HISTFILE, so every probe
  # would otherwise append its own commands to the fake home's .zsh_history —
  # including the "ssh myhost" that _sushi_dispatch pushes with `print -s`, which
  # then showed up as a scan candidate and broke unrelated assertions.
  zprobe() {
    HOME="$H" SHELL_SESSIONS_DISABLE=1 \
      zsh -ic "SAVEHIST=0; SUSHI_MODE='$1'; source '$Z'; $2" 2>&1 | tail -1
  }

  assert_eq "engine is found next to sushi.zsh"  "$SUSHI" "$(zprobe key 'echo $SUSHI_BIN')"
  assert_has "sushi works as a shell function, off PATH" "zhost" "$(zprobe key 'sushi list')"

  out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; source '$Z'; echo \$SUSHI_MODE" 2>&1 | tail -1)"
  assert_eq "default mode does not shadow ssh" "key,enter" "$out"

  out="$(HOME="$H" zsh -c "SUSHI_MODE=wrap; source '$Z'; whence -w ssh" 2>&1 | tail -1)"
  assert_eq "non-interactive zsh never loads the integration" "ssh: command" "$out"

  section "zsh integration: handing the host back to the shell"

  # A terminal with native SSH integration (Warp) only recognises a session if
  # the shell runs a literal `ssh <host>` command line. So by default the picked
  # host is pushed onto the next prompt with `print -z`, and the shell function
  # must NOT connect on its own.
  STUB="$WORK/stubbin"
  mkdir -p "$STUB"
  printf '#!/bin/sh\necho "STUBSSH $*"\n' > "$STUB/ssh"
  chmod +x "$STUB/ssh"

  out="$(HOME="$H" PATH="$STUB:$PATH" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SAVEHIST=0; source '$Z'; _sushi_dispatch myhost" 2>&1)"
  assert_lacks "by default the function does not connect itself" "STUBSSH" "$out"

  out="$(HOME="$H" PATH="$STUB:$PATH" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SUSHI_EXEC=1; source '$Z'; _sushi_dispatch myhost" 2>&1)"
  assert_has "SUSHI_EXEC=1 connects immediately instead" "STUBSSH myhost" "$out"

  out="$(HOME="$H" PATH="$STUB:$PATH" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SAVEHIST=0; source '$Z'; _sushi_dispatch ''" 2>&1)"
  assert_lacks "an empty pick is a no-op" "STUBSSH" "$out"

  assert_eq "SUSHI_EXEC defaults to off" "0" "$(zprobe key 'print $SUSHI_EXEC')"

  # EVERY subcommand the engine advertises must reach it through the wrapper
  # rather than being mistaken for a picker query. A hardcoded list in the
  # wrapper went stale when `ignore` was added; this walks the real list.
  for sub in $("$SUSHI" __subcommands); do
    case "$sub" in
      choose|edit) continue ;;   # choose blocks on fzf; edit spawns $EDITOR
    esac
    out="$(zprobe key "sushi $sub --help 2>&1 | head -2")"
    assert_lacks "sushi $sub is not treated as a picker query" "no hosts in" "$out"
  done

  assert_has "sushi list reaches the engine"  "zhost"       "$(zprobe key 'sushi list')"
  assert_has "sushi help reaches the engine"  "fuzzy SSH"   "$(zprobe key 'sushi help 2>&1 | head -1')"
  assert_has "sushi scan -n reaches the engine" "Nothing new found" \
             "$(zprobe key 'sushi scan -n 2>&1 | tail -1')"
  assert_has "sushi ignore --list reaches the engine" "Nothing ignored yet" \
             "$(zprobe key 'sushi ignore --list 2>&1 | head -1')"
  # a bare unknown word must go to the picker, not be taken for a subcommand
  # (empty config, so the picker bails before it would reach for fzf)
  out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SUSHI_MODE=key; export SUSHI_CONFIG=$WORK/none.conf; source '$Z'
    sushi somethingunmatched 2>&1 | head -1" 2>&1 | tail -1)"
  assert_has "a bare unknown word is still a picker query" "no hosts in" "$out"
  assert_has "the dispatcher exists even in off mode" "0" "$(zprobe off 'print $SUSHI_EXEC')"

  section "zsh integration: completion"

  # `_sushi` is defined inline and registered with compdef rather than shipped as
  # a file in fpath, because install.sh appends its source line to the END of
  # ~/.zshrc — after compinit has already run, at which point a new fpath entry
  # is never scanned. These assertions are what keep that decision honest.
  ZCD="$WORK/zcompdump"
  # zcprobe <mode> <snippet> -> last line, with the completion system loaded
  zcprobe() {
    HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0
      autoload -Uz compinit; compinit -u -d '$ZCD' 2>/dev/null
      SUSHI_MODE='$1'; source '$Z'; $2" 2>&1 | tail -1
  }

  assert_eq "compdef registers _sushi for sushi" "_sushi" "$(zcprobe key 'print $_comps[sushi]')"
  assert_eq "and the function exists"            "1"      "$(zcprobe key 'print ${+functions[_sushi]}')"
  assert_eq "so does the host helper"            "1"      "$(zcprobe key 'print ${+functions[_sushi_aliases]}')"
  assert_eq "and the theme helper"               "1"      "$(zcprobe key 'print ${+functions[_sushi_themes]}')"
  # completion for theme names reads them from the engine, so a file dropped in
  # ~/.config/sushi/themes is completable without touching sushi.zsh
  assert_has "theme names come from the engine" "ansi" \
             "$(zcprobe key '"$SUSHI_BIN" __themes | tr "\n" " "')"

  # off mode means "no key bindings, do not touch ssh" — not "a worse `sushi`"
  assert_eq "off mode still gets completion" "_sushi" "$(zcprobe off 'print $_comps[sushi]')"

  # ssh keeps zsh's own completion: sushi writes real Host stanzas, so _ssh
  # already knows every imported alias. Overriding it would be a regression.
  out="$(zcprobe key 'print $_comps[ssh]')"
  assert_lacks "ssh completion is left to zsh" "_sushi" "$out"

  # without compinit there is no compdef, and loading must stay silent
  out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0
    unfunction compdef 2>/dev/null
    source '$Z' && print LOADED" 2>&1 | tail -1)"
  assert_eq "no compinit is not an error" "LOADED" "$out"

  # the completion reads aliases from the engine, so that has to work
  assert_has "the engine lists aliases for completion" "zhost" "$(run "$H" __aliases)"

  section "zsh integration: mode key"
  assert_eq "leaves ssh a real command"  "ssh: command"       "$(zprobe key 'whence -w ssh')"
  assert_has "binds the key"             "sushi-insert-host"  "$(zprobe key "bindkey '^S'")"
  assert_lacks "does not touch accept-line" "sushi-accept-line" "$(zprobe key 'zle -l | grep accept-line')"
  out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SUSHI_MODE=key; SUSHI_KEY='^G'; source '$Z'; bindkey '^G'" 2>&1 | tail -1)"
  assert_has "honours a custom SUSHI_KEY" "sushi-insert-host" "$out"

  section "zsh integration: mode enter"
  assert_eq "leaves ssh a real command"  "ssh: command"  "$(zprobe enter 'whence -w ssh')"
  assert_has "binds the RETURN key"      "sushi-accept-line" "$(zprobe enter "bindkey '^M'")"
  assert_lacks "does not bind ^S"        "sushi-insert-host" "$(zprobe enter "bindkey '^S'")"
  out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SUSHI_MODE=enter; SUSHI_RETURN='^J'; source '$Z'; bindkey '^J'" 2>&1 | tail -1)"
  assert_has "honours a custom SUSHI_RETURN" "sushi-accept-line" "$out"

  # It must NOT take ownership of the accept-line widget: zsh-autosuggestions,
  # zsh-syntax-highlighting and terminal integrations all wrap it, `zle -N
  # accept-line` destroys whoever held it, and the loser depends on load order.
  assert_lacks "never takes over the accept-line widget" "sushi" \
               "$(zprobe enter 'print -r -- $widgets[accept-line]')"

  section "zsh integration: coexistence with widget-wrapping plugins"

  # a stand-in for how zsh-autosuggestions wraps widgets
  FAKE="$WORK/fakesuggest.zsh"
  cat > "$FAKE" <<'PLUGIN'
_fakesuggest_bound_accept-line() {
  if [[ -n ${widgets[fakesuggest-orig-accept-line]-} ]]; then
    zle fakesuggest-orig-accept-line
  else
    zle .accept-line
  fi
}
case ${widgets[accept-line]-} in
  user:*) zle -A accept-line fakesuggest-orig-accept-line ;;
esac
zle -N accept-line _fakesuggest_bound_accept-line
PLUGIN

  for ord in "'$Z' '$FAKE'" "'$FAKE' '$Z'"; do
    label="$([ "${ord#\'$Z\'}" != "$ord" ] && echo "sushi first" || echo "plugin first")"
    out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SUSHI_MODE=enter; source ${ord% *}; source ${ord#* }
      print -r -- \"W=\$widgets[accept-line] K=\$(bindkey '^M')\"" 2>&1 | tail -1)"
    assert_has "$label: the plugin keeps accept-line" "_fakesuggest_bound_accept-line" "$out"
    assert_has "$label: sushi still owns RETURN"      "sushi-accept-line"              "$out"
  done

  # Re-sourcing must be a no-op. `source ~/.zshrc` to reload is the documented
  # advice for terminals where `exec zsh` throws away their shell integration,
  # so sourcing twice — with a widget-wrapping plugin in between — has to be safe.
  out="$(HOME="$H" SHELL_SESSIONS_DISABLE=1 zsh -ic "SAVEHIST=0; SUSHI_MODE=key,enter
    source '$Z'; source '$FAKE'; source '$Z'; source '$Z'
    print -r -- \"W=\$widgets[accept-line] M=\$(bindkey '^M') S=\$(bindkey '^S')\"" 2>&1 | tail -1)"
  assert_has   "re-sourcing leaves accept-line with the plugin" "_fakesuggest_bound_accept-line" "$out"
  assert_has   "re-sourcing keeps RETURN bound once"            "sushi-accept-line" "$out"
  assert_has   "re-sourcing keeps ^S bound"                     "sushi-insert-host" "$out"
  assert_lacks "re-sourcing does not chain sushi onto itself"   "sushi-accept-line sushi" "$out"

  section "zsh integration: mode wrap"
  assert_eq "shadows ssh with a function" "ssh: function" "$(zprobe wrap 'whence -w ssh')"
  assert_has "ssh with arguments still reaches the real binary" "OpenSSH" "$(zprobe wrap 'ssh -V')"
  assert_lacks "does not bind a key"      "sushi-insert-host" "$(zprobe wrap "bindkey '^S'")"

  section "zsh integration: mode off / invalid"
  assert_eq "off leaves ssh alone"        "ssh: command"      "$(zprobe off 'whence -w ssh')"
  assert_lacks "off binds nothing"        "sushi-insert-host" "$(zprobe off "bindkey '^S'")"
  assert_has "off still provides the sushi function" "zhost"  "$(zprobe off 'sushi list')"
  assert_has "an unrecognised mode warns" "matched nothing"   "$(zprobe bogus 'true')"

  section "zsh integration: combined modes"
  assert_has "key,enter binds ^S"           "sushi-insert-host" "$(zprobe key,enter "bindkey '^S'")"
  assert_has "key,enter binds RETURN"       "sushi-accept-line" "$(zprobe key,enter "bindkey '^M'")"
  assert_eq  "key,enter leaves ssh a real command" "ssh: command" "$(zprobe key,enter 'whence -w ssh')"
else
  skip "zsh integration" "zsh not installed"
fi

# --------------------------------------------------------------------------
section "install.sh"

IH="$WORK/installhome"
rm -rf "$IH"; mkdir -p "$IH/.ssh"
printf '# pre-existing\nexport KEEP=1\n' > "$IH/.zshrc"

HOME="$IH" SHELL=/bin/zsh "$ROOT/install.sh" >/dev/null 2>&1
zshrc="$(cat "$IH/.zshrc")"
assert_has "keeps pre-existing .zshrc content" "export KEEP=1" "$zshrc"
assert_has "writes the mode explicitly"        "SUSHI_MODE:=key,enter" "$zshrc"
assert_has "sources the integration"           "sushi.zsh" "$zshrc"

HOME="$IH" SHELL=/bin/zsh "$ROOT/install.sh" >/dev/null 2>&1
n="$(grep -c 'sushi.zsh' "$IH/.zshrc")"
assert_eq "re-running does not duplicate the block" "1" "$n"

HOME="$IH" SHELL=/bin/zsh "$ROOT/install.sh" --mode=wrap >/dev/null 2>&1
assert_has "switching mode rewrites the block" "SUSHI_MODE:=wrap" "$(cat "$IH/.zshrc")"
n="$(grep -c 'sushi.zsh' "$IH/.zshrc")"
assert_eq "switching mode leaves one block" "1" "$n"

HOME="$IH" SHELL=/bin/zsh "$ROOT/install.sh" --key='^G' >/dev/null 2>&1
assert_has "honours --key" "SUSHI_KEY:='^G'" "$(cat "$IH/.zshrc")"

# the written block must not clobber an exported value, so that
# `SUSHI_MODE=off zsh -i` gives you a throwaway shell with sushi disabled
if command -v zsh >/dev/null 2>&1; then
  HOME="$IH" SHELL=/bin/zsh "$ROOT/install.sh" --mode=enter >/dev/null 2>&1
  out="$(HOME="$IH" SHELL_SESSIONS_DISABLE=1 zsh -ic 'SAVEHIST=0; print $SUSHI_MODE' 2>/dev/null | tail -1)"
  assert_eq "the .zshrc block applies its mode"  "enter" "$out"
  out="$(HOME="$IH" SUSHI_MODE=off SHELL_SESSIONS_DISABLE=1 zsh -ic 'SAVEHIST=0; SAVEHIST=0; print $SUSHI_MODE' 2>/dev/null | tail -1)"
  assert_eq "an exported SUSHI_MODE overrides it" "off" "$out"
  out="$(HOME="$IH" SUSHI_MODE=wrap SHELL_SESSIONS_DISABLE=1 zsh -ic 'SAVEHIST=0; whence -w ssh' 2>/dev/null | tail -1)"
  assert_eq "and the override actually takes effect" "ssh: function" "$out"
fi

if HOME="$IH" "$ROOT/install.sh" --mode=nonsense >/dev/null 2>&1; then
  no "an unrecognised --mode exits non-zero"
else
  ok "an unrecognised --mode exits non-zero"
fi

out="$(HOME="$IH" SHELL=/bin/zsh TERM_PROGRAM=WarpTerminal "$ROOT/install.sh" --mode=wrap 2>&1)"
assert_has "warns that wrap breaks Warp's completion" "shadows the ssh" "$out"
out="$(HOME="$IH" SHELL=/bin/zsh TERM_PROGRAM=WarpTerminal "$ROOT/install.sh" --mode=enter 2>&1)"
assert_lacks "stays quiet about Warp in enter mode" "shadows the ssh" "$out"

# A missing fzf must produce advice that is right for THIS machine, and must
# never block a non-interactive run (CI pipes install.sh its stdin from nowhere).
#
# fzf_install_cmd is exercised on its own, with a PATH holding nothing but the
# stub under test. Running it through the whole script instead would measure the
# runner's distro, not the function: /usr/bin/apt-get is real on the Linux job, so
# the "no package manager" case found one and every other case matched apt before
# reaching its own stub.
#
# Sourced into a subshell rather than exec'd, so no PATH lookup is needed for the
# shell itself — `command -v` and `printf` are builtins, which is the whole
# dependency surface of the function.
FAKEBIN="$WORK/fakebin"
FZFFN="$WORK/fzf_install_cmd.sh"
mkdir -p "$FAKEBIN"
{
  printf 'have() { command -v "$1" >/dev/null 2>&1; }\n'
  sed -n '/^fzf_install_cmd()/,/^}/p' "$ROOT/lib/util.sh"
  printf 'fzf_install_cmd\n'
} > "$FZFFN"

# One wrapper so the shellcheck directive is written once. The path is built two
# lines up; there is nothing for shellcheck to follow.
# shellcheck disable=SC1090
fzf_hint_with() { ( PATH="$1"; . "$FZFFN" ); }

# stub -> the exact command it must produce
while IFS='|' read -r pm want; do
  [ -n "$pm" ] || continue
  rm -f "${FAKEBIN:?}"/*
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$pm"; chmod +x "$FAKEBIN/$pm"
  assert_eq "the fzf hint for $pm" "$want" "$(fzf_hint_with "$FAKEBIN")"
done <<'EOF'
brew|brew install fzf
apt-get|sudo apt install fzf
dnf|sudo dnf install fzf
yum|sudo yum install fzf
pacman|sudo pacman -S fzf
zypper|sudo zypper install fzf
apk|sudo apk add fzf
port|sudo port install fzf
pkg|sudo pkg install fzf
nix-env|nix-env -iA nixpkgs.fzf
EOF

# brew wins when both are there: someone with brew on Linux wants brew
rm -f "${FAKEBIN:?}"/*
for pm in brew apt-get; do
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$pm"; chmod +x "$FAKEBIN/$pm"
done
assert_eq "brew takes precedence over apt" "brew install fzf" "$(fzf_hint_with "$FAKEBIN")"

rm -f "${FAKEBIN:?}"/*
assert_has "with no package manager it points at the project" \
           "github.com/junegunn/fzf" "$(fzf_hint_with "$FAKEBIN")"

# and the engine's own hint is one line, whatever it says
hint="$("$SUSHI" __fzfhint)"
assert_eq "the engine's hint is a single line" "1" "$(printf '%s\n' "$hint" | wc -l | tr -d ' ')"
assert_has "and mentions fzf"                  "fzf" "$hint"

printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/apt-get"; chmod +x "$FAKEBIN/apt-get"

# install.sh, non-interactive, no fzf on PATH: warns with the right command and
# exits on its own rather than waiting on a prompt nobody can answer
insout="$WORK/insout"
( HOME="$IH" SHELL=/bin/zsh PATH="$FAKEBIN:/usr/bin:/bin" "$ROOT/install.sh" \
    >"$insout" 2>&1 </dev/null ) & inspid=$!
i=0
while kill -0 "$inspid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$inspid" 2>/dev/null; then
  kill -9 "$inspid" 2>/dev/null; wait "$inspid" 2>/dev/null
  no "install.sh does not block on the fzf prompt without a terminal"
else
  wait "$inspid" 2>/dev/null
  ok "install.sh does not block on the fzf prompt without a terminal"
  assert_has "and names the platform's install command" "apt install fzf" "$(cat "$insout")"
  assert_lacks "not brew's"                             "brew"            "$(cat "$insout")"
fi

HOME="$IH" "$ROOT/install.sh" --uninstall >/dev/null 2>&1
zshrc="$(cat "$IH/.zshrc")"
assert_has   "uninstall keeps your content" "export KEEP=1" "$zshrc"
assert_lacks "uninstall removes everything sushi added" "sushi" "$zshrc"

# --------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  green "$PASS passed"; printf ', '; dim "$SKIP skipped"; printf '\n'
  exit 0
else
  red "$FAIL failed"; printf ', %s passed, ' "$PASS"; dim "$SKIP skipped"; printf '\n'
  exit 1
fi
