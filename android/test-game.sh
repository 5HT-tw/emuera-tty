#!/usr/bin/env bash
# Tests a running game on a connected phone: touches reach the script (INPUTMOUSEKEY, MOUSEX,
# MOUSEB, GETKEY), ordinary inputs still work, the game survives in the background, CBG* layers
# land where they should (this reads the screen's pixels), crashes get reported, sound plays, text
# can be resized, the screen can turn, and the game's menu changes its settings, reloads the scripts, manages saves,
# goes back to the title and restarts. (The save manager's export and import go through the system's file picker: not here.)
#
#   ./test-game.sh
#
# Install the build to test first, and keep the phone unlocked. This relies on the APK being a
# debug build (run-as). It uses throwaway games named erbfix-* and removes them at the end.
# Like any game start it overwrites files/engine.log. It force-stops the app, so it refuses to
# run while a game is open: that would lose unsaved progress.
set -u
P=io.github.astartes_gaming.emuera
NOTIFY=android.permission.POST_NOTIFICATIONS
G=files/games/erbfix-touch
fails=0
passes=0
ok() { echo "  ok    $1"; passes=$((passes+1)); }
bad() { echo "  FAIL  $1"; fails=$((fails+1)); }
ras() { adb shell "run-as $P sh -c '$1'" 2>/dev/null | tr -d '\r'; }
pid() { adb shell pidof $P:game | tr -d '\r'; }
# (GameActivity's tablet flag, as the launcher sets it)
tablet() { [ "$(adb shell am get-config | grep -o "sw[0-9]*dp" | tr -dc 0-9)" -ge 600 ] 2>/dev/null && echo true || echo false; }
others() { ras 'cd files/games && find . -type f ! -path "./erbfix-*" ! -path "./.old-erbfix-*" -exec sha256sum {} + | sort -k2'; }
gamebase() { printf 'コード,1\nバージョン,1000\nタイトル,erbfix\n' | adb exec-in "run-as $P sh -c 'cat > $1/CSV/GAMEBASE.CSV'"; } # game folder

[ "$(ras 'echo y')" = y ] || { echo "can't reach the app: is the phone connected and a debug build installed?" >&2; exit 2; }
[ -z "$(pid)" ] || { echo "a game is open on the phone: leave it first, or its unsaved progress is lost" >&2; exit 2; }

# (the prompt would cover the screen; put back as it was afterwards)
adb shell dumpsys package $P | grep -q "$NOTIFY: granted=true" && granted=yes || granted=no
adb shell pm grant $P $NOTIFY 2>/dev/null
# (a tablet turning mid-test would leave every position below wrong; put back as it was afterwards)
auto=$(adb shell settings get system accelerometer_rotation | tr -d '\r')
rot=$(adb shell settings get system user_rotation | tr -d '\r')
adb shell wm user-rotation lock >/dev/null
# (a game that died earlier would have its report cover the list, and a run that stopped early
# may have left a text size for its games)
ras 'rm -f files/game-running; sed -i "/erbfix-/d" shared_prefs/text-size.xml'
T=$(mktemp -d)
cleanup() {
  rm -rf "$T"
  adb shell am force-stop $P
  ras 'sed -i "/erbfix-/d" shared_prefs/text-size.xml; cd files && rm -rf game-running games/erbfix-* data/emuera-tty/*/erbfix-*'
  [ "$granted" = yes ] || adb shell pm revoke $P $NOTIFY 2>/dev/null
  adb shell settings put system user_rotation "$rot"
  if [ "$auto" = 1 ]; then adb shell wm user-rotation free >/dev/null; else adb shell wm user-rotation lock "$rot" >/dev/null; fi
  adb shell rm -f /data/local/tmp/ui.xml
  adb shell input keyevent KEYCODE_HOME
}
trap cleanup EXIT

# --- the game: each step writes what it saw to txtNN.txt, which is also how this script follows it
ras "rm -rf $G; mkdir -p $G/CSV $G/ERB"
gamebase $G
adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
REPEAT 30
	PRINTBUTTON "[ a button filling the left half of the screen, and rows of it ]", 7
	PRINTL
REND
CALL RAW, 10
CALL RAW, 11
CALL RAW, 12
CALL RAW, 13
CALL RAW, 14
CALL RAW, 15
$TIMEOUT
INPUTMOUSEKEY 200
SIF RESULT:0 != 4
	GOTO TIMEOUT
CALL REC, 16
LOCAL = GETKEYTRIGGERED(1)
$HIT
AWAIT 20
SIF !GETKEYTRIGGERED(1)
	GOTO HIT
LOCALS = mouseb=%MOUSEB()% x={MOUSEX()} y={MOUSEY()}
LOCAL = SAVETEXT(LOCALS, 20)
$HELD
AWAIT 20
SIF !GETKEY(1)
	GOTO HELD
LOCAL = SAVETEXT("held", 21)
$RELEASED
AWAIT 20
SIF GETKEY(1)
	GOTO RELEASED
LOCAL = SAVETEXT("released", 22)
LOCAL = GETKEYTRIGGERED(2)
$RIGHT
AWAIT 20
SIF !GETKEYTRIGGERED(2)
	GOTO RIGHT
LOCAL = SAVETEXT("right", 23)
$FRAME
INPUTMOUSEKEY 16
SIF RESULT:0 != 1
	GOTO FRAME
CALL REC, 30
REPEAT 5
	PRINTBUTTON "[ a button for an ordinary input, filling the left half of the screen ]", 8
	PRINTL
REND
INPUT
LOCAL = SAVETEXT(TOSTR(RESULT), 31)
PRINTL a WAIT, passed by a tap anywhere
WAIT
LOCAL = SAVETEXT("passed", 32)
$SLOW
LOCAL:1 = MOUSEX()
LOCAL:2 = GETMILLISECOND()
WHILE GETMILLISECOND() < LOCAL:2 + 200
WEND
INPUTMOUSEKEY 15
SIF RESULT:0 != 1
	GOTO SLOW
LOCALS = hover={LOCAL:1} click={RESULT:2}
LOCAL = SAVETEXT(LOCALS, 33)
CALL RAW, 40
QUIT

@RAW, ARG
INPUTMOUSEKEY
CALL REC, ARG

@REC, ARG
LOCALS = r0={RESULT:0} r1={RESULT:1} r2={RESULT:2} r3={RESULT:3} r5={RESULT:5}
LOCAL = SAVETEXT(LOCALS, ARG)
ERB

