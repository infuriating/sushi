# Contributing

Bug reports and patches welcome. The project is deliberately small: two files of shell, no
dependencies beyond fzf, no build step.

## Before opening a PR

```bash
./test/run.sh
shellcheck -S warning sushi install.sh test/run.sh
```

Both must be clean. CI runs the same two things on Linux and macOS.

## Ground rules

**Portability.** macOS ships bash 3.2 and BSD userland. That rules out `mapfile`, `declare -A`,
`${var,,}`, `sed -i` without an argument, GNU-only flags, and `\x` escapes in `awk`.

macOS's `/usr/bin/awk` is onetrueawk, not gawk, and two of its limits have bitten this project:

- **`awk -v` cannot take a value containing a newline.** It fails with "newline in string" and the
  program never runs — so you get empty output, not an error you'd notice. Never pass a multi-line
  list through `-v`: stream it in on stdin behind a marker line, or read it from a file in `BEGIN`
  with `getline < file`.
- **POSIX character classes** like `[[:space:]]` are unsupported in older builds. Use `[ \t]` in awk
  programs. (`sed` and bash `[[ =~ ]]` are fine with them on both platforms.)

`apt-get install original-awk` gets you the same implementation, and the suite runs the
awk-sensitive paths against it when present — so the Linux job catches this class of bug. The macOS
job is still the final word on bash 3.2 and BSD tools.

**Keep the tests hermetic.** The zsh probes run with `SAVEHIST=0` and `SHELL_SESSIONS_DISABLE=1`.
Without them, macOS's `/etc/zshrc` writes each probe's commands into the fake `$HOME`'s
`.zsh_history` and `.zsh_sessions/*.history` — both of which sushi scans — so probes contaminated
each other's fixtures. `_sushi_dispatch` in particular pushes `ssh <host>` into the shell history by
design, which then reappeared as a scan candidate.

**Never lose the user's config.** Any change to the write path has to keep these properties, each
of which has a test:

- writes go inside the `# >>> sushi managed hosts >>>` markers, at the top of the file
- everything outside the markers is preserved byte-for-byte
- a timestamped backup is taken before writing
- the result is validated with `ssh -G` and discarded if it fails
- `~/.ssh` stays `700`, the config stays `600`
- deletion only ever removes stanzas from inside the markers

Everything that rewrites the config goes through `commit_managed`, which takes the whole new block
body and handles backup, blank-line collapsing, validation and permissions. `install_block` (append)
and `remove_managed_aliases` (delete) are thin wrappers over it. Add a third operation the same way
rather than writing to `$CONFIG` directly.

**Watch out for per-line and per-item forks.** Every performance problem this project has had was
the same shape: a subprocess inside a loop.

- `flatten_config` ran `printf | tr` on every line of the ssh config to lowercase it for one glob
  test. Two forks a line made `config_hosts` cost ~500ms on a 170-line config — and `config_hosts`
  is called by nearly everything, including every preview redraw. A `case` with `[Ii][Nn]...`
  bracket globs does the same job with no fork.
- `cmd_ignore` called `config_hosts` once per managed alias to resolve its target. Forty imported
  hosts meant forty full config parses: **19 seconds** before the menu appeared. It is one awk over
  two marker-separated streams now.
- `scan_history` looped in bash over every line of every history file. Pure builtins, but still
  ~90us a line. A `grep -hF ssh` in front means the loop only sees candidate lines.

The pattern to reach for when you need two datasets in one awk: concatenate the streams with a
marker line between them and switch on it in the program. Passing one of them through `awk -v`
instead breaks on macOS as soon as it contains a newline (see above).

Benchmark with the internal subcommands before and after:

```bash
time ./sushi __candidates    # history parse
time ./sushi __lines         # main picker rows
time ./sushi __preview host  # one preview redraw
time ./sushi __scanmenu      # scan picker rows
time ./sushi __ignoremenu    # ignore picker rows
```

**Keep the scan picker's redraw cheap.** `ctrl-x` fires a reload on every keypress, so anything on
that path runs tens of times a second in practice. It reads a pre-built cache (`SUSHI_SCAN_CACHE`)
and a pending-dismissals file (`SUSHI_SCAN_PENDING`); it must not touch the history, the ssh config
or the ignore file. Two things that mattered when this was ~900ms a press: `is_ignored` re-read the
ignore file for every candidate, and the config filter used `tr` plus `grep -Fxq` per candidate —
about six forks a row. Both are now one-shot. Before adding work there, benchmark it:

```bash
SUSHI_SCAN_CACHE=/tmp/c SUSHI_SCAN_PENDING=/tmp/p ./sushi __menucache
```

**Mind the subshell.** `scan_candidates` is consumed via `done < <(...)`, so it runs in a child
process — a counter incremented inside it never reaches the caller. That bit us once with the
ignore-list tally. Filter and count in the caller's loop, where the body runs in the current shell.

**Add a test with the fix.** `test/run.sh` needs no fzf and no terminal — it builds throwaway
`$HOME`s and asserts on output. Copy the nearest existing section; the helpers are `assert_eq`,
`assert_has` and `assert_lacks`.

If you are fixing a parsing bug, the failing input belongs in the `history parsing` section as a
line in the fixture heredoc plus one assertion. That section is the most valuable part of the
suite — shell history is endlessly creative.

**Don't invent data.** If a source genuinely doesn't contain a username (hashed `known_hosts`, for
instance), emit a commented-out `# User ?` and let the user decide. Guessing is worse than
admitting the gap.

## Debugging

Three hidden subcommands dump intermediate state:

```bash
sushi __candidates       # raw history scan:  count|user|host|port
sushi __lines            # exactly what is piped into fzf
sushi __preview foo      # the preview pane for one alias
sushi __rmalias foo bar  # delete managed stanzas without the picker
sushi __scanmenu         # scan picker rows
sushi __ignoremenu       # ignore picker rows
sushi __subcommands      # what the zsh wrapper passes through
```

Point them at a fixture rather than your real history:

```bash
HOME=/tmp/fake ./sushi __candidates
```
