#!/usr/bin/env bash
# Tests replacing a game on a connected phone, through the app and the system file picker:
# saves survive in the game's own folder and in sav/, interrupted imports recover, and Delete removes
# a game with the engine's copies of its saves.
#
#   nix shell nixpkgs#zip -c ./test-import.sh
#
# Install the build to test first, and keep the phone unlocked. This relies on the APK being a
# debug build (run-as). It uses throwaway games named erbfix-* and the folder Download/erbfix-test,
# and removes them at the end. Like any game start it overwrites files/engine.log. It force-stops
# the app, so it refuses to run while a game is open: that would lose unsaved progress.
set -u
P=io.github.astartes_gaming.emuera
G=files/games
DIR=/sdcard/Download/erbfix-test
PICK='content://com.android.externalstorage.documents/document/primary%3ADownload%2Ferbfix-test'
fails=0
passes=0
ok() { echo "  ok    $1"; passes=$((passes+1)); }
bad() { echo "  FAIL  $1"; fails=$((fails+1)); }
ras() { adb shell "run-as $P sh -c '$1'" 2>/dev/null | tr -d '\r'; }
game_running() { [ -n "$(adb shell pidof $P:game | tr -d '\r')" ]; }
# (GameActivity's tablet flag, as the launcher sets it)
tablet() { [ "$(adb shell am get-config | grep -o "sw[0-9]*dp" | tr -dc 0-9)" -ge 600 ] 2>/dev/null && echo true || echo false; }
# everything of the player's: the test must leave all of it alone
others() { ras 'cd files/games && find . -type f ! -path "./erbfix-*" ! -path "./.old-erbfix-*" -exec sha256sum {} + | sort -k2'; }

command -v zip >/dev/null || { echo "needs zip: nix shell nixpkgs#zip -c $0" >&2; exit 2; }
[ "$(ras 'echo y')" = y ] || { echo "can't reach the app: is the phone connected and a debug build installed?" >&2; exit 2; }
game_running && { echo "a game is open on the phone: leave it first, or its unsaved progress is lost" >&2; exit 2; }

# (a game's first start asks for this, and the prompt would cover the screen; put back as it was afterwards)
adb shell dumpsys package $P | grep -q "android.permission.POST_NOTIFICATIONS: granted=true" && granted=yes || granted=no
adb shell pm grant $P android.permission.POST_NOTIFICATIONS 2>/dev/null

# (a game that died earlier would have its report cover the list)
ras 'rm -f files/game-running'
T=$(mktemp -d)
cleanup() {
  adb shell am force-stop $P
  adb shell am force-stop com.android.documentsui
  ras 'cd files && rm -rf game-running games/erbfix-* games/.old-erbfix-* games/.import-.deleted-erbfix-* data/emuera-tty/*/erbfix-*'
  [ "$granted" = yes ] || adb shell pm revoke $P android.permission.POST_NOTIFICATIONS 2>/dev/null
  adb shell rm -rf $DIR /data/local/tmp/ui.xml
  # (or the file manager goes on listing the folder, from the media index)
  adb shell content delete --uri content://media/external/file --where "_data\ LIKE\ \'%/erbfix-test%\'" >/dev/null 2>&1
  adb shell input keyevent KEYCODE_HOME
  rm -rf "$T"
}
trap cleanup EXIT

# --- the games. v1 writes every kind of save; v2 reads them back and writes down what it found.
V1='@SYSTEM_TITLE\nGLOBAL:0 = 4242\nSAVEGLOBAL\nADDCHARA 0\nSAVECHARA "mine", "a character", 0\nFLAG:0 = 7\nSAVEDATA 0, "a save"\nLOCAL = SAVETEXT("mine", 0)\nGCREATE 1, 8, 8\nLOCAL = GSAVE(1, 1)\nQUIT\n'
V2='@SYSTEM_TITLE\nLOADGLOBAL\nCHKDATA 0\nLOCAL:1 = RESULT\nLOADCHARA "mine"\nLOCAL:2 = GLOAD(2, 1)\nLOCALS = %LOADTEXT(0)%\nLOCALS:1 = v2 global={GLOBAL:0} chkdata={LOCAL:1} charas={CHARANUM} gload={LOCAL:2} text=%LOCALS%\nLOCAL = SAVETEXT(LOCALS:1, 1)\nQUIT\n'
EXPECT='v2 global=4242 chkdata=0 charas=1 gload=1 text=mine'
game() { # folder, version, script
  mkdir -p "$1/CSV" "$1/ERB" "$1/dat"
  printf 'コード,1\nバージョン,1000\nタイトル,erbfix\n' > "$1/CSV/GAMEBASE.CSV"
  printf '番号,0\n名前,A\n呼び名,A\n' > "$1/CSV/Chara0.csv"
  echo "game data $2" > "$1/dat/schema.xml"
  printf '%b' "$3" > "$1/ERB/TITLE.ERB"
}
# saves in the game's own folder (no config), in a zip with a wrapper folder
game "$T/root1/erbfix-root-1.0" v1 "$V1"
game "$T/root2/erbfix-root-2.0" v2 "$V2"
printf '@OLD_ONLY\nRETURN 0\n' > "$T/root1/erbfix-root-1.0/ERB/OLD.ERB"
echo author > "$T/root2/erbfix-root-2.0/global.sav"
# saves in sav/, in a tar.gz with no wrapper
game "$T/sav1" v1 "$V1"
game "$T/sav2" v2 "$V2"
printf 'セーブデータをsavフォルダ内に作成する:YES\n' | tee "$T/sav1/CSV/_default.config" > "$T/sav2/CSV/_default.config"
printf '@OLD_ONLY\nRETURN 0\n' > "$T/sav1/ERB/OLD.ERB"
mkdir "$T/sav2/sav"
echo author > "$T/sav2/sav/save00.sav"
for v in 1 2; do
  (cd "$T/root$v" && zip -q -r -X "$T/root$v.zip" .)
  tar -C "$T/sav$v" -czf "$T/sav$v.tar.gz" .
