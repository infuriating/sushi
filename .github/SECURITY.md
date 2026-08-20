# Security

sushi rewrites `~/.ssh/config` and can append a line to `~/.zshrc` (`theme set`). Treat bugs in
those write paths as security-sensitive even when they look like ordinary correctness issues.

## Report a vulnerability

**Do not open a public issue.**

Use [GitHub Security Advisories](https://github.com/infuriating/sushi/security/advisories/new)
for this repository. Include:

- what a malicious or malformed input can do (config corruption, unintended Host merge, etc.)
- a minimal reproducer (synthetic hosts are fine)
- sushi version / commit, OS, bash/zsh versions

## What we care about most

- writes outside the `# >>> sushi managed hosts >>>` markers, or loss of content outside them
- skipped backup / `ssh -G` validation before replacing the config
- permission regression on `~/.ssh` (`700`) or the config (`600`)
- anything that could inject unexpected ssh options from history or theme input

Out of scope: phishing via crafted Host aliases you chose to import, and the security of ssh itself.
