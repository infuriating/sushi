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

# import everything sushi finds, non-interactively
import_all() {
  local h="$1"
  printf 'w\n' | HOME="$h" SUSHI_ALL=1 "$SUSHI" scan 2>&1
}

# --------------------------------------------------------------------------
section "static checks"

if bash -n "$SUSHI" 2>/dev/null; then ok "sushi parses under bash"; else no "sushi parses under bash"; fi

if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$ROOT/sushi.zsh" 2>/dev/null; then ok "sushi.zsh parses under zsh"; else no "sushi.zsh parses under zsh"; fi
else
  skip "sushi.zsh parses under zsh" "zsh not installed"
fi

if command -v shellcheck >/dev/null 2>&1; then
  out="$(shellcheck -S warning "$SUSHI" 2>&1)"
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
order="$(run "$H" __lines | cut -f1 | sed 's/\x1b\[[0-9;]*m//g' | awk '{ print $1 }')"
assert_eq "most-used host first"  "zulu" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "then the next"         "mike" "$(printf '%s\n' "$order" | sed -n 2p)"
assert_eq "a bare \`ssh alias\` counts for that alias" "alpha" "$(printf '%s\n' "$order" | sed -n 3p)"
assert_eq "never-used hosts trail" "cold" "$(printf '%s\n' "$order" | sed -n 4p)"

order="$(HOME="$H" SUSHI_SORT=alpha "$SUSHI" __lines | cut -f1 | sed 's/\x1b\[[0-9;]*m//g' | awk '{ print $1 }')"
assert_eq "SUSHI_SORT=alpha is plain A-Z" "alpha" "$(printf '%s\n' "$order" | sed -n 1p)"
assert_eq "...second"                     "cold"  "$(printf '%s\n' "$order" | sed -n 2p)"

# no history: every host is unused, so A-Z
rm -f "$H/.zsh_history"
rm -rf "$XDG_CACHE_HOME"
order="$(run "$H" __lines | cut -f1 | sed 's/\x1b\[[0-9;]*m//g' | awk '{ print $1 }')"
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
