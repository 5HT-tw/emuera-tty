#!/usr/bin/env bash
# Copies a game to the test app on a connected phone, faster than importing it on the phone
# when you're working on a PC. This relies on the APK being a debug build (run-as). The game
# folder on the PC is only read.
#
#   ./push-game.sh GAME_DIR [NAME]     as a game to play. Refuses to replace an existing game:
#                                      that would delete its saves. Import it in the app instead.
#   ./push-game.sh GAME_DIR --bench    as the copy the benchmark replays: replaced freely, and
#                                      kept apart from the games you play
set -euo pipefail
PKG=io.github.astartes_gaming.emuera
GAME=${1:?usage: push-game.sh GAME_DIR [NAME | --bench]}
[ -d "$GAME/ERB" ] || [ -d "$GAME/erb" ] || { echo "$GAME has no ERB folder" >&2; exit 2; }
if [ "${2:-}" = --bench ]; then
  DEST=files/bench/game
  adb shell "run-as $PKG sh -c 'rm -rf $DEST; mkdir -p $DEST'"
else
  NAME=${2:-$(basename "$(cd "$GAME" && pwd)")}
  case "$NAME" in *[!A-Za-z0-9._-]*|.*) echo "use a plain folder name, not '$NAME'" >&2; exit 2 ;; esac
  DEST=files/games/$NAME
  if adb shell "run-as $PKG [ -e $DEST ]"; then
    echo "$NAME is already on the phone. Replacing it here would delete its saves." >&2
    echo "Import the new version in the app (that keeps saves), or delete it there first." >&2
    exit 1
  fi
  adb shell "run-as $PKG mkdir -p $DEST"
fi
# (exec-in: a binary-safe pipe to a program on the phone, so no temporary copy is needed)
tar -C "$GAME" --exclude=.git --exclude=docs --exclude='#Translation' --exclude='*.exe' --exclude='*.bat' -cf - . \
  | adb exec-in "run-as $PKG sh -c 'cd $DEST && tar xf -'"
adb shell "run-as $PKG du -sh $DEST"
