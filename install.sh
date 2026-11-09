#!/bin/sh
# Install stage on macOS (Apple Silicon):
#   curl -fsSL https://raw.githubusercontent.com/tridha643/stage/main/install.sh | sh
# Installs notesd, notes, stage and stage-helper into ~/.local/bin, loads the notesd
# LaunchAgent (launchd owns the socket and starts notesd on first connect), and copies
# the stage skills (stage, brief-me) into every agent skills folder it finds. Run it again to upgrade.
# It never replaces a skill folder or a herdr it didn't install without asking first, and backs up
# what it replaces; `| sh -s -- --force` answers yes to those questions.
# STAGE_VERSION=v0.1.0 pins a release; `sh install.sh DIR` installs an unpacked build
# (scripts/install.sh uses that for source builds).
set -eu
force=0
dist=""
for arg; do
  case "$arg" in
    --force) force=1 ;;
    -*) echo "unknown option $arg" >&2; exit 1 ;;
    *) dist="$arg" ;;
  esac
done
# Every path this run writes or removes, printed at the end.
log=""
note() { log="$log
  $*"; }
# Yes only with --force or an explicit y typed at a terminal. A piped install's stdin is the
# script itself, so read the answer from /dev/tty, and treat no terminal as no.
confirm() {
  [ "$force" = 1 ] && return 0
  (: </dev/tty) 2>/dev/null || return 1
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r answer </dev/tty || return 1
  case "$answer" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
# Content hash of a skill folder, leaving out its .stage-managed marker.
tree_hash() { (cd "$1" 2>/dev/null && find . -type f ! -name .stage-managed -exec shasum {} +) | LC_ALL=C sort -k2 | shasum | cut -d' ' -f1; }
repo="tridha643/stage"
asset="stage-macos-arm64.tar.gz"
[ "$(uname -s)" = Darwin ] || { echo "stage runs on macOS only" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "stage needs an Apple Silicon Mac" >&2; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo "stage needs macOS 26 or later" >&2; exit 1; }

if [ -z "$dist" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  case "${STAGE_VERSION:-latest}" in
    latest) url="https://github.com/$repo/releases/latest/download/$asset" ;;
    *) url="https://github.com/$repo/releases/download/$STAGE_VERSION/$asset" ;;
  esac
  echo "downloading $url"
  curl -fsSL "$url" | tar -xz -C "$tmp"
  dist="$tmp"
fi

bin="$HOME/.local/bin"
support="$HOME/Library/Application Support/Notes"
plist="$HOME/Library/LaunchAgents/dev.notes.notesd.plist"
# Keep a host's session directory across upgrades; an explicit value wins.
# PlistBuddy prints "File Doesn't Exist" to stdout, so only ask it when the plist is there.
stage_dir="${NOTES_STAGE_DIR:-$([ ! -f "$plist" ] || /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:NOTES_STAGE_DIR' "$plist" 2>/dev/null || true)}"
case "$stage_dir" in
  ""|/*) ;;
  *) echo "NOTES_STAGE_DIR must be an absolute path" >&2; exit 1 ;;
esac
mkdir -p "$bin" "$support" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$dist/bin/notesd" "$dist/bin/notes" "$dist/bin/stage" "$dist/bin/stage-helper" "$bin/"
note "wrote $bin/notesd, $bin/notes, $bin/stage, $bin/stage-helper"
# stage-helper loads pele (mermaid) from its resource bundle, which must sit next to it.
for bundle in "$dist"/bin/*.bundle; do
  rm -rf "$bin/$(basename "$bundle")" && cp -R "$bundle" "$bin/"
  note "wrote $bin/$(basename "$bundle")"
done
# Each installed skill folder holds .stage-managed, the hash of the files stage wrote there. A
# folder that still matches it (or already matches this release) is replaced; anything else is
# the user's own skill or has local edits, so ask first and move it to a backup outside the
# skills folders, where agents won't load it as a second copy.
backups="$support/backups/$(date +%Y%m%d-%H%M%S)"
for skills in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.pi/agent/skills" "$HOME/.agents/skills"; do
  [ -d "$skills" ] || continue
  for skill in "$dist"/skills/*; do
    dest="$skills/${skill##*/}"
    want="$(tree_hash "$skill")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      have="$(tree_hash "$dest")"
      marker="$(cat "$dest/.stage-managed" 2>/dev/null || true)"
      if [ "$have" = "$want" ] || [ "$have" = "$marker" ]; then
        rm -rf "$dest"
      elif confirm "$dest wasn't installed by stage or has local edits. Back it up and replace it with stage's?"; then
        mkdir -p "$backups/${skills#"$HOME"/}"
        mv "$dest" "$backups/${skills#"$HOME"/}/"
        echo "backed up $dest to $backups/${skills#"$HOME"/}/${skill##*/}"
        note "moved $dest to $backups/${skills#"$HOME"/}/${skill##*/}"
      else
        echo "kept $dest: stage didn't install it, or it has local edits. Rerun with --force to back it up and replace it" >&2
        continue
      fi
    fi
    cp -R "$skill" "$dest"
    echo "$want" >"$dest/.stage-managed"
    note "wrote $dest"
  done