tap_text() { # only ever taps what it found by name: its text, or the attribute given (content-desc); "start" matches the start
  local i b end='"'
  [ "${3:-}" = start ] && end=''
  for i in $(seq 1 25); do
    adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1
    b=($(adb exec-out cat /data/local/tmp/ui.xml | sed 's/></>\n</g' | grep -iF "${2:-text}=\"$1$end" | head -1 | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'))
    [ "${#b[@]}" = 4 ] && { adb shell input tap $(( (b[0]+b[2])/2 )) $(( (b[1]+b[3])/2 )); return 0; }
  done
  # (this app's own words only: the screen could be anything else's)
  echo "  (never saw \"$1\", with $(adb shell dumpsys activity activities | grep -m1 topResumedActivity | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+') on top, $(adb shell dumpsys window displays | grep -m1 -oE 'cur=[0-9]+x[0-9]+'), showing: $(adb exec-out cat /data/local/tmp/ui.xml | sed 's/></>\n</g' | grep -F "package=\"$P\"" | grep -oE ' text="[^"]+"' | head -14 | paste -sd' ' | cut -c1-260))"
  return 1
}
screen_size() { scr=($(adb shell dumpsys window displays | grep -m1 -oE 'cur=[0-9]+x[0-9]+' | grep -oE '[0-9]+')); }
# as a player does: from the launcher's list, which stays underneath
play() {
  # (stopping a game that's running looks like a crash: its report would cover the list)
  adb shell am force-stop $P
  ras 'rm -f files/game-running'
  adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $P/.MainActivity >/dev/null
  # (a short screen or a long list can have it further down)
  adb shell sleep 1
  screen_size
  local i
  for i in 1 2 3 4 5 6; do
    adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1
    adb exec-out cat /data/local/tmp/ui.xml | grep -qF "text=\"$1\"" && break
    adb shell input swipe $((scr[0]/2)) $((scr[1]*3/5)) $((scr[0]/2)) $((scr[1]/4)) 300
    adb shell sleep 1
  done
  tap_text "$1"
}
# tapping the launcher's icon: its flags (not monkey, which turns auto-rotate back on)
icon() { adb shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n $P/.MainActivity >/dev/null; }
top_is_game() { adb shell dumpsys activity activities | grep -m1 topResumedActivity | grep -q "$P/.GameActivity"; }
heap() { adb shell dumpsys meminfo $P:game | awk '/^ *Native Heap /{print int($3/1024); exit}'; }

