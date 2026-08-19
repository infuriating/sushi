# Contributing

Bug reports and patches welcome. The project is deliberately small: two files of shell, no
dependencies beyond fzf, no build step.

## Before opening a PR

```bash
./test/run.sh
shellcheck -S warning sshui install.sh test/run.sh
```

Both must be clean. CI runs the same two things on Linux and macOS.

## Ground rules

**Portability.** macOS ships bash 3.2 and BSD userland. That rules out `mapfile`, `declare -A`,
`${var,,}`, `sed -i` without an argument, GNU-only flags, and `\x` escapes in `awk`. If you are
unsure, the macOS CI job will tell you.

**Never lose the user's config.** Any change to the write path has to keep these properties, each
of which has a test:

- writes go inside the `# >>> sshui managed hosts >>>` markers, at the top of the file
- everything outside the markers is preserved byte-for-byte
- a timestamped backup is taken before writing
- the result is validated with `ssh -G` and discarded if it fails
- `~/.ssh` stays `700`, the config stays `600`
- deletion only ever removes stanzas from inside the markers

Everything that rewrites the config goes through `commit_managed`, which takes the whole new block
body and handles backup, blank-line collapsing, validation and permissions. `install_block` (append)
and `remove_managed_aliases` (delete) are thin wrappers over it. Add a third operation the same way
rather than writing to `$CONFIG` directly.

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
sshui __candidates       # raw history scan:  count|user|host|port
sshui __lines            # exactly what is piped into fzf
sshui __preview foo      # the preview pane for one alias
sshui __rmalias foo bar  # delete managed stanzas without the picker
```

Point them at a fixture rather than your real history:

```bash
HOME=/tmp/fake ./sshui __candidates
```