done

# --- driving the screen
dump() { adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; adb exec-out cat /data/local/tmp/ui.xml 2>/dev/null; }
# (any case: themes show dialog buttons in capitals)
find_node() { dump | sed 's/></>\n</g' | grep -iF "$1" | head -1; }
tap() {
  local i node b
  for i in $(seq 1 25); do
    node=$(find_node "text=\"$1\"")
    if [ -n "$node" ]; then
      b=($(printf '%s' "$node" | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'))
      adb shell input tap $(( (b[0]+b[2])/2 )) $(( (b[1]+b[3])/2 ))
      return 0
    fi
  done
  echo "  (never saw \"$1\")"
  return 1
}
wait_text() {
  local i
  for i in $(seq 1 40); do
    [ -n "$(find_node "text=\"$1")" ] && return 0
  done
  return 1
}
import() { # file name, game, "replace" if the dialog must appear
  adb shell am force-stop com.android.documentsui
  adb shell am start -S -W -n $P/.MainActivity --es initial_uri "$PICK" >/dev/null
  tap "Import a zip or tar" || return 1
  tap "$1" || return 1
  if [ "${3:-}" = replace ]; then
    wait_text "Replace $2?" || { echo "  (no replace dialog)"; return 1; }
    tap "Replace" || return 1
  fi
  wait_text "Imported $2 in"
}
play() { # game, the last file its script writes
  local i
  adb shell am start -S -W -n $P/.GameActivity --es game "$1" --ez tablet "$(tablet)" >/dev/null
  for i in $(seq 1 90); do
    [ "$(ras "[ -e $G/$1/$2 ] && echo y")" = y ] && break
    [ "$i" = 90 ] && return 1
    adb shell sleep 1
  done
  for i in $(seq 1 30); do
    game_running || return 0
    adb shell sleep 1
  done
  return 1
}

scenario() { # game, file name, v1, v2, save prefix, where the archive's own save goes
  local g=$1 file=$2 v1=$3 v2=$4 pre=$5 aside=$6 sums1 sums2 out
  local saves="${pre}global.sav ${pre}save00.sav ${pre}txt00.txt ${pre}img0001.png dat/chara_mine.dat"
  echo "### $g ($file)"
  adb push "$T/$v1" "$DIR/$file" >/dev/null 2>&1 || { bad "push"; return; }
  import "$file" "$g" && ok "v1 imported through the system picker" || { bad "v1 import"; return; }
  play "$g" "${pre}img0001.png" && ok "v1 played and exited" || { bad "v1 play"; ras 'tail -5 files/engine.log'; return; }
  sums1=$(ras "cd $G/$g && sha256sum $saves")
  [ "$(printf '%s\n' "$sums1" | grep -cE '^[0-9a-f]{64} ')" = 5 ] && ok "the engine wrote all 5 kinds of save" || { bad "saves: $sums1"; return; }
  adb push "$T/$v2" "$DIR/$file" >/dev/null 2>&1 || { bad "push"; return; }
  import "$file" "$g" replace && ok "v2 replaced v1 through the system picker" || { bad "v2 import"; return; }
  [ "$(ras "grep -c LOADGLOBAL $G/$g/ERB/TITLE.ERB")" = 1 ] && ok "the game really is v2 now" || { bad "not v2"; return; }
  sums2=$(ras "cd $G/$g && sha256sum $saves")
  [ "$sums1" = "$sums2" ] && ok "all 5 saves kept, byte-identical" || { bad "saves changed"; diff <(echo "$sums1") <(echo "$sums2") | cut -c1-110; }
  [ "$(ras "cat $G/$g/dat/schema.xml")" = "game data v2" ] && ok "new game data won in dat/" || bad "dat/schema.xml"
  [ -z "$(ras "[ -e $G/$g/ERB/OLD.ERB ] && echo left")" ] && ok "old game file gone" || bad "ERB/OLD.ERB still there"
  [ "$(ras "cat $G/$g/$aside")" = author ] && ok "the archive's own save kept aside as $aside" || bad "aside $aside"
  [ "$(ras "ls -a $G | grep -cF .old-")" = 0 ] && ok "no .old- folder left" || bad "leftovers: $(ras "ls -a $G")"
  play "$g" "${pre}txt01.txt" && ok "v2 played and exited" || { bad "v2 play"; ras 'tail -5 files/engine.log'; return; }
  out=$(ras "cat $G/$g/${pre}txt01.txt")
  [ "$out" = "$EXPECT" ] && ok "the engine loaded the kept saves: $out" || { bad "read back: $out"; ras 'tail -5 files/engine.log'; }
}

ras "rm -rf $G/.old-erbfix-* $G/erbfix-*"
before=$(others)
adb shell mkdir -p $DIR
adb shell input keyevent KEYCODE_WAKEUP
scenario erbfix-root erbfix-root.zip root1.zip root2.zip "" global.sav.from-archive
scenario erbfix-sav erbfix-sav.tar.gz sav1.tar.gz sav2.tar.gz sav/ sav.from-archive/save00.sav

echo "### recovery on the app's next start"
ras "mkdir -p $G/.old-erbfix-sav/dat $G/.old-erbfix-gone/CSV && echo stranded > $G/.old-erbfix-sav/save05.sav && echo stranded > $G/.old-erbfix-sav/dat/chara_late.dat && echo gamefile > $G/.old-erbfix-sav/README.txt && echo stranded > $G/.old-erbfix-gone/global.sav"
adb shell am force-stop com.android.documentsui
adb shell am start -S -W -n $P/.MainActivity >/dev/null
wait_text "ERB player"
[ "$(ras "cat $G/erbfix-sav/save05.sav")" = stranded ] && [ "$(ras "cat $G/erbfix-sav/dat/chara_late.dat")" = stranded ] && ok "saves stranded mid-move reached the game" || bad "stranded saves"
[ -z "$(ras "[ -e $G/erbfix-sav/README.txt ] && echo left")" ] && ok "the old copy's game files weren't carried" || bad "README carried"
[ "$(ras "cat $G/erbfix-gone/global.sav")" = stranded ] && ok "a game missing after a crash came back with its save" || bad "missing game"
[ "$(ras "ls -a $G | grep -cF .old-")" = 0 ] && ok "no .old- folder left" || bad ".old- left: $(ras "ls -a $G")"

echo "### deleting a game"
B=files/data/emuera-tty/backups
ras "mkdir -p $B/erbfix-sav/20260101-000000 $G/.import-.deleted-erbfix-root/ERB && echo old > $B/erbfix-sav/20260101-000000/save00.sav"
adb shell am start -S -W -n $P/.MainActivity >/dev/null
wait_text "ERB player"
[ -z "$(ras "ls -a $G | grep -F .deleted-")" ] && ok "a delete cut short is finished on the next start" || bad "left: $(ras "ls -a $G")"
# (the player's games may push it down the list)
for i in 1 2 3 4 5 6; do
  b=($(find_node 'content-desc="Delete erbfix-sav"' | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'))
  [ "${#b[@]}" = 4 ] && break
  adb shell input swipe 300 1200 300 400 300
done
adb shell input tap $(( (b[0]+b[2])/2 )) $(( (b[1]+b[3])/2 ))
wait_text "Delete erbfix-sav?" || bad "no delete dialog"
b=($(find_node 'resource-id="android:id/button1"' | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'))
adb shell input tap $(( (b[0]+b[2])/2 )) $(( (b[1]+b[3])/2 ))
for i in $(seq 1 20); do [ -z "$(ras "ls -a $G $B | grep -F erbfix-sav")" ] && break; adb shell sleep 1; done
[ -z "$(ras "ls -a $G | grep -F erbfix-sav")" ] && ok "Delete removes the game" || bad "still there: $(ras "ls -a $G")"
[ -z "$(ras "ls $B | grep -F erbfix-sav")" ] && ok "and the engine's copies of its saves" || bad "backups left: $(ras "ls $B")"
[ -z "$(find_node 'text="erbfix-sav"')" ] && ok "and the list doesn't show it" || bad "still listed"

echo "### the player's own games"
[ "$before" = "$(others)" ] && ok "all $(printf '%s' "$before" | grep -c .) other files unchanged" || bad "other games' files changed"

echo "RESULT: $passes passed, $fails failed"
[ "$fails" = 0 ]
