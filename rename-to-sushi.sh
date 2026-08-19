#!/usr/bin/env bash
# Completes the sshui -> sushi rename on this machine.
#   bash ~/sshui/rename-to-sushi.sh
#
# Does, in order: drop the old files from git, run the tests, commit, push,
# migrate your ~/.ssh/config and ~/.zshrc, then rename the directory itself.
set -euo pipefail

cd "$HOME/sshui"

# the exec bit does not survive the file transfer
chmod +x sushi install.sh test/run.sh

# The CI workflow could not be written remotely (GitHub Actions files are
# protected), so patch its three sshui references here. Only lowercase
# occurrences exist in it.
if [ -f .github/workflows/test.yml ] && grep -q sshui .github/workflows/test.yml; then
  sed -i '' 's/sshui/sushi/g' .github/workflows/test.yml 2>/dev/null \
    || sed -i 's/sshui/sushi/g' .github/workflows/test.yml
  echo "--- patched .github/workflows/test.yml ---"
  grep -n sushi .github/workflows/test.yml
  echo
fi

echo "--- dropping the old filenames from git ---"
git rm -q --ignore-unmatch sshui sshui.zsh
git add sushi sushi.zsh install.sh test/run.sh README.md CONTRIBUTING.md \
        .github/workflows/test.yml .gitignore

echo
echo "--- what will be committed ---"
git status --short
echo

echo "--- tests ---"
./test/run.sh | tail -2
echo

git commit -F - <<'MSG'
refactor!: rename sshui to sushi

ssh + ui, rearranged — and easier to say out loud.

BREAKING CHANGE: the command, both files, every environment variable and both
sets of config markers change name.

  sshui                 -> sushi
  sshui.zsh             -> sushi.zsh
  SSHUI_*               -> SUSHI_*
  ~/.ssh/sshui-ignore   -> ~/.ssh/sushi-ignore
  # >>> sshui managed hosts >>>  -> # >>> sushi managed hosts >>>
  # >>> sshui >>>  (in ~/.zshrc) -> # >>> sushi >>>

install.sh migrates an existing install rather than leaving it stranded. The
managed-host markers matter most: sushi would not recognise the old ones, would
treat that block as hand-written, and would add a second block — duplicating
every imported Host. So it rewrites the markers in place (after a
config.pre-sushi-rename backup), copies the ignore list to its new name, and
drops the stale sshui block from ~/.zshrc, which would otherwise source a file
that no longer exists on every shell start. --uninstall clears a pre-rename
block too. Thirteen tests cover the migration, including that it is idempotent
and that exactly one managed block survives.

Noted in the README: on Linux, gnome-sushi also ships a /usr/bin/sushi.

Tests: 192.
MSG

git push

echo
echo "--- migrating ~/.ssh/config and ~/.zshrc ---"
./install.sh

echo
echo "--- renaming the directory ---"
cd "$HOME"
if [ -e "$HOME/sushi" ]; then
  echo "  ! $HOME/sushi already exists — leaving $HOME/sshui alone."
  echo "    Move it yourself, then re-run: ~/sushi/install.sh"
else
  mv "$HOME/sshui" "$HOME/sushi"
  echo "  ~/sshui -> ~/sushi"
  # ~/.zshrc still points at the old path, so rewire it
  "$HOME/sushi/install.sh" >/dev/null
  echo "  ~/.zshrc now sources $HOME/sushi/sushi.zsh"
fi

cat <<'EOF'

--- done ---

  source ~/.zshrc      pick it up in this pane (NOT `exec zsh` in Warp)
  sushi list           should show your hosts, unchanged
  sushi scan -n        should report nothing new

Two things left, both in a browser:
  - rename the repo: github.com/infuriating/sshui -> Settings -> Repository name
  - GitHub redirects the old URL, but fix your remote anyway:
      git -C ~/sushi remote set-url origin git@github.com:infuriating/sushi.git

EOF