done
# Standard, not Background: notesd answers stage and the CLI, so it shouldn't be throttled.
note "wrote $plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.notes.notesd</string>
  <key>ProgramArguments</key><array><string>$bin/notesd</string></array>
  <key>Sockets</key><dict><key>Listeners</key><dict>
    <key>SockPathName</key><string>$support/notesd.sock</string>
    <key>SockPathMode</key><integer>384</integer>
  </dict></dict>
  <key>ProcessType</key><string>Standard</string>
  <key>RunAtLoad</key><false/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/notesd.log</string>
</dict>
</plist>
PLIST
if [ -n "$stage_dir" ]; then
  plutil -insert EnvironmentVariables -dictionary "$plist"
  plutil -insert EnvironmentVariables.NOTES_STAGE_DIR -string "$stage_dir" "$plist"
fi
launchctl bootout "gui/$(id -u)/dev.notes.notesd" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
# stage runs in Herdr panes, and its kitty graphics need a current Herdr. Replace an older
# copy (Homebrew's or a loose binary) with the latest release in $bin, after asking, since the
# old copy isn't stage's to remove. Not installed: skip.
if have="$(herdr --version 2>/dev/null)"; then
  have="${have#herdr }"
  # A failed lookup or download leaves the old herdr in place rather than failing the install.
  latest="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/herdrdev/herdr/releases/latest || true)"
  latest="${latest##*/tag/v}"
  if [ -n "$latest" ] && [ "$have" != "$latest" ] && [ "$(printf '%s\n%s\n' "$have" "$latest" | sort -V | tail -1)" = "$latest" ]; then
    old="$(command -v herdr)"
    brew=""
    if brew list herdr >/dev/null 2>&1; then brew=1; fi
    plan="install herdr $latest at $bin/herdr"
    [ -z "$brew" ] || plan="$plan, run brew uninstall herdr"
    [ "$old" = "$bin/herdr" ] || plan="$plan, and delete $old"
    if ! confirm "stage's graphics need a current herdr, and you have $have. OK to $plan?"; then
      echo "kept herdr $have at $old; stage's graphics may not draw until you upgrade it" >&2
    elif curl -fsSL -o "$bin/herdr.new" "https://github.com/herdrdev/herdr/releases/download/v$latest/herdr-macos-aarch64"; then
      echo "replacing herdr $have with $latest"
      chmod 755 "$bin/herdr.new"
      if [ -n "$brew" ]; then brew uninstall herdr && note "removed Homebrew herdr $have"; fi
      if [ "$old" != "$bin/herdr" ] && [ -e "$old" ]; then
        if rm -f "$old"; then note "removed $old"; else echo "remove $old by hand: it shadows $bin/herdr" >&2; fi
      fi
      mv "$bin/herdr.new" "$bin/herdr"
      note "wrote $bin/herdr"
      echo "a running herdr keeps $have until you restart it (herdr server stop)"
    fi
  fi
fi
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "add $bin to your PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" >&2 ;;
esac
# launchd needs a moment after bootstrap before the socket answers.
sock="$support/notesd.sock"
for _ in 1 2 3 4 5 6 7 8 9 10; do "$bin/notes" doctor --sock "$sock" >/dev/null 2>&1 && break; sleep 0.2; done
"$bin/notes" doctor --sock "$sock"
printf 'paths written or removed:%s\n' "$log"
echo "installed. Open a terminal pane and run: stage"
