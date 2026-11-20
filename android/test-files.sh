#!/usr/bin/env bash
# Tests moving files in and out of the app through the system's file manager, the way a player
# does (only that app can reach GamesProvider): list, rename, copy both ways byte for byte, a name
# already taken, new folder, delete. tools/paths_test.kt covers paths that try to get out.
#
#   ./test-files.sh
#
# Install the build to test first, and keep the phone unlocked. This relies on the APK being a
# debug build (run-as). It uses a throwaway game named erbfix-files and the folder erbfix-test on
# the phone's storage, and removes them at the end. It stops at the first thing it can't find, and
# only ever taps things by name, never the player's own games. The menus are read in English or
# German: another language needs its words added below.
set -u
P=io.github.astartes_gaming.emuera
UI=com.android.documentsui
G=files/games/erbfix-files
OUT=/sdcard/erbfix-test
fails=0
passes=0
ok() { echo "  ok    $1"; passes=$((passes+1)); }
bad() { echo "  FAIL  $1"; fails=$((fails+1)); }
ras() { adb shell "run-as $P sh -c '$1'" 2>/dev/null | tr -d '\r'; }
others() { ras 'cd files/games && find . -type f ! -path "./erbfix-*" ! -path "./.import-erbfix-*" -exec sha256sum {} + | sort -k2'; }
sha_app() { ras "sha256sum \"$G/$1\"" | cut -d' ' -f1; }
sha_out() { adb shell "sha256sum '$OUT/$1'" 2>/dev/null | tr -d '\r' | cut -d' ' -f1; }

[ "$(ras 'echo y')" = y ] || { echo "can't reach the app: is the phone connected and a debug build installed?" >&2; exit 2; }
[ -z "$(adb shell pidof $P:game | tr -d '\r')" ] || { echo "a game is open on the phone: leave it first" >&2; exit 2; }

T=$(mktemp -d)
cleanup() {
  rm -rf "$T"
  adb shell am force-stop $UI
  ras 'rm -rf files/games/erbfix-files files/games/.import-erbfix-hidden'
  adb shell rm -rf $OUT /data/local/tmp/ui.xml
  # (or the file manager goes on listing the folder, from the media index)
  adb shell content delete --uri content://media/external/file --where "_data\ LIKE\ \'%/erbfix-test%\'" >/dev/null 2>&1
  adb shell input keyevent KEYCODE_HOME
}
trap cleanup EXIT