step() { # number: waits for that step's file and prints it
  local i
  for i in $(seq 1 30); do
    [ -n "$(ras "ls $G/txt$1.txt 2>/dev/null")" ] && { ras "cat $G/txt$1.txt"; return 0; }
    adb shell sleep 1
  done
  echo "(step $1 never came)"
  return 1
}
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# --- start it, and find the view on the screen
before=$(others)
adb shell input keyevent KEYCODE_WAKEUP
# (any app can start the list, and engine settings can overwrite a save: only adb may pass them to a game)
adb shell am start -W -n $P/.MainActivity --es game erbfix-touch --es env EMUERA_MEMSTATS=files/stolen >/dev/null
adb shell sleep 3
[ -z "$(pid)" ] && ok "the list doesn't start a game it's sent" || bad "the list started a game for another app"
play erbfix-touch
for i in $(seq 1 30); do [ -n "$(ras "grep -l loaded files/engine.log")" ] && break; adb shell sleep 1; done
adb shell sleep 1
# (the bar below the view starts where the view ends, and shares its left edge)
find_view() {
  local ui i
  for i in 1 2 3 4 5; do
    adb shell rm -f /data/local/tmp/ui.xml
    adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1
    ui=$(adb exec-out cat /data/local/tmp/ui.xml 2>/dev/null | sed 's/></>\n</g')
    enter=($(printf '%s\n' "$ui" | grep -iF 'text="Enter"' | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'))
    field_box=($(printf '%s\n' "$ui" | grep -F 'android.widget.EditText' | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+'))
    [ "${#enter[@]}" = 4 ] && [ "${#field_box[@]}" = 4 ] && break
  done
  [ "${#enter[@]}" = 4 ] && [ "${#field_box[@]}" = 4 ] || { bad "no input bar on the screen"; exit 1; }
  left=${field_box[0]}
  right=$(printf '%s\n' "$ui" | grep -iF 'text="Skip"' | grep -o 'bounds="[^"]*"' | grep -o '[0-9]\+' | sed -n 3p)
  bottom=$(( enter[1] < field_box[1] ? enter[1] : field_box[1] ))
  width=$((right-left))
}
find_view
# on a button (the left half), on nothing (the right edge), and on the bottom row
bx=$((left+width/4)); by=$((bottom-200)); ex=$((left+width*95/100))
echo "view: x $left to $right, bottom $bottom"

echo "### taps at INPUTMOUSEKEY"
adb shell input tap $bx $by
s=$(step 10) || bad "tap on a button: $s"
[ "$(field "$s" r0)" = 1 ] && [ "$(field "$s" r1)" = 1048576 ] && [ "$(field "$s" r5)" = 7 ] && ok "tap on a button: left click with its value ($s)" || bad "tap on a button: $s"
x1=$(field "$s" r2); y1=$(field "$s" r3)
adb shell input tap $ex $by
s=$(step 11) || bad "tap on nothing: $s"
x2=$(field "$s" r2)
[ "$(field "$s" r0)" = 1 ] && [ "$(field "$s" r5)" = 0 ] && ok "tap on nothing still reaches the script ($s)" || bad "tap on nothing: $s"
# 25% and 95% across: the positions have to keep that ratio, to within a cell or two
[ $((x1*95)) -gt $((x2*22)) ] && [ $((x1*95)) -lt $((x2*28)) ] && ok "x follows the finger ($x1 at 25%, $x2 at 95%)" || bad "x: $x1 at 25%, $x2 at 95%"
adb shell input tap $ex $((bottom-3))
s=$(step 12) || bad "bottom row: $s"
y=$(field "$s" r3)
[ "$y" -lt 0 ] && [ "$y" -gt -20 ] && [ "$y1" -lt -40 ] && ok "y counts up from the bottom row: $y there, $y1 higher up" || bad "y: $y at the bottom, $y1 higher up"
adb shell input swipe $ex $by $ex $by 900
s=$(step 13) || bad "long press: $s"
[ "$(field "$s" r0)" = 1 ] && [ "$(field "$s" r1)" = 2097152 ] && ok "long press is a right click ($s)" || bad "long press: $s"
adb shell input swipe $ex $((by+100)) $ex $((by-300)) 300
s=$(step 14) || bad "drag: $s"
[ "$(field "$s" r0)" = 2 ] && [ "$(field "$s" r1)" = -120 ] && ok "dragging up is the wheel going down ($s)" || bad "drag: $s"
s=$(step 15) || bad "drag remainder: $s"
[ "$(field "$s" r0)" = 2 ] && ok "a long drag sends several wheel steps" || bad "expected a second wheel step: $s"
s=$(step 16) || bad "timeout: $s"
[ "$(field "$s" r0)" = 4 ] && ok "a timed INPUTMOUSEKEY times out with no touch" || bad "timeout: $s"

echo "### between inputs: what scripts poll during AWAIT"
adb shell sleep 1
adb shell input tap $bx $by
s=$(step 20) || bad "tap during AWAIT: $s"
[ "$(field "$s" mouseb)" = 7 ] && [ "$(field "$s" x)" = "$x1" ] && ok "GETKEYTRIGGERED, MOUSEB and MOUSEX see a tap ($s)" || bad "tap during AWAIT: $s"
adb shell input swipe $ex $by $ex $by 1500 &
s=$(step 21) || bad "held: $s"
[ "$s" = held ] && ok "GETKEY sees the finger down" || bad "held: $s"
wait
s=$(step 22) || bad "released: $s"
[ "$s" = released ] && ok "GETKEY sees it lifted" || bad "released: $s"
adb shell sleep 1
adb shell input swipe $ex $by $ex $by 900
s=$(step 23) || bad "right: $s"
[ "$s" = right ] && ok "GETKEYTRIGGERED(2) sees a long press" || bad "right: $s"

echo "### a real-time loop, then ordinary inputs"
adb shell sleep 1
# (all threads, in ticks of 1/100 s: the same screen used to be drawn again every frame, 38-97%; the
# frames themselves take 5% on a POCO F1 and 11% on a Tab S6 Lite)
cpu() { ras "cat /proc/$(pid)/stat" | awk '{print $14+$15}'; }
c0=$(cpu); adb shell sleep 5; c=$(( ($(cpu)-c0)/5 ))
if [ -n "$(ras "ls $G/txt30.txt 2>/dev/null")" ]; then bad "the 16 ms loop ended before its tap: an earlier one was kept for it"
elif [ "$c" -lt 25 ]; then ok "idle in a 16 ms INPUTMOUSEKEY loop, the game takes $c% of one core"; else bad "idle in a 16 ms loop, the game takes $c% of one core"; fi
adb shell input tap $bx $by
s=$(step 30) || bad "tap in a 16 ms loop: $s"
[ "$(field "$s" r5)" = 7 ] && ok "a tap reaches a 16 ms INPUTMOUSEKEY loop ($s)" || bad "tap in a 16 ms loop: $s"
adb shell sleep 1
adb shell input tap $bx $((bottom-60))
s=$(step 31) || bad "INPUT: $s"
[ "$s" = 8 ] && ok "a tap on a button still answers an INPUT" || bad "INPUT: $s"
adb shell sleep 1
adb shell input tap $ex $by
s=$(step 32) || bad "WAIT: $s"
[ "$s" = passed ] && ok "a tap anywhere still passes a WAIT" || bad "WAIT: $s"
# a menu like pops-tw's title: what's under the mouse is worked out once a frame, slower than a tap
adb shell sleep 1
adb shell input tap $bx $by
s=$(step 33) || bad "slow frames: $s"
[ -n "$(field "$s" click)" ] && [ "$(field "$s" hover)" = "$(field "$s" click)" ] && ok "a frame sees where the finger is before its click arrives ($s)" || bad "slow frames: $s"

echo "### in the background"
adb shell sleep 1
game=$(pid)
adb shell input keyevent KEYCODE_HOME
adb shell sleep 3
adj=$(ras "cat /proc/$game/oom_score_adj")
[ -n "$adj" ] && [ "$adj" -le 250 ] && ok "kept near the front of what Android spares (oom_score_adj $adj)" || bad "oom_score_adj $adj"
adb shell am kill $P
adb shell sleep 2
[ "$(pid)" = "$game" ] && ok "survives Android killing the app's background processes" || bad "killed: was $game, now $(pid)"
adb shell dumpsys notification --noredact | grep -q "pkg=$P" && ok "the notification is showing" || bad "no notification"

echo "### coming back"
one_game() { [ "$(pid)" = "$game" ] && [ "$(adb shell dumpsys activity activities | grep -c "Hist.*$P/.GameActivity")" = 1 ] && top_is_game; }
icon
adb shell sleep 2
one_game && ok "the launcher icon returns to the same game" || bad "launcher icon: pid $(pid), top: $(adb shell dumpsys activity activities | grep -m1 topResumedActivity | cut -c1-90)"
adb shell input keyevent KEYCODE_HOME
# (Android can hold a foreground service's notification back for 10 s, and coming back restarts ours)
adb shell sleep 12
# (as a player does: uiautomator goes on reading the game's window until something touches the shade)
screen_size
adb shell input swipe $((scr[0]/2)) 0 $((scr[0]/2)) $((scr[1]/2)) 300
adb shell sleep 2
# (by its title: a quiet notification can be collapsed to that. With others showing it starts as an
# icon at the bottom, so scroll down to it)
for i in 1 2 3; do
  adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1
  adb exec-out cat /data/local/tmp/ui.xml | grep -qF 'text="erbfix-touch"' && break
  adb shell input swipe $((scr[0]/2)) $((scr[1]*3/4)) $((scr[0]/2)) $((scr[1]/4)) 300
  adb shell sleep 1
done
if tap_text "erbfix-touch"; then
  adb shell sleep 2
  one_game && ok "the notification returns to the same game" || bad "notification: pid $(pid), top: $(adb shell dumpsys activity activities | grep -m1 topResumedActivity | cut -c1-90)"
else
  bad "the notification wasn't there to tap"
  adb shell cmd statusbar collapse
  icon
  adb shell sleep 2
fi
top_is_game || { bad "not back in the game: stopping here so nothing else gets tapped"; exit 1; }
adb shell input tap $bx $by
s=$(step 40) || bad "after coming back: $s"
[ "$(field "$s" r0)" = 1 ] && ok "the game still answers: it wasn't restarted" || bad "after coming back: $s"
for i in $(seq 1 15); do [ -z "$(pid)" ] && break; adb shell sleep 1; done
[ -z "$(pid)" ] && ok "the process ends with the game, and the service with it" || bad "still running after QUIT"
adb shell sleep 2
[ -z "$(pid)" ] && ok "nothing brought it back" || bad "the service came back"

echo "### swiping it away in Recents"
ras "rm -f $G/txt*.txt"
play erbfix-touch
for i in $(seq 1 30); do [ -n "$(pid)" ] && break; adb shell sleep 1; done
adb shell sleep 2
game=$(pid)
task=$(adb shell dumpsys activity activities | grep -m1 -E "Task\{.*A=[0-9]+:$P" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
adb shell am stack remove "$task" >/dev/null 2>&1
adb shell sleep 3
[ -n "$game" ] && [ -z "$(pid)" ] && ok "it ends the game" || bad "pid was '$game', now '$(pid)'"
adb shell sleep 3
[ -z "$(pid)" ] && ok "and it stays ended" || bad "it came back"
[ "$(adb shell dumpsys notification --noredact | grep -c "pkg=$P")" = 0 ] && ok "and the notification goes" || bad "the notification stayed"

echo "### memory in the background"
PIC=files/games/erbfix-pic
# a big picture, made by the engine itself: this leaves its decoded copy in the picture cache
ras "mkdir -p $PIC/CSV $PIC/ERB"
gamebase $PIC
printf '@SYSTEM_TITLE\nGCREATE 1, 2400, 2400\nLOCAL = GSAVE(1, 1)\nQUIT\n' | adb exec-in "run-as $P sh -c 'cat > $PIC/ERB/TITLE.ERB'"
play erbfix-pic
for i in $(seq 1 60); do [ -n "$(ras "ls $PIC/img0001.png 2>/dev/null")" ] && [ -z "$(pid)" ] && break; adb shell sleep 1; done
ras "mkdir -p $PIC/resources && mv $PIC/img0001.png $PIC/resources/big.png && echo BIG,big.png > $PIC/resources/pic.csv"
adb exec-in "run-as $P sh -c 'cat > $PIC/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
HTML_PRINT "<img src='BIG'>"
PRINTL
REPEAT 5
	PRINTBUTTON "[ a button after the picture, filling the left half of the screen ]", 1
	PRINTL
REND
INPUT
LOCAL = SAVETEXT(TOSTR(RESULT), 50)
QUIT
ERB
play erbfix-pic
for i in $(seq 1 30); do [ -n "$(ras "grep -l loaded files/engine.log")" ] && break; adb shell sleep 1; done
adb shell sleep 3
heap1=$(heap)
adb shell input keyevent KEYCODE_HOME
adb shell sleep 5
heap2=$(heap)
[ -n "$heap1" ] && [ -n "$heap2" ] && [ $((heap1-heap2)) -ge 10 ] && ok "hiding it gives pictures back: native heap $heap1 MB to $heap2 MB" || bad "native heap $heap1 MB to $heap2 MB"
icon
adb shell sleep 2
top_is_game || { bad "not back in the game: stopping here so nothing else gets tapped"; exit 1; }
adb shell input tap $bx $((bottom-60))
for i in $(seq 1 20); do [ -n "$(ras "ls $PIC/txt50.txt 2>/dev/null")" ] && break; adb shell sleep 1; done
s=$(ras "cat $PIC/txt50.txt")
[ "$s" = 1 ] && ok "the game still answers after that" || bad "after giving memory back: $s"

echo "### pictures behind and in front of the text (CBG*)"
G=files/games/erbfix-cbg
adb shell am force-stop $P
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
# a picture file for a sprite layer, made by the engine itself
printf '@SYSTEM_TITLE\nGCREATE 4, 100, 100\nGCLEAR 4, 0xFF0000FF\nLOCAL = GSAVE(4, 1)\nQUIT\n' | adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'"
play erbfix-cbg
for i in $(seq 1 30); do [ -n "$(ras "ls $G/img0001.png 2>/dev/null")" ] && [ -z "$(pid)" ] && break; adb shell sleep 1; done
ras "mkdir -p $G/resources && mv $G/img0001.png $G/resources/blue.png && echo BLUE,blue.png > $G/resources/pic.csv"
adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
GCREATE 1, 400, 200
GCLEAR 1, 0xFFFF0000
GSETBRUSH 1, 0xFFFFFFFF
GSETFONT 1, "", 64
LOCAL = GDRAWTEXT(1, "■", 300, 20)
LOCAL = CBGSETG(1, 0, 0, 1)
GCREATE 3, 100, 200
GCLEAR 3, 0xFF00FF00
LOCAL = CBGSETG(3, 400, 0, -1)
LOCAL = CBGSETSPRITE("BLUE", 500, 0, 1)
GCREATE 2, 400, 200
GCLEAR 2, 0xFF000011
GSETBRUSH 2, 0xFF000022
GFILLRECTANGLE 2, 200, 0, 200, 200
LOCAL = CBGSETBMAPG(2)
REPEAT 3
	PRINTL ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
REND
CALL RAW, 60
CALL RAW, 61
CALL RAW, 62
CALL RAW, 63
LOCAL = SAVETEXT(TOSTR(CLIENTHEIGHT()), 64)
LOCAL = CBGCLEAR()
CALL RAW, 65
QUIT

@RAW, ARG
INPUTMOUSEKEY
LOCALS = r0={RESULT:0} r2={RESULT:2} r3={RESULT:3} r4={RESULT:4}
LOCAL = SAVETEXT(LOCALS, ARG)
ERB
play erbfix-cbg
for i in $(seq 1 30); do [ -n "$(ras "grep -l loaded files/engine.log")" ] && break; adb shell sleep 1; done
adb shell sleep 3
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
# Emuera's pixels on the screen: 120 half-width cells of 9 pixels fill the view's width
s100=$((width*100/1080))
sx() { echo $((left+$1*s100/100)); }
sy() { echo $((bottom-$1*s100/100)); }
shot() {
  adb exec-out screencap > "$T/s.raw"
  sw=$(od -An -tu4 -N4 "$T/s.raw" | tr -d ' ')
  sh=$(od -An -tu4 -j4 -N4 "$T/s.raw" | tr -d ' ')
  hdr=$(($(stat -c %s "$T/s.raw")-sw*sh*4))
}
pixel() { # what, Emuera x, Emuera y up from the bottom, red, green, blue
  local c
  c=($(od -An -tu1 -j $((hdr+($(sy $3)*sw+$(sx $2))*4)) -N3 "$T/s.raw"))
  local dr=$((c[0]-$4)) dg=$((c[1]-$5)) db=$((c[2]-$6))
  [ $((dr*dr+dg*dg+db*db)) -lt 10000 ] && ok "$1 (${c[*]})" || bad "$1: expected $4 $5 $6, got ${c[*]}"
}
# (along a wide character's width: one sample can land on its soft edge, or between two of them.
# Green, as the test pictures behind the text are red)
bright() { # what, Emuera x, Emuera y up from the bottom
  local top
  top=$(od -An -v -tu1 -w4 -j $((hdr+($(sy $3)*sw+$(sx $2))*4)) -N $((s100*20/100*4)) "$T/s.raw" | awk '{print $2}' | sort -n | tail -1)
  [ "${top:-0}" -ge 150 ] && ok "$1 ($top)" || bad "$1: the brightest is ${top:-nothing}"
}
shot
pixel "a layer behind the text shows" 100 190 255 0 0
pixel "it's anchored at the bottom left, as tall as it should be" 100 215 0 0 0
# (the bottom row's text: higher up, where the gap between rows falls depends on the text size)
bright "text is drawn over a layer behind it" 100 10
pixel "a layer in front covers the text" 450 24 0 255 0
pixel "a sprite layer shows, from its picture file" 550 80 0 0 255
pixel "text drawn into a picture shows" 332 148 255 255 255
pixel "there's nothing beyond the layers" 800 150 0 0 0
# (the first may be a step that never came: a failed check, not the end of the run)
near() { [ "$1" -ge $(($2-$3)) ] 2>/dev/null && [ "$1" -le $(($2+$3)) ]; }
adb shell input tap $(sx 100) $(sy 100)
s=$(step 60) || bad "button map: $s"
[ "$(field "$s" r4)" = 17 ] && near "$(field "$s" r2)" 100 9 && near "$(field "$s" r3)" -100 19 && ok "a button map answers in the left half, at the right pixel ($s)" || bad "button map, left: $s"
adb shell input tap $(sx 300) $(sy 100)
s=$(step 61) || bad "button map: $s"
[ "$(field "$s" r4)" = 34 ] && ok "and in the right half ($s)" || bad "button map, right: $s"
adb shell input tap $(sx 800) $(sy 100)
s=$(step 62) || bad "off the map: $s"
[ "$(field "$s" r4)" = -1 ] && ok "off the map there's no button ($s)" || bad "off the map: $s"
# (the top of the screen, which positions must reach)
adb shell input tap $(sx 800) 30
s=$(step 63) || bad "top of the screen: $s"
near "$(field "$s" r3)" $((-(bottom-30)*100/s100)) 19 && ok "a tap at the top of the screen is at the top ($s)" || bad "top of the screen: $s, expected about $((-(bottom-30)*100/s100))"
s=$(step 64) || bad "CLIENTHEIGHT: $s"
near "$s" $((bottom*100/s100)) 19 && ok "CLIENTHEIGHT is what's on the screen ($s)" || bad "CLIENTHEIGHT $s, expected about $((bottom*100/s100))"
adb shell sleep 1
shot
pixel "CBGCLEAR takes the layers away" 100 190 0 0 0

echo "### crash reports"
G=files/games/erbfix-crash
adb shell am force-stop $P
ras 'rm -f files/game-running'
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
screen() { adb shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; adb exec-out cat /data/local/tmp/ui.xml; }
sees() { # a text to wait for on the screen
  local i
  for i in $(seq 1 25); do screen | grep -qF "$1" && return 0; done
  return 1
}
top() { adb shell dumpsys activity activities | grep -m1 topResumedActivity | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | head -1; }

# a script error: shown by the game, then reported on the way out
printf '@SYSTEM_TITLE\nLOCAL = 1\nLOCAL = 1 / (LOCAL - 1)\nQUIT\n' | adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'"
play erbfix-crash
for i in $(seq 1 20); do [ -n "$(ras "grep -l loaded files/engine.log")" ] && break; adb shell sleep 1; done
adb shell sleep 2
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
adb shell input tap $ex $by
sees "The game stopped with an error" && ok "a script error is reported when the game ends" || bad "no report: $(top)"
screen | grep -qiE 'division|zero|TITLE.ERB' && ok "and the report says what went wrong" || bad "the report doesn't say why"
tap_text "Share"
adb shell sleep 2
case "$(top)" in *$P*) bad "no share sheet: $(top)" ;; *) ok "Share opens the system's share sheet ($(top | cut -d/ -f1))" ;; esac
[ -z "$(pid)" ] && ok "and the game's process has ended" || bad "still running behind the share sheet"
adb shell input keyevent KEYCODE_BACK
adb shell sleep 1

# a panic in the engine: this used to leave a frozen screen
log1=$(ras 'cat files/engine.log | wc -c')
adb shell am start -S -W -n $P/.GameActivity --es game erbfix-crash --es env PANIC=1 --ez tablet "$(tablet)" >/dev/null
sees "The game stopped with an error" && ok "a panic is reported, not a frozen screen" || bad "no report after a panic: $(top)"
screen | grep -qF "PANIC is set" && ok "and the report has its message" || bad "the panic's message isn't there"
[ "$(ras 'cat files/engine.log.1 | wc -c')" = "$log1" ] && ok "the run before keeps its log" || bad "engine.log.1 has $(ras 'cat files/engine.log.1 | wc -c') bytes, expected $log1"
tap_text "Close"
adb shell sleep 2
[ -z "$(pid)" ] && ok "Close ends the game" || bad "still running after Close"
[ -z "$(ras 'ls files/game-running 2>/dev/null')" ] && ok "and nothing is reported again" || bad "the marker stayed"

# a native crash: the process just dies, so the list says so
printf '@SYSTEM_TITLE\nPRINTL waiting\nINPUT\nQUIT\n' | adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'"
play erbfix-crash
for i in $(seq 1 20); do [ -n "$(pid)" ] && break; adb shell sleep 1; done
adb shell sleep 3
game=$(pid)
ras "kill -SEGV $game"
adb shell sleep 3
[ -z "$(pid)" ] || bad "the crash didn't end the process"
adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $P/.MainActivity >/dev/null
sees "The last game stopped unexpectedly" && ok "a native crash is reported the next time the list shows" || bad "no report after a native crash: $(top)"
tap_text "Close"
adb shell sleep 1
adb shell am start -S -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $P/.MainActivity >/dev/null
adb shell sleep 2
screen | grep -qF "The last game stopped unexpectedly" && bad "reported twice" || ok "and only once"

echo "### sound"
G=files/games/erbfix-sound
adb shell am force-stop $P
ras "mkdir -p $G/CSV $G/ERB $G/sound"
gamebase $G
# noise as an 8 kHz, 8-bit mono WAV: $1 file, $2 seconds, the size below in little-endian bytes
wav() {
  local n=$(($2*8000))
  le() { printf "\\\\x%02x\\\\x%02x\\\\x%02x\\\\x%02x" $(($1&255)) $(($1>>8&255)) $(($1>>16&255)) $(($1>>24&255)); }
  { printf "RIFF$(le $((n+36)))WAVEfmt \x10\0\0\0\x01\0\x01\0\x40\x1f\0\0\x40\x1f\0\0\x01\0\x08\0data$(le $n)"; head -c $n /dev/urandom; } | adb exec-in "run-as $P sh -c 'cat > $G/sound/$1'"
}
wav long.wav 30
wav one.wav 1
head -c 4000 /dev/urandom | adb exec-in "run-as $P sh -c 'cat > $G/sound/bad.mp3'"
adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
PLAYBGM "long.wav"
CALL NEXT, 70
PLAYSOUND "long.wav"
CALL NEXT, 71
STOPSOUND
CALL NEXT, 72
SETBGMVOLUME 50
SETSOUNDVOLUME 50
CALL NEXT, 73
PLAYBGM "LONG.WAV"
CALL NEXT, 74
STOPBGM
CALL NEXT, 75
PLAYSOUND "one.wav", 3
CALL NEXT, 76
REPEAT 14
	PLAYSOUND "long.wav"
REND
CALL NEXT, 77
STOPSOUND
PLAYBGM "bad.mp3"
PLAYSOUND "bad.mp3"
PLAYSOUND "not-there.wav"
CALL NEXT, 78
QUIT

@NEXT, ARG
LOCAL = SAVETEXT("here", ARG)
INPUTMOUSEKEY
ERB
playing() { adb shell dumpsys audio | grep -cE "u/pid:[0-9]+/$(pid) state:started"; }
paused() { adb shell dumpsys audio | grep -cE "u/pid:[0-9]+/$(pid) state:paused"; }
# (Android's report can take a moment to catch up: a real failure never gets there)
audio_is() { # how many playing, how many paused
  local i
  for i in 1 2 3 4 5 6; do
    [ "$(playing)" = "$1" ] && [ "$(paused)" = "${2:-0}" ] && return 0
    adb shell sleep 1
  done
  return 1
}
marked_as_game() {
  local i
  for i in 1 2 3 4 5 6; do
    adb shell dumpsys audio | grep -E "u/pid:[0-9]+/$(pid) state:started" | grep -q USAGE_GAME && return 0
    adb shell sleep 1
  done
  return 1
}
at() { step "$1" >/dev/null || bad "step $1 never came"; adb shell sleep "${2:-2}"; }
go_on() { adb shell input tap $ex $by; }
play erbfix-sound
at 70
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
audio_is 1 && ok "PLAYBGM plays" || bad "BGM: $(playing) playing"
marked_as_game && ok "as a game's sound, which the volume keys control" || bad "not marked as a game's sound"
go_on; at 71
audio_is 2 && ok "PLAYSOUND plays over it" || bad "with an effect: $(playing) playing"
go_on; at 72
audio_is 1 && ok "STOPSOUND stops just the effect" || bad "after STOPSOUND: $(playing) playing"
adb shell input keyevent KEYCODE_HOME
adb shell sleep 2
audio_is 0 1 && ok "hiding the game pauses its sound" || bad "hidden: $(playing) playing, $(paused) paused"
icon
adb shell sleep 2
top_is_game || { bad "not back in the game: stopping here so nothing else gets tapped"; exit 1; }
audio_is 1 && ok "coming back resumes it" || bad "back: $(playing) playing"
go_on; at 73
audio_is 1 && ok "changing the volumes doesn't disturb it" || bad "after the volumes: $(playing) playing"
go_on; at 74
audio_is 1 && ok "a new PLAYBGM replaces the old one, in any letter case" || bad "second BGM: $(playing) playing"
go_on; at 75
audio_is 0 && ok "STOPBGM stops it" || bad "after STOPBGM: $(playing) playing"
go_on; at 76
audio_is 1 && ok "PLAYSOUND with a count is still going at 2 s of 3" || bad "repeats: $(playing) playing at 2 s"
adb shell sleep 3
audio_is 0 && ok "and has finished by 5 s" || bad "repeats: $(playing) still playing at 5 s"
go_on; at 77
audio_is 10 && ok "14 effects at once use the ten channels" || bad "channels: $(playing) playing"
go_on; at 78
audio_is 0 && ok "files it can't play, or that aren't there, are silence, not a crash" || bad "bad files: $(playing) playing"
game=$(pid)
go_on
for i in $(seq 1 15); do [ -z "$(pid)" ] && break; adb shell sleep 1; done
[ -n "$game" ] && [ -z "$(pid)" ] && ok "and the game ends normally after them" || bad "pid was '$game', now '$(pid)'"

echo "### text size"
G=files/games/erbfix-size
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
# a layer with a button map, and a line of text 100 half-width cells long
adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
GCREATE 1, 400, 200
GCLEAR 1, 0xFFFF0000
LOCAL = CBGSETG(1, 0, 0, 1)
GCREATE 2, 400, 200
GCLEAR 2, 0xFF000011
LOCAL = CBGSETBMAPG(2)
PRINTL ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
LOCAL = SAVETEXT(TOSTR(CLIENTWIDTH()), 67)
$AGAIN
INPUTMOUSEKEY
LOCALS = r2={RESULT:2} r3={RESULT:3} r4={RESULT:4}
LOCAL = SAVETEXT(LOCALS, 68)
GOTO AGAIN
ERB
ras "cp -r $G files/games/erbfix-size2"
sized() { # the line, as it should be: on one row, or wrapped at 80 columns
  shot
  if [ "$2" = whole ]; then
    bright "$1: the line is on one row" 762 10
  else
    pixel "$1: the line has wrapped" 762 10 0 0 0
    bright "$1: onto a second row" 100 10
    # (the middle of the second row: 19 pixels a row, grown with the text size this game was given)
    local pct
    pct=$(ras "cat shared_prefs/text-size.xml" | grep -o "name=\"${G##*/}\" value=\"[0-9]*\"" | grep -o '[0-9]*"$' | tr -dc 0-9)
    bright "$1: under a full first row" 762 $((19*${pct:-100}*3/200))
  fi
}
play erbfix-size
step 67 >/dev/null || bad "the game didn't start"
adb shell sleep 2
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
sized "as it starts" whole
tap_text "A+"
tap_text "A+"
adb shell sleep 2
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
sized "two sizes up" wrapped
pixel "a picture layer stays where it was" 100 190 255 0 0
pixel "and the same size" 100 215 0 0 0
ras "rm -f $G/txt68.txt"
adb shell input tap $(sx 100) $(sy 100)
s=$(step 68) || bad "tap at the bigger size: $s"
[ "$(field "$s" r4)" = 17 ] && near "$(field "$s" r2)" 100 9 && near "$(field "$s" r3)" -100 19 && ok "tap positions and button maps don't move ($s)" || bad "tap at the bigger size: $s"
play erbfix-size
for i in $(seq 1 15); do [ -n "$(pid)" ] && break; adb shell sleep 1; done
adb shell sleep 4
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
sized "after starting the game again" wrapped
[ "$(ras "cat $G/txt67.txt")" = 1080 ] && ok "CLIENTWIDTH is still the game's own window" || bad "CLIENTWIDTH $(ras "cat $G/txt67.txt")"
for i in 1 2 3 4 5 6; do tap_text "A+"; done
for i in 1 2 3 4 5 6; do tap_text "A-"; done
adb shell sleep 2
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
sized "back down from the largest, past its end" whole
ok "and it survived the whole range"
ras "cat shared_prefs/text-size.xml" | grep -q 'name="erbfix-size" value="100"' && ok "and the size chosen is stored" || bad "stored: $(ras "cat shared_prefs/text-size.xml")"
tap_text "A+"
tap_text "A+"
adb shell sleep 1
play erbfix-size2
# (the line is printed once the copy has its own txt67: a fixed wait once looked too early)
for i in $(seq 1 30); do [ -n "$(ras "ls files/games/erbfix-size2/txt67.txt 2>/dev/null")" ] && break; adb shell sleep 1; done
adb shell sleep 2
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
sized "in another game" whole

echo "### the smallest text a game starts with"
G=files/games/erbfix-wide
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
# a window wider than any screen's minimum: 3200 pixels at font 16 is 400 columns
printf 'WINDOW WIDTH:3200\nFONT SIZE:16\nLINE HEIGHT:16\n' | adb exec-in "run-as $P sh -c 'cat > $G/CSV/_default.config'"
printf '@SYSTEM_TITLE\nLOCAL = SAVETEXT(TOSTR(STRLENS(GETLINESTR("-"))+1), 69)\nINPUTMOUSEKEY\nQUIT\n' | adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'"
started_wide() {
  adb shell am force-stop $P
  ras "rm -f $G/txt69.txt"
  play erbfix-wide
  c=$(step 69)
  adb shell sleep 2
  top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
}
started_wide
[ "$c" -gt 20 ] && [ "$c" -lt 400 ] && ok "a game with a wide window starts with bigger text: $c of its 400 columns" || bad "started with $c columns"
for i in $(seq 1 10); do ras "cat shared_prefs/text-size.xml" | grep -q 'name="erbfix-wide" value="100"' && break; tap_text "A-"; adb shell sleep 1; done
started_wide
[ "$c" = 400 ] && ok "A- still goes down to the game's own size, and that's kept over the minimum" || bad "after A- and a restart: $c columns"

echo "### quick taps"
G=files/games/erbfix-quick
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
printf '@SYSTEM_TITLE\n$AGAIN\nINPUTMOUSEKEY\nLOCAL += 1\nLOCAL:1 = SAVETEXT(TOSTR(LOCAL), 90)\nGOTO AGAIN\n' | adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'"
play erbfix-quick
for i in $(seq 1 30); do [ -n "$(ras "grep -l loaded files/engine.log")" ] && break; adb shell sleep 1; done
adb shell sleep 3
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
# (as fast as adb goes, in the one spot: a double tap as Android would see it)
for i in $(seq 1 20); do adb shell input tap $ex $by; done
adb shell sleep 2
c=$(ras "cat $G/txt90.txt")
[ "$c" = 20 ] && ok "every quick tap counts, none taken for a double tap" || bad "$c of 20 quick taps counted"

echo "### turning the screen"
G=files/games/erbfix-turn
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
# (wider than any screen's minimum, so its text starts at the minimum whichever way up)
printf 'WINDOW WIDTH:3200\nFONT SIZE:16\nLINE HEIGHT:16\n' | adb exec-in "run-as $P sh -c 'cat > $G/CSV/_default.config'"
adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
GCREATE 1, 400, 200
GCLEAR 1, 0xFFFF0000
LOCAL = CBGSETG(1, 0, 0, 1)
$AGAIN
LOCAL = SAVETEXT(TOSTR(STRLENS(GETLINESTR("-"))+1), 69)
INPUTMOUSEKEY 100
IF RESULT:0 == 1
	LOCALS = x={RESULT:2} y={RESULT:3}
	LOCAL = SAVETEXT(LOCALS, 68)
ENDIF
GOTO AGAIN
ERB
turned() { # a rotation: turns the screen, then checks the game on it
  adb shell wm user-rotation lock $1
  adb shell sleep 3
  top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
  find_view
  s100=$((width*100/3200))
  cols=$(ras "cat $G/txt69.txt")
  screen_size
  local at="at ${scr[0]}x${scr[1]}"
  [ $((width*10)) -ge $((scr[0]*9)) ] && [ $((enter[3]*10)) -ge $((scr[1]*9)) ] && ok "$at the game fills the screen (to $right, ${enter[3]})" || bad "$at the game only reaches $right, ${enter[3]}"
  shot
  pixel "$at a picture layer shows" 100 100 255 0 0
  pixel "$at it's its own size" 100 260 0 0 0
  ras "rm -f $G/txt68.txt"
  adb shell input tap $(sx 100) $(sy 100)
  s=$(step 68) || bad "tap $at: $s"
  near "$(field "$s" x)" 100 9 && near "$(field "$s" y)" -100 19 && ok "$at a tap lands where it should ($s)" || bad "tap $at: $s"
}
ras "rm -f $G/txt69.txt"
play erbfix-turn
step 69 >/dev/null || bad "the game didn't start"
adb shell sleep 2
turned 0
cols0=$cols; width0=$width; wide0=$((scr[0]>scr[1]))
turned 1
wide1=$((scr[0]>scr[1]))
near $((cols*width0/width)) "$cols0" 3 && ok "the text stays the same size on the screen: $cols0 columns in $width0 pixels, $cols in $width" || bad "text: $cols0 columns in $width0 pixels, $cols in $width"
dp=$(( (scr[0]<scr[1]?scr[0]:scr[1])*160/$(adb shell wm density | tail -1 | grep -oE '[0-9]+') ))
if [ "$dp" -ge 600 ]; then
  [ "$wide0" != "$wide1" ] && ok "a tablet ($dp dp) turns with the screen" || bad "a tablet ($dp dp) didn't turn"
else
  [ "$wide0$wide1" = 11 ] && ok "a phone ($dp dp) stays in landscape" || bad "a phone ($dp dp) left landscape"
fi
tap_text "A-"
adb shell sleep 2
chosen=$(ras "cat $G/txt69.txt")
turned 0
[ "$cols" = "$chosen" ] && ok "a size the player chose stays when it turns ($chosen columns)" || bad "chose $chosen columns, then $cols"

echo "### the game's menu and settings"
G=files/games/erbfix-menu
ras "mkdir -p $G/CSV $G/ERB"
gamebase $G
# the title notes the save slots the game has (txt80) and saves to slot 1; each tap at its WAIT notes the
# slots again (txt81), and what MARK.ERB says (txt82)
adb exec-in "run-as $P sh -c 'cat > $G/ERB/TITLE.ERB'" <<'ERB'
@SYSTEM_TITLE
LOCAL = SAVETEXT(TOSTR(GETCONFIG("表示するセーブデータ数")), 80)
SAVEDATA 1, "menu test"
PRINTL the title
$AGAIN
WAIT
LOCAL = SAVETEXT(TOSTR(GETCONFIG("表示するセーブデータ数")), 81)
LOCAL = SAVETEXT(MARK(), 82)
GOTO AGAIN
ERB
mark() { printf '@MARK\n#FUNCTIONS\nRETURNF "%s"\n' "$1" | adb exec-in "run-as $P sh -c 'cat > $G/ERB/MARK.ERB'"; }
mark before
slots() { # a value for the settings dialog's "Number of save slots", then Save
  tap_text "Number of save slots" content-desc || return 1
  adb shell input keyevent KEYCODE_MOVE_END
  for i in 1 2 3 4 5 6; do adb shell input keyevent KEYCODE_DEL; done
  adb shell input text "$1"
  # (the keyboard could be over the dialog's buttons; back only hides it while it shows)
  adb shell dumpsys input_method | grep -q "mInputShown=true" && adb shell input keyevent KEYCODE_BACK
  tap_text "Save"
}
config() { ras "cat $G/emuera.config" | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//'; } # (Emuera's files start with a BOM)
# (as play does: a game stopped mid-run would have its report cover the list)
adb shell am force-stop $P
ras 'rm -f files/game-running'
adb shell am start -W -n $P/.MainActivity >/dev/null
tap_text "Settings for erbfix-menu" content-desc && slots 40
adb shell sleep 1
config | grep -qx "表示するセーブデータ数:40" && ok "the list's settings write the game's emuera.config" || bad "emuera.config: $(config)"
play erbfix-menu
[ "$(step 80)" = 40 ] && ok "and the game starts with them" || bad "save slots at the start: $(ras "cat $G/txt80.txt")"
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
ras "rm -f $G/txt81.txt"
tap_text "Game menu" content-desc && tap_text "Game settings…" && slots 30
adb shell sleep 1
top_is_game || { bad "not back in the game: stopping here so nothing else gets tapped"; exit 1; }
find_view
adb shell input tap $(((left+right)/2)) $((bottom/2))
[ "$(step 81)" = 30 ] && ok "settings changed in the game's menu reach the running game" || bad "save slots after the menu: $(ras "cat $G/txt81.txt")"
ras "rm -f $G/txt80.txt"
# (the menu's item, then the question's button: the menu has gone by then)
tap_text "Game menu" content-desc && tap_text "Back to the title" && adb shell sleep 1 && tap_text "Back to the title"
[ "$(step 80)" = 30 ] && ok "the menu goes back to the title" || bad "no title again: $(ras "cat $G/txt80.txt")"
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
ras "rm -f $G/txt81.txt"
tap_text "Game menu" content-desc && tap_text "Game settings…" && tap_text "Game's defaults"
adb shell sleep 1
config | grep -q "表示するセーブデータ数" && bad "the player's value is still there: $(config)" || ok "Game's defaults takes the player's values out"
adb shell input tap $(((left+right)/2)) $((bottom/2))
[ "$(step 81)" = 20 ] && ok "and the running game is back at Emuera's 20 slots" || bad "save slots after the defaults: $(ras "cat $G/txt81.txt")"
mark after
ras "rm -f $G/txt82.txt"
tap_text "Game menu" content-desc && tap_text "Reload ERB files"
adb shell sleep 2
adb shell input tap $(((left+right)/2)) $((bottom/2))
[ "$(step 82)" = after ] && ok "Reload ERB files runs the changed script, the game going on" || bad "after reloading: $(ras "cat $G/txt82.txt")"
# the saves: where the game keeps them, and where the save manager keeps what it replaces
sav() { ras "ls $G/$1 $G/sav/$1 2>/dev/null"; }
kept() { ras "ls files/data/emuera-tty/backups/erbfix-menu/*/$1 2>/dev/null"; }
[ -n "$(sav save01.sav)" ] || bad "the title didn't save to slot 1"
tap_text "Game menu" content-desc && tap_text "Manage saves…" && tap_text "slot 01 " text start && tap_text "Copy to slot…" &&
  tap_text "Slot" content-desc && adb shell input keyevent KEYCODE_MOVE_END && adb shell input keyevent KEYCODE_DEL && adb shell input keyevent KEYCODE_DEL && adb shell input text 5
adb shell dumpsys input_method | grep -q "mInputShown=true" && adb shell input keyevent KEYCODE_BACK
tap_text "OK"
adb shell sleep 1
[ -n "$(sav save05.sav)" ] && ok "the save manager copies a save to another slot" || bad "no save05: $(ras "ls $G $G/sav 2>/dev/null" | tr '\n' ' ')"
# (the copy put the list up again)
tap_text "slot 05 " text start && tap_text "Delete" && adb shell sleep 1 && tap_text "Delete"
adb shell sleep 1
[ -z "$(sav save05.sav)" ] && [ -n "$(kept save05.sav)" ] && ok "and deletes one, keeping it in the backups" || bad "delete: save05 '$(sav save05.sav)', kept '$(kept save05.sav)'"
tap_text "Back up all saves now"
for i in $(seq 1 10); do [ -n "$(kept save01.sav)" ] && break; adb shell sleep 1; done
[ -n "$(kept save01.sav)" ] && ok "and backs them all up" || bad "no backup of save01: $(ras "ls -R files/data/emuera-tty/backups 2>/dev/null" | tr '\n' ' ')"
tap_text "Close"
adb shell sleep 1
top_is_game || { bad "not in the game: stopping here so nothing else gets tapped"; exit 1; }
old=$(pid)
ras "rm -f $G/txt80.txt"
tap_text "Game menu" content-desc && tap_text "Restart the game" && adb shell sleep 1 && tap_text "Restart"
step 80 >/dev/null || bad "the game didn't start again"
adb shell sleep 1
[ -n "$(pid)" ] && [ "$(pid)" != "$old" ] && top_is_game && ok "Restart the game starts it again in a new process" || bad "restart: pid $old, then '$(pid)', top: $(adb shell dumpsys activity activities | grep -m1 topResumedActivity | cut -c1-90)"

echo "### the player's own games"
[ "$before" = "$(others)" ] && ok "all $(printf '%s' "$before" | grep -c .) other files unchanged" || bad "other games' files changed"

echo "RESULT: $passes passed, $fails failed"
[ "$fails" = 0 ]
