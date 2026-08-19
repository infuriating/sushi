# sushi

![test](../../actions/workflows/test.yml/badge.svg)

*ssh + ui, rearranged.* A fuzzy picker for your SSH hosts that builds itself from your shell
history — then gets out of the way.

```
ssh ⏎
```

```
  ssh ❯ stag                                    ┌──────────────────────────────────┐
  ENTER connect · ctrl-e edit · ctrl-r rescan   │   deploy@staging.example.com:2022 │
                                                │                                  │
> staging          deploy@staging.example.com…  │   resolved                       │
  db1              luca@db1.example.com         │     user           deploy        │
  prod-web         deploy@10.20.30.40:2222      │     hostname       staging.exa…  │
  bastion          luca@jump.example.com        │     port           2022          │
                                                │                                  │
                                                │   stanza in ~/.ssh/config        │
                                                │     Host staging                 │
                                                │         HostName staging.exam…   │
                                                │         User deploy              │
                                                │         Port 2022                │
                                                └──────────────────────────────────┘
```

## The idea

You have already told your machine about every server you use — you just told it in the wrong
place. `~/.zsh_history` is full of `ssh deploy@10.20.30.40 -p 2222`, typed for the hundredth time,
while `~/.ssh/config` sits empty.

sushi reads the history, extracts the destinations, and writes them into `~/.ssh/config` as real
`Host` stanzas. That last part is the point: **the output is native ssh config, not a private
database.** Once a host is imported, `ssh staging`, `scp file staging:`, `rsync … staging:`,
`git clone staging:repo` and `ssh <TAB>` completion all work — with or without sushi installed.
The picker is a convenience on top; the config is the deliverable.

## Install

```bash
git clone https://github.com/infuriating/sushi.git ~/sushi
cd ~/sushi
./install.sh
source ~/.zshrc
```

`install.sh` adds one `source` line to `~/.zshrc` and copies nothing, so `git pull` is a complete
update. `./install.sh --uninstall` removes it again.

Reload with `source ~/.zshrc`, not `exec zsh`. In Warp — or any terminal that injects shell
integration at launch — `exec zsh` replaces the shell the terminal set up, and that pane loses the
terminal's own features (native SSH blocks, completions) until you close it. A new tab or pane is
always safe. Re-sourcing sushi is idempotent, so reloading repeatedly costs nothing.