# --- the screen, by name only
MORE='content-desc="(Weitere Optionen|More options)"'
ROOTS='content-desc="(Root-Verzeichnis anzeigen|Show roots)"'
COPY_TO='text="(Kopieren nach…|Copy to…)"'
COPY_HERE='text="(KOPIEREN|COPY|Kopieren|Copy)"'
RENAME='text="(Umbenennen|Rename)"'
DELETE='content-desc="(Endgültig löschen|Löschen|Delete permanently|Delete)"'
NEW_FOLDER='text="(Neuer Ordner|New folder)"'
dump() { adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; adb exec-out cat /data/local/tmp/ui.xml 2>/dev/null | sed 's/></>\n</g'; }
box() { dump | grep -E "$1" | "${PICK:-head}" -1 | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'; }
need() { # waits for something on the screen; without it nothing more can be done safely
  local i b
  for i in $(seq 1 12); do
    b=($(box "$1"))
    [ "${#b[@]}" = 4 ] && { x=$(( (b[0]+b[2])/2 )); y=$(( (b[1]+b[3])/2 )); return 0; }
  done
  bad "never saw $1, on: $(dump | grep -oE ' text="[^"]+"' | head -14 | paste -sd' ' | cut -c1-240)"
  echo "RESULT: $passes passed, $fails failed"
  exit 1
}
tap() { need "$1"; adb shell input tap $x $y; adb shell sleep 1; }
hold() { need "$1"; adb shell input swipe $x $y $x $y 900; adb shell sleep 1; }
name() { printf 'text="%s"' "$(printf '%s' "$1" | sed 's/[][().*+?]/\\&/g')"; }
# (the last one on the screen: the title behind the open drawer can have the same name)
drawer() { tap "$ROOTS"; adb shell sleep 1; PICK=tail tap "$(name "$1")"; adb shell sleep 1; }
open_app() {
  adb shell am force-stop $UI
  adb shell am start -W -a android.intent.action.VIEW -t vnd.android.document/root -d content://$P.games/root/games -n $UI/.files.FilesActivity >/dev/null
  adb shell sleep 2
}
open_storage() {
  adb shell am force-stop $UI
  adb shell am start -W -a android.intent.action.VIEW -t vnd.android.document/root -d content://com.android.externalstorage.documents/root/primary -n $UI/.files.FilesActivity >/dev/null
  adb shell sleep 2
}
copy_selected_to() { # the folders to go through, from the root named first
  tap "$MORE"
  tap "$COPY_TO"
  adb shell sleep 1
  drawer "$1"
  shift
  local f
  for f in "$@"; do tap "$(name "$f")"; done
  tap "$COPY_HERE"
}
wait_for() { # a command that prints something once the copy is done
  local i
  for i in $(seq 1 30); do [ -n "$("$@")" ] && return 0; adb shell sleep 1; done
  return 1
}

# --- what there is to move
ras "rm -rf $G; mkdir -p $G/CSV $G/ERB $G/sav files/games/.import-erbfix-hidden"
head -c 3000000 /dev/urandom > "$T/out.bin"
head -c 3000000 /dev/urandom > "$T/in.bin"
adb exec-in "run-as $P sh -c 'cat > $G/sav/save00.sav'" < "$T/out.bin"
adb shell mkdir -p $OUT
adb push "$T/in.bin" $OUT/erbfix-in.sav >/dev/null 2>&1
before=$(others)
adb shell input keyevent KEYCODE_WAKEUP

echo "### listing"
open_app
need "$(name erbfix-files)"
ok "the game is listed in the file manager"
[ -z "$(dump | grep -F 'import-erbfix-hidden')" ] && ok "folders with a dot aren't" || bad "a hidden folder is listed"

echo "### rename"
tap "$(name erbfix-files)"
tap "$(name sav)"
hold "$(name save00.sav)"
tap "$MORE"
tap "$RENAME"
adb shell input keyevent KEYCODE_MOVE_END
for i in $(seq 1 12); do adb shell input keyevent KEYCODE_DEL; done
adb shell input text erbfix-out.sav
adb shell sleep 1
tap 'text="OK"'
adb shell sleep 1
[ -n "$(ras "ls $G/sav/erbfix-out.sav")" ] && [ -z "$(ras "ls $G/sav/save00.sav 2>/dev/null")" ] && ok "a file can be renamed" || bad "rename: $(ras "ls $G/sav")"

echo "### copying out"
hold "$(name erbfix-out.sav)"
# (the phone's own storage goes by the phone's name in the file manager)
copy_selected_to "$(adb shell settings get global device_name | tr -d '\r')" erbfix-test
wait_for sha_out erbfix-out.sav
[ "$(sha_out erbfix-out.sav)" = "$(sha256sum "$T/out.bin" | cut -d' ' -f1)" ] && ok "3 MB copied out, byte-identical" || bad "copied out: $(sha_out erbfix-out.sav)"

echo "### copying in"
open_storage
tap "$(name erbfix-test)"
hold "$(name erbfix-in.sav)"
copy_selected_to "ERB player" erbfix-files sav
wait_for sha_app sav/erbfix-in.sav
[ "$(sha_app sav/erbfix-in.sav)" = "$(sha256sum "$T/in.bin" | cut -d' ' -f1)" ] && ok "3 MB copied in, byte-identical" || bad "copied in: $(sha_app sav/erbfix-in.sav)"
[ "$(ras "wc -c < $G/sav/erbfix-in.sav")" = 3000000 ] && ok "and the app itself can read it" || bad "the app can't read what came in"

echo "### a name already taken"
open_storage
tap "$(name erbfix-test)"
hold "$(name erbfix-in.sav)"
copy_selected_to "ERB player" erbfix-files sav
wait_for sha_app "sav/erbfix-in (1).sav"
[ "$(sha_app "sav/erbfix-in (1).sav")" = "$(sha_app sav/erbfix-in.sav)" ] && ok "a second copy gets its own name, and the first is untouched" || bad "second copy: $(ras "ls $G/sav")"

echo "### new folder, and delete"
open_app
tap "$(name erbfix-files)"
tap "$MORE"
tap "$NEW_FOLDER"
adb shell input text erbfix-new
adb shell sleep 1
tap 'text="OK"'
adb shell sleep 1
[ -n "$(ras "ls -d $G/erbfix-new")" ] && ok "a folder can be made" || bad "no new folder: $(ras "ls $G")"
open_app
tap "$(name erbfix-files)"
tap "$(name sav)"
hold "$(name "erbfix-in (1).sav")"
tap "$DELETE"
tap 'text="OK"'
adb shell sleep 1
[ -z "$(ras "ls \"$G/sav/erbfix-in (1).sav\" 2>/dev/null")" ] && [ -n "$(ras "ls $G/sav/erbfix-in.sav")" ] && ok "a file can be deleted, and only that file" || bad "delete: $(ras "ls $G/sav")"

echo "### the player's own games"
[ "$before" = "$(others)" ] && ok "all $(printf '%s' "$before" | grep -c .) other files unchanged" || bad "other games' files changed"

echo "RESULT: $passes passed, $fails failed"
[ "$fails" = 0 ]
