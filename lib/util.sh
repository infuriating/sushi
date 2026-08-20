# Every awk in this file runs in the C locale.
#
# onetrueawk — what macOS ships — aborts the whole program the moment an input
# byte sequence is not valid UTF-8 in the current locale:
#
#     awk: towc: multibyte conversion failure on: '...'
#
# and it does that mid-stream, so every record after the offending one is
# silently lost rather than the run visibly failing. A shell history collects
# bytes from everywhere — a truncated paste, a latin-1 filename, a stray 0xff —
# so that is not a rare input, it is an inevitable one. In the C locale awk
# treats input as bytes and cannot fail this way.
#
# Nothing is given up by it: every keyword awk matches here is ASCII, and hosts
# and aliases are ASCII by the time they reach any of these programs. The locale
# is set per-call rather than for the whole script on purpose — fzf draws the
# picker with box-drawing characters, and LC_ALL=C would turn those into noise.
AWK() { LC_ALL=C awk "$@"; }


# -------------------------------------------------------------------- clock --
#
# `added at` and `last used at` want a date and a rough age, and awk cannot give
# us one: strftime() is a gawk/mawk extension that onetrueawk does not have, and
# calling `date` per row is a fork per row on top of `date -r` (BSD) and
# `date -d` (GNU) disagreeing about how to print an epoch. So the calendar
# arithmetic lives here, and every awk program that needs it interpolates
# AWK_TIME and passes `now` / `tzoff` in through -v.
NOW=""
TZOFF=0
clock_now() {
  [ -n "$NOW" ] && return 0
  local z n
  NOW="$(date +%s 2>/dev/null)"
  case "$NOW" in ""|*[!0-9]*) NOW=0 ;; esac
  z="$(date +%z 2>/dev/null)"
  case "$z" in
    [+-][0-9][0-9][0-9][0-9])
      # 10# or bash reads "+0200" as octal and quietly lands two hours out
      n=$((10#${z#[+-]}))
      TZOFF=$((n / 100 * 3600 + n % 100 * 60))
      case "$z" in -*) TZOFF=$((0 - TZOFF)) ;; esac
      ;;
    *) TZOFF=0 ;;
  esac
  return 0
}

AWK_TIME='
# days since 1970-01-01, and back again (Hinnant, days_from_civil)
function dfc(y, m, d,   era, yoe, doy, doe) {
  y += (m <= 2 ? -1 : 0)
  era = int((y >= 0 ? y : y - 399) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function cfd(z,   era, doe, yoe, y, doy, mp, d, m) {
  z += 719468
  era = int((z >= 0 ? z : z - 146096) / 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = mp + (mp < 10 ? 3 : -9)
  return sprintf("%04d-%02d-%02d", y + (m <= 2 ? 1 : 0), m, d)
}
# "2026-08-14 09:41" (local) -> epoch. Anything else -> "".
function iso2epoch(s,   t) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return ""
  t = dfc(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400
  if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]/)
    t += substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60
  return t - tzoff
}
# epoch -> "2026-08-14 09:41", local
function when(t,   d, s) {
  if (t == "" || t + 0 <= 0) return ""
  t = int(t) + tzoff
  d = int(t / 86400); s = t - d * 86400
  return cfd(d) sprintf(" %02d:%02d", int(s / 3600), int((s % 3600) / 60))
}
# epoch -> "now" / "7m" / "2h" / "14d" / "3y" — never wider than four columns
function ago(t,   d) {
  if (t == "" || t + 0 <= 0) return "-"
  d = now - int(t)
  if (d < 60) return "now"
  if (d < 3600) return int(d / 60) "m"
  if (d < 86400) return int(d / 3600) "h"
  if (d < 31536000) return int(d / 86400) "d"
  return int(d / 31536000) "y"
}
# the parenthetical the preview hangs off a date — "3d ago", but "just now"
function since(t,   r) {
  r = ago(t)
  return (r == "now" ? "just now" : r " ago")
}
'

# ------------------------------------------------------------------ fzf check --

# How to install fzf on THIS machine. "brew install fzf" was hardcoded, which is
# useless advice on the majority of machines sushi runs on — and a wrong install
# command is worse than none, because it sends you looking for the wrong problem.
#
# Order matters: brew first, because someone who has brew on Linux wants brew.
fzf_install_cmd() {
  if   have brew;    then printf 'brew install fzf'
  elif have apt-get; then printf 'sudo apt install fzf'
  elif have dnf;     then printf 'sudo dnf install fzf'
  elif have yum;     then printf 'sudo yum install fzf'
  elif have pacman;  then printf 'sudo pacman -S fzf'
  elif have zypper;  then printf 'sudo zypper install fzf'
  elif have apk;     then printf 'sudo apk add fzf'
  elif have port;    then printf 'sudo port install fzf'
  elif have pkg;     then printf 'sudo pkg install fzf'
  elif have nix-env; then printf 'nix-env -iA nixpkgs.fzf'
  else printf 'see https://github.com/junegunn/fzf#installation'
  fi
}

# The one place that explains a missing fzf, so the wording and the install
# command cannot drift apart between call sites.
warn_no_fzf() {
  warn "fzf not found — the picker needs it."
  warn "    $(fzf_install_cmd)"
  warn "Meanwhile: 'sushi list' shows your hosts and 'sushi scan' still imports."
}
