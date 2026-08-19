# sshui

![test](../../actions/workflows/test.yml/badge.svg)

A fuzzy picker for your SSH hosts that builds itself from your shell history — then gets out of the way.

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

sshui reads the history, extracts the destinations, and writes them into `~/.ssh/config` as real
`Host` stanzas. That last part is the point: **the output is native ssh config, not a private
database.** Once a host is imported, `ssh staging`, `scp file staging:`, `rsync … staging:`,
`git clone staging:repo` and `ssh <TAB>` completion all work — with or without sshui installed.
The picker is a convenience on top; the config is the deliverable.

## Install

```bash
git clone https://github.com/infuriating/sshui.git ~/sshui
cd ~/sshui
./install.sh
exec zsh
```

`install.sh` adds one `source` line to `~/.zshrc` and copies nothing, so `git pull` is a complete
update. `./install.sh --uninstall` removes it again.

Requires zsh, bash 3.2+ (macOS's system bash is fine) and [fzf](https://github.com/junegunn/fzf)
for the picker. `scan` and `list` work without fzf.

## Use

```bash
sshui scan -n     # dry run: what it found, sorted by how often you used it
sshui scan        # pick hosts with TAB, import them into ~/.ssh/config
ssh               # the picker
ssh staging       # untouched — goes straight to the real ssh
```

…where `ssh` on its own opens the picker in the default mode. Inside it: type to filter, `ENTER` to
connect, `ctrl-e` to edit `~/.ssh/config`, `ctrl-r` to rescan history.

Other commands: `sshui list` prints the host table, `sshui edit` opens the config,
`sshui choose` prints an alias instead of connecting (useful for your own scripts).

### Shell integration modes

How the picker is reached is configurable, because the obvious approach — defining a shell
function called `ssh` — has a real cost. Terminals that ship their own `ssh` completion (Warp, and
anything Fig-derived) key off the `ssh` command word, and shadowing it with a function turns that
completion off. So that mode exists, but it isn't the default.

| `SSHUI_MODE` | How you open the picker | Shadows `ssh`? |
| --- | --- | --- |
| `key` | a keybinding, `^S` by default | no |
| `enter` | press ENTER on a line containing only `ssh` | no |
| `wrap` | run `ssh` with no arguments | **yes** |
| `off` | only the `sshui` command | no |

Default is `key,enter` — combine any of them with commas.

`enter` is the interesting one: it rebinds zsh's `accept-line` widget, so a buffer of exactly `ssh`
gets rewritten to `ssh <picked-host>` a moment before it runs. You get the same "just type ssh"
feel as `wrap`, but `ssh` stays a real command, so native completion keeps working.

`key` inserts at the cursor rather than replacing the line, which makes it useful beyond ssh —
type `scp report.pdf ` then hit `^S` and you get the host appended. Set `SSHUI_KEY_ACCEPT=1` if
you'd rather it run immediately instead of leaving the line for you to edit.

```bash
./install.sh --mode=enter        # switch modes any time; rewrites the ~/.zshrc block
./install.sh --mode=key --key='^G'
./install.sh --mode=off
```

All modes load only in interactive shells, so scripts, cron jobs and anything calling
`/usr/bin/ssh` directly are unaffected. In every mode the command that actually runs is a real
`ssh <host>`, pushed into your shell history — so `↑` repeats it and the next `scan` sees it.

## Where the hosts come from

| Source | What it gives | Notes |
| --- | --- | --- |
| `~/.zsh_history`, `~/.bash_history`, `~/.zsh_sessions/*`, fish | user, host, port, **frequency** | the useful one |
| `~/.ssh/config` | existing aliases | read, never duplicated |
| `~/.ssh/known_hosts` | hostnames only | see below |

`known_hosts` is the source everyone reaches for first and it is the weakest of the three. It
stores host keys, so it has **no usernames at all**, and with `HashKnownHosts yes` — the default
on most systems — the hostnames are SHA-1 hashed and cannot be recovered. sshui offers the
unhashed entries with a commented-out `# User ?` line rather than guessing.

History parsing handles `-p`, `-l`, `-i`, `-o`, `-J` and friends, options before *or* after the
destination (`ssh host -p 2222` is valid OpenSSH), `ssh://user@host:port` URLs, quoting, and
`sudo`/`&&`/`;` prefixes. It ignores `scp`, `ssh-keygen`, commented-out lines and `ssh` appearing
inside a quoted string. Two entries for the same `user@host` — one with an explicit port, one
without — collapse into a single host.

## What it does to `~/.ssh/config`

Everything sshui writes goes inside a marked block:

```
# >>> sshui managed hosts >>>
...
# <<< sshui managed hosts <<<
```

- **The block goes at the top of the file.** In `ssh_config` the *first* value found for a keyword
  wins, so a `Host *` block above it would silently override every `User` and `Port` sshui wrote.
- **Your content is never touched.** Hand-written stanzas, comments and `Include` directives are
  preserved verbatim, including edits you make inside the managed block.
- **A backup is written on every change** (`config.sshui-backup-<timestamp>`, last five kept).
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
- The shell integration is zsh-only. bash and fish users can still use `sshui` as a command.
- `SSHUI_MODE=wrap` disables terminal-native `ssh` completion, as described above. Use `enter`.
- `^S` is XOFF under legacy terminal flow control; `key` mode runs `stty -ixon` when that is the
  chosen key. Pass `--key='^G'` if you'd rather it left your tty settings alone.
- Generated aliases are a best guess (first DNS label, or `srv-10-0-0-5` for an IP). Rename them —
  edits inside the managed block survive.

## Tests

```bash
./test/run.sh        # 110-odd assertions, no fzf or terminal needed
./test/run.sh -v     # show every assertion
```

The suite builds throwaway `$HOME`s and `.zshrc`s and checks the awkward parts: odd history lines,
glob safety, port collapsing, hashed `known_hosts`, alias collisions, managed-block ordering,
idempotency, refusal to write an unparseable config, what each `SSHUI_MODE` does and does not
touch, and `install.sh` being idempotent and fully reversible. CI runs it on Linux and macOS — the
macOS job exercises bash 3.2, which is what ships with the OS.

## Licence

MIT — see [LICENSE](LICENSE).