Requires zsh, bash 3.2+ (macOS's system bash is fine) and [fzf](https://github.com/junegunn/fzf)
for the picker. `scan` and `list` work without fzf.

## Use

```bash
sushi scan -n     # dry run: what it found, sorted by how often you used it
sushi scan        # pick hosts with TAB, import them into ~/.ssh/config
ssh               # the picker
ssh staging       # untouched — goes straight to the real ssh
```

…where `ssh` on its own opens the picker in the default mode. Inside it: type to filter, `ENTER` to
connect, `ctrl-e` to edit `~/.ssh/config`, `ctrl-r` to rescan history. In the `scan` picker, `ctrl-x` dismisses rows.

The picker is ordered by how often you actually reach each host, not
alphabetically — `bastion` being first because it starts with b is not useful. Hosts with no history
trail at the bottom, A-Z among themselves. `SUSHI_SORT=alpha` restores plain alphabetical.

Other commands: `sushi list` prints the host table, `sushi edit` opens the config,
`sushi choose` prints an alias instead of connecting (useful for your own scripts).

### Making things go away

Your history accumulates hosts you'll never use again — a box that's been decommissioned, a
colleague's machine you SSH'd into once, a whole staging environment. Without somewhere to record
that, `scan` re-offers them forever.

```bash
sushi delete              # pick things to get rid of  (alias: sushi ignore)
sushi ignore 'root@*'     # or add patterns directly
sushi ignore '*.staging.acme.tld'
sushi ignore --list
sushi ignore --remove     # picker; or pass patterns
sushi ignore --edit       # open the file in $EDITOR
```

You can also dismiss rows without leaving `scan`: highlight one (or `TAB` several) and press
**`ctrl-x`**. They vanish immediately and never come back. Nothing is imported and `~/.ssh/config`
isn't touched — it's purely "stop showing me this".

`ctrl-x` is deliberately cheap. The candidate list is scanned once into a temp cache when the picker
opens; a keypress only appends a pattern to a pending file, and the redraw re-reads the cache minus
that file. The ignore list itself is written once, after the picker closes, however many rows you
dismissed. Doing the obvious thing instead — write the ignore file, then reload by re-scanning —
cost ~900ms per keypress on a 3000-line history; this is ~30ms.

`sushi delete` is the standalone version. It only ever offers things you haven't dealt with —
anything already on the ignore list is left out, since re-offering it in the picker you dismissed it
from is just noise. Use `--list` and `--remove` to see and undo the list itself.

Its picker offers two kinds of entry:

- **`scan`** — a candidate that hasn't been imported. Selecting it adds a pattern to the ignore
  list so it's never offered again.
- **`imported`** — a host already in `~/.ssh/config`. Selecting it **deletes its `Host` stanza**
  *and* adds the ignore pattern. Deleting without ignoring would just mean the next `scan` offers it
  straight back.

Stanza deletion only ever touches the sushi-managed block, so hand-written entries are safe, and it
goes through the same backup-and-`ssh -G`-validate path as import. A `Host` line naming several
patterns loses only the ones you picked; it survives while any remain.

The ignore list lives at `~/.ssh/sushi-ignore` (`SUSHI_IGNORE` to move it) — one glob per line,
`#` for comments, matched against both `user@host` and the bare host. It affects `scan` only;
`~/.ssh/config` and the picker are never filtered by it. `scan` reports how many candidates it hid
rather than quietly shrinking its list.

### Look

The default theme is taken off the logo — cyan through violet to magenta, on the near-black of the
nori:

| | |
| --- | --- |
| `#22c7e8` cyan | match highlights, markers, key paths |
| `#8c6fe0` violet | headers, section labels, borders |
| `#ec4899` magenta | prompt, pointer, the `imported` tag |
| `#f472b6` rose | the resolved target in the preview |
| `#14101f` nori | — (the background is left transparent) |
| `#fdf7fb` rice | aliases and values |

The background is deliberately `-1`, so your terminal's own background and transparency show
through rather than being painted over.

Two escape hatches:

```bash
SUSHI_THEME=none            # no colours at all; FZF_DEFAULT_OPTS decides
SUSHI_FZF_OPTS='--height=40% --layout=default --preview-window=down,60%'
```

`SUSHI_FZF_OPTS` is appended after everything sushi passes, and fzf lets the later flag win, so it
overrides any of this — including the geometry the call sites set.

`sushi list` only colours itself when stdout is a terminal, so piping or capturing it gives you
clean text.

### Shell integration modes

How the picker is reached is configurable, because the obvious approach — defining a shell
function called `ssh` — has a real cost. Terminals that ship their own `ssh` completion (Warp, and
anything Fig-derived) key off the `ssh` command word, and shadowing it with a function turns that
completion off. So that mode exists, but it isn't the default.

| `SUSHI_MODE` | How you open the picker | Shadows `ssh`? |
| --- | --- | --- |
| `key` | a keybinding, `^S` by default | no |
| `enter` | press ENTER on a line containing only `ssh` | no |
| `wrap` | run `ssh` with no arguments | **yes** |
| `off` | only the `sushi` command | no |

Default is `key,enter` — combine any of them with commas.

`enter` is the interesting one: it binds the RETURN key, and if the buffer is exactly `ssh` it
rewrites it to `ssh <picked-host>` a moment before running. You get the same "just type ssh" feel
as `wrap`, but `ssh` stays a real command, so native completion keeps working.

It binds the *key* rather than redefining the `accept-line` *widget* on purpose. `accept-line` is
contested territory — zsh-autosuggestions wraps it (and re-wraps on every `precmd` by default),
zsh-syntax-highlighting wraps it, terminals add their own. `zle -N accept-line …` silently destroys
whoever held it, and which side loses depends on load order, so the same `.zshrc` ends up behaving
differently in different shells. Binding `^M` and then delegating with `zle accept-line` — by name,
not `.accept-line` — means sushi never owns the widget and every wrapper in the chain still runs.
Set `SUSHI_RETURN` if you need a different key.

`key` inserts at the cursor rather than replacing the line, which makes it useful beyond ssh —
type `scp report.pdf ` then hit `^S` and you get the host appended. Set `SUSHI_KEY_ACCEPT=1` if
you'd rather it run immediately instead of leaving the line for you to edit.

```bash
./install.sh --mode=enter        # switch modes any time; rewrites the ~/.zshrc block
./install.sh --mode=key --key='^G'
./install.sh --mode=off
```

All modes load only in interactive shells, so scripts, cron jobs and anything calling
`/usr/bin/ssh` directly are unaffected.

### Terminals with native SSH integration

Warp — and anything else that gives ssh sessions special treatment — recognises a session by the
**literal command line the shell runs**. A picker that connects on your behalf is invisible to it:
the terminal saw `sushi`, not `ssh`. You lose the session chip, the remote directory indicator, and
block-level integration.

So sushi never connects for you. Every mode ends with a real `ssh <host>` command line submitted
from your prompt:

- `key` inserts it into the line you're editing; you press ENTER
- `enter` rewrites the buffer to `ssh <host>` immediately before it runs
- bare `sushi` (and `sushi <query>`) pushes it onto your **next** prompt via zsh's `print -z`, so
  you press ENTER once more and the terminal sees a command you typed

That last ENTER is the price of native integration. If you'd rather skip it and connect straight
away, `SUSHI_EXEC=1` — with the understanding that Warp-style session detection then won't fire.

Either way the command lands in your shell history, so `↑` repeats it and the next `scan` sees it.

## Where the hosts come from

| Source | What it gives | Notes |
| --- | --- | --- |
| `~/.zsh_history`, `~/.bash_history`, `~/.zsh_sessions/*`, fish | user, host, port, **frequency** | the useful one |
| `~/.ssh/config` | existing aliases | read, never duplicated |
| `~/.ssh/known_hosts` | hostnames only | see below |
| `~/.ssh/sushi-ignore` | what to leave out | see [Making things go away](#making-things-go-away) |

`known_hosts` is the source everyone reaches for first and it is the weakest of the three. It
stores host keys, so it has **no usernames at all**, and with `HashKnownHosts yes` — the default
on most systems — the hostnames are SHA-1 hashed and cannot be recovered. sushi offers the
unhashed entries with a commented-out `# User ?` line rather than guessing.

`-i` and `-J` are not just skipped, they're kept: `ssh -i ~/.ssh/deploy_key -J bastion@edge web1`
imports as a stanza with `IdentityFile` and `ProxyJump` already filled in, so a host behind a
bastion or on a specific key works without hand-editing. Anything that isn't plainly a path or a
destination is dropped rather than written into your config — an unexpanded `$HOME`, a path with
spaces. In the `scan` list those rows are flagged `key` and `via <bastion>`.

History parsing handles `-p`, `-l`, `-i`, `-o`, `-J` and friends, options before *or* after the
destination (`ssh host -p 2222` is valid OpenSSH), `ssh://user@host:port` URLs, quoting, and
`sudo`/`&&`/`;` prefixes. It ignores `scp`, `ssh-keygen`, commented-out lines and `ssh` appearing
inside a quoted string. Two entries for the same `user@host` — one with an explicit port, one
without — collapse into a single host.

## What it does to `~/.ssh/config`

Everything sushi writes goes inside a marked block:

```
# >>> sushi managed hosts >>>
...
# <<< sushi managed hosts <<<
```

- **The block goes at the top of the file.** In `ssh_config` the *first* value found for a keyword
  wins, so a `Host *` block above it would silently override every `User` and `Port` sushi wrote.
- **Your content is never touched.** Hand-written stanzas, comments and `Include` directives are
  preserved verbatim, including edits you make inside the managed block.
- **A backup is written on every change** (`config.sushi-backup-<timestamp>`, last five kept).
- **The result is validated with `ssh -G` before it is committed.** If ssh cannot parse it, the
  original file is left byte-identical and the run aborts. Validation is skipped if your config
  already fails to parse, so a pre-existing problem can't lock you out.
- **Re-running is idempotent.** Hosts already covered by your config — by hostname+user or by
  alias — are not offered again.
- Modes are enforced: `700` on `~/.ssh`, `600` on the config.

## Limitations

- The destination has to appear literally in your history. Hosts you only ever reached through an
  alias, a `ProxyJump`, or a wrapper script won't be found.
- Bare IPv6 literals (`ssh 2001:db8::1`) are skipped — indistinguishable from `host:port` without
  guessing.
- The shell integration is zsh-only. bash and fish users can still use `sushi` as a command.
- `SUSHI_MODE=wrap` disables terminal-native `ssh` completion, as described above. Use `enter`.
- `^S` is XOFF under legacy terminal flow control; `key` mode runs `stty -ixon` when that is the
  chosen key. Pass `--key='^G'` if you'd rather it left your tty settings alone.
- Generated aliases are a best guess (first DNS label, or `srv-10-0-0-5` for an IP). Rename them —
  edits inside the managed block survive.
- On Linux, `gnome-sushi` also installs a `/usr/bin/sushi` (a file previewer). If you have it, one
  of the two wins on `$PATH`. macOS has no such clash.

## Tests

```bash
./test/run.sh        # ~190 assertions, no fzf or terminal needed
./test/run.sh -v     # show every assertion
```

The suite builds throwaway `$HOME`s and `.zshrc`s and checks the awkward parts: odd history lines,
glob safety, port collapsing, hashed `known_hosts`, alias collisions, managed-block ordering,
idempotency, refusal to write an unparseable config, what each `SUSHI_MODE` does and does not
touch, and `install.sh` being idempotent and fully reversible. CI runs it on Linux and macOS — the
macOS job exercises bash 3.2, which is what ships with the OS.

## Licence

MIT — see [LICENSE](LICENSE).
