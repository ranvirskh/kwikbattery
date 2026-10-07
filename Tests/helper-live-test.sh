#!/bin/bash
#
# Live test of the charge-control helper on real hardware. Run from the
# repository folder AFTER installing the helper (sudo bash install-helper.sh),
# with the charger plugged in and the battery above 57%:
#
#     bash Tests/helper-live-test.sh              # hold, discharge, heat, top-up, Low Power Mode
#     bash Tests/helper-live-test.sh --schedule   # also: a scheduled top-up fires at its time (~2 min)
#     bash Tests/helper-live-test.sh --sleep      # also the sleep-safety check
#     (flags can be combined)
#
# It talks to the helper exactly like the app does (one JSON line over
# /var/run/kwikbattery.sock), checks what macOS and the SMC report, and always
# puts charging back to normal at the end, even if interrupted, and puts your
# own charge-control settings back the way they were, and Low Power Mode back to
# what it was for the power source in use (if you use "Only on Battery", check
# System Settings > Battery afterwards: the test can only set both sources alike).
#
set -uo pipefail
SOCK=/var/run/kwikbattery.sock
HELPER=/Library/PrivilegedHelperTools/kwikbatteryd
PASS=0; FAIL=0

say()  { printf '\n== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }

send() { printf '%s\n' "$1" | nc -U "$SOCK" 2>/dev/null; }
field() { plutil -extract "$2" raw -o - - <<<"$1" 2>/dev/null; }   # $1 = JSON, $2 = key
status() { send '{"cmd":"status"}'; }
policy() { send "{\"cmd\":\"setPolicy\",\"policy\":$1}"; }
source_state() { pmset -g batt | head -1 | sed -E "s/.*'(.*)'.*/\1/"; }   # "AC Power" / "Battery Power"
percent() { pmset -g batt | grep -oE '[0-9]+%' | head -1 | tr -d '%'; }
chie() { "$HELPER" --probe 2>/dev/null | awk '$1 == "CHIE" { print $5 }'; }

restore() {
  policy '{"enabled":false,"pauseWhenHot":true,"hotLimitCelsius":40}' >/dev/null
  send '{"cmd":"restore"}' >/dev/null
  # Your own settings (limit, schedules, Low Power Mode rules) go back as they were.
  [[ -n "${ORIGINAL_POLICY:-}" ]] && policy "$ORIGINAL_POLICY" >/dev/null
  case "${ORIGINAL_LPM:-}" in
    1) send '{"cmd":"setLowPower","lowPower":true}' >/dev/null ;;
    0) send '{"cmd":"setLowPower","lowPower":false}' >/dev/null ;;
  esac
}
# "lowpowermode N" on older macOS, "powermode N" (1 = Low Power) on newer.
lpm() { pmset -g | awk '$1 == "lowpowermode" { l = $2 } $1 == "powermode" { p = ($2 == 1 ? 1 : 0) } END { if (l != "") print l; else if (p != "") print p }'; }
ORIGINAL_POLICY=""; ORIGINAL_LPM=""
FLAGS=" $* "
trap 'echo; echo "Interrupted: restoring normal charging."; restore; exit 1' INT TERM

# Wait up to $2 seconds for `$1` (a command) to print $3.
wait_for() {
  local i
  for ((i = 0; i < $2; i += 2)); do
    [[ "$($1)" == "$3" ]] && return 0
    sleep 2
  done
  return 1
}

say "Preflight"
[[ -S "$SOCK" ]] || { echo "  The helper isn't running. Install it first: sudo bash install-helper.sh"; exit 1; }
osascript -e 'quit app "KwikBattery"' >/dev/null 2>&1   # so the app can't push its own settings mid-test
S="$(status)"
[[ -n "$S" ]] && ok "helper answers (version $(field "$S" version))" || { bad "helper doesn't answer"; exit 1; }
ORIGINAL_POLICY="$(plutil -extract policy json -o - - <<<"$S" 2>/dev/null)"
ORIGINAL_LPM="$(lpm)"
lpm_source() { pmset -g custom | awk -v want="$1" '/^Battery Power:/ { s = "battery" } /^AC Power:/ { s = "ac" } $1 == "lowpowermode" && s == want { print $2 } $1 == "powermode" && s == want { print ($2 == 1 ? 1 : 0) }'; }
LPM_BATTERY="$(lpm_source battery)"; LPM_AC="$(lpm_source ac)"
ORIG_ENABLED="$(plutil -extract enabled raw -o - - <<<"$ORIGINAL_POLICY" 2>/dev/null)"
HELPER_VERSION="$(field "$S" version)"
echo "  keys: charge=$(field "$S" chargeKey) adapter=$(field "$S" adapterKey) emulatedHold=$(field "$S" emulatedHold)"
echo "  battery temperature: $(field "$S" temperatureC) °C"
[[ "$(source_state)" == "AC Power" ]] || { echo "  Plug the charger in first."; exit 1; }
P="$(percent)"
(( P >= 57 )) || { echo "  The battery is at $P%; charge it above 57% first."; exit 1; }
echo "  battery $P%, on AC"
LIMIT=$(( P - 2 ))

say "1. Hold at the limit ($LIMIT%)"
S="$(policy "{\"enabled\":true,\"limit\":$LIMIT,\"sailingRange\":3,\"pauseWhenHot\":false}")"
[[ "$(field "$S" mode)" == "hold" ]] && ok "mode = hold ($(field "$S" reason))" || bad "mode = $(field "$S" mode), expected hold"
if [[ "$(field "$S" emulatedHold)" == "true" ]]; then
  wait_for source_state 20 "Battery Power" && ok "macOS runs from the battery (adapter switched off)" || bad "macOS still on $(source_state)"
  [[ "$(chie)" == "08" ]] && ok "CHIE = 08" || bad "CHIE = $(chie), expected 08"
else
  sleep 6
  [[ "$(source_state)" == "AC Power" ]] && ok "still on AC with charging inhibited" || bad "source = $(source_state)"
fi

say "2. Turning charge control off restores normal charging"
S="$(policy '{"enabled":false,"pauseWhenHot":false}')"
[[ "$(field "$S" mode)" == "normal" ]] && ok "mode = normal" || bad "mode = $(field "$S" mode)"
wait_for source_state 20 "AC Power" && ok "back on AC power" || bad "source = $(source_state)"
[[ "$(chie)" == "00" ]] && ok "CHIE = 00" || bad "CHIE = $(chie), expected 00"

say "3. Automatic discharge (limit $((P - 3))%)"
S="$(policy "{\"enabled\":true,\"limit\":$((P - 3)),\"autoDischarge\":true,\"dischargeTolerance\":1,\"pauseWhenHot\":false}")"
[[ "$(field "$S" mode)" == "discharge" ]] && ok "mode = discharge ($(field "$S" reason))" || bad "mode = $(field "$S" mode), expected discharge"
wait_for source_state 20 "Battery Power" && ok "running from the battery while plugged in" || bad "source = $(source_state)"
policy '{"enabled":false,"pauseWhenHot":false}' >/dev/null
wait_for source_state 20 "AC Power" && ok "adapter back on" || bad "source = $(source_state)"

say "4. Pause charging when hot (the helper is told the battery is 42 °C for this step)"
policy '{"enabled":false,"pauseWhenHot":true,"hotLimitCelsius":40}' >/dev/null
S="$(send '{"cmd":"simulateHeat","temperature":42}')"
if [[ "$(field "$S" hotPaused)" == "true" && "$(field "$S" mode)" == "hold" ]]; then
  ok "paused at $(field "$S" temperatureC) °C ($(field "$S" reason))"
  if [[ "$(field "$S" emulatedHold)" == "true" ]]; then
    wait_for source_state 20 "Battery Power" && ok "charging stopped (adapter off)" || bad "source = $(source_state)"
  fi
else
  bad "not paused: mode=$(field "$S" mode) hotPaused=$(field "$S" hotPaused) temp=$(field "$S" temperatureC)"
fi
S="$(send '{"cmd":"simulateHeat","temperature":0}')"
REAL="$(field "$S" temperatureC)"
if [[ "$(field "$S" mode)" == "normal" && "$(field "$S" hotPaused)" != "true" ]]; then
  ok "back to the real ${REAL} °C: charging resumes"
else
  bad "still paused at ${REAL} °C: mode=$(field "$S" mode)"
fi
wait_for source_state 20 "AC Power" && ok "back on AC power" || bad "source = $(source_state)"
S="$(policy '{"enabled":false,"pauseWhenHot":false}')"
S="$(send '{"cmd":"simulateHeat","temperature":45}')"
[[ "$(field "$S" mode)" == "normal" ]] && ok "with pause-when-hot off, 45 °C doesn't pause" || bad "mode=$(field "$S" mode)"
send '{"cmd":"simulateHeat","temperature":0}' >/dev/null

say "5. Top up past the limit"
P="$(percent)"
LIMIT=$(( P - 2 ))
policy "{\"enabled\":true,\"limit\":$LIMIT,\"pauseWhenHot\":false}" >/dev/null
S="$(send '{"cmd":"topUpNow","target":100}')"
if (( P >= 100 )); then
  [[ "$(field "$S" topUpActive)" != "true" && "$(field "$S" mode)" == "hold" ]] \
    && ok "already at 100%: the top-up finishes at once and the limit holds" \
    || bad "at 100%: mode=$(field "$S" mode) topUp=$(field "$S" topUpActive)"
else
  [[ "$(field "$S" topUpActive)" == "true" && "$(field "$S" mode)" == "normal" ]] \
    && ok "topping up: $(field "$S" reason)" || bad "mode=$(field "$S" mode) topUp=$(field "$S" topUpActive)"
fi
S="$(send '{"cmd":"cancelTopUp"}')"
[[ "$(field "$S" topUpActive)" != "true" && "$(field "$S" mode)" == "hold" ]] && ok "cancelled: back to holding" || bad "mode=$(field "$S" mode) topUp=$(field "$S" topUpActive)"

if [[ "$FLAGS" == *" --schedule "* ]]; then
  say "5b. A scheduled top-up fires at its time"
  P="$(percent)"
  if (( P >= 99 )); then
    echo "  skipped: the battery is at $P%, so a top-up to 100% would finish at once"
  else
    LIMIT=$(( P - 2 ))
    W=$(( $(date -v+1M +%w) + 1 ))                       # Calendar weekday: 1 = Sunday
    MINUTE=$(( 10#$(date -v+1M +%H) * 60 + 10#$(date -v+1M +%M) ))
    UUID="$(uuidgen)"
    S="$(policy "{\"enabled\":true,\"limit\":$LIMIT,\"pauseWhenHot\":false,\"schedules\":[{\"id\":\"$UUID\",\"enabled\":true,\"weekdays\":[$W],\"minuteOfDay\":$MINUTE,\"targetPercent\":100}]}")"
    [[ "$(field "$S" topUpActive)" != "true" && "$(field "$S" mode)" == "hold" ]] \
      && ok "before its time the limit still holds" || bad "mode=$(field "$S" mode) topUp=$(field "$S" topUpActive)"
    echo "  waiting up to 2 minutes for $(date -v+1M +%H:%M)…"
    FIRED=0
    for ((i = 0; i < 120; i += 3)); do
      S="$(status)"
      if [[ "$(field "$S" topUpActive)" == "true" ]]; then FIRED=1; break; fi
      sleep 3
    done
    (( FIRED )) && ok "the schedule fired: $(field "$S" reason)" || bad "the schedule never started a top-up"
    send '{"cmd":"cancelTopUp"}' >/dev/null
  fi
fi

if (( ${HELPER_VERSION:-0} >= 3 )); then
  say "5c. Low Power Mode"
  send '{"cmd":"setLowPower","lowPower":true}' >/dev/null
  [[ "$(lpm)" == "1" ]] && ok "switched on by hand (pmset reports it)" || bad "lowpowermode = $(lpm)"
  send '{"cmd":"setLowPower","lowPower":false}' >/dev/null
  [[ "$(lpm)" == "0" ]] && ok "switched off by hand" || bad "lowpowermode = $(lpm)"

  NOW=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  IN_START=$(( (NOW + 1440 - 1) % 1440 )); IN_END=$(( (NOW + 3) % 1440 ))
  OUT_START=$(( (NOW + 60) % 1440 ));      OUT_END=$(( (NOW + 120) % 1440 ))
  window() {   # $1 start, $2 end
    echo "{\"id\":\"$(uuidgen)\",\"enabled\":true,\"weekdays\":[1,2,3,4,5,6,7],\"startMinute\":$1,\"endMinute\":$2}"
  }
  S="$(policy "{\"enabled\":false,\"pauseWhenHot\":false,\"lowPower\":{\"enabled\":true,\"belowPercent\":0,\"windowsOnBatteryOnly\":false,\"windows\":[$(window $IN_START $IN_END)]}}")"
  wait_for lpm 15 "1" && ok "a window containing now switches Low Power Mode on" || bad "lowpowermode = $(lpm)"
  [[ "$(field "$(status)" lowPowerManaged)" == "true" ]] && ok "the helper reports it owns it" || bad "lowPowerManaged = $(field "$(status)" lowPowerManaged)"

  S="$(policy "{\"enabled\":false,\"pauseWhenHot\":false,\"lowPower\":{\"enabled\":true,\"belowPercent\":0,\"windowsOnBatteryOnly\":false,\"windows\":[$(window $OUT_START $OUT_END)]}}")"
  wait_for lpm 15 "0" && ok "when the window ends it switches it off again" || bad "lowpowermode = $(lpm)"

  # Turned on by the user first: the schedule must leave it alone afterwards.
  send '{"cmd":"setLowPower","lowPower":true}' >/dev/null
  S="$(policy "{\"enabled\":false,\"pauseWhenHot\":false,\"lowPower\":{\"enabled\":true,\"belowPercent\":0,\"windowsOnBatteryOnly\":false,\"windows\":[$(window $IN_START $IN_END)]}}")"
  sleep 7
  [[ "$(field "$(status)" lowPowerManaged)" != "true" ]] && ok "already on: the helper doesn't claim it" || bad "the helper claimed a Low Power Mode it didn't switch on"
  S="$(policy "{\"enabled\":false,\"pauseWhenHot\":false,\"lowPower\":{\"enabled\":true,\"belowPercent\":0,\"windowsOnBatteryOnly\":false,\"windows\":[$(window $OUT_START $OUT_END)]}}")"
  sleep 7
  [[ "$(lpm)" == "1" ]] && ok "and it stays on when the window ends" || bad "lowpowermode = $(lpm); the helper switched off something it didn't turn on"
  send '{"cmd":"setLowPower","lowPower":false}' >/dev/null
else
  say "5c. Low Power Mode"
  echo "  skipped: the installed helper is version ${HELPER_VERSION:-?}; run: sudo bash install-helper.sh"
fi

if [[ "$FLAGS" == *" --sleep "* ]]; then
  say "6. Sleep safety: discharge, then sleep. WAKE THE MAC (press a key) after ~20 s."
  policy "{\"enabled\":true,\"limit\":$((P - 3)),\"autoDischarge\":true,\"dischargeTolerance\":1,\"pauseWhenHot\":false}" >/dev/null
  wait_for source_state 20 "Battery Power" && ok "discharging before sleep" || bad "didn't start discharging"
  BEFORE="$(field "$(status)" lastSleepAt)"
  sleep 2; pmset sleepnow >/dev/null; sleep 15
  S="$(status)"
  AFTER="$(field "$S" lastSleepAt)"
  if [[ -n "$AFTER" && "$AFTER" != "$BEFORE" ]]; then
    [[ "$(field "$S" lastSleepAdapterOn)" == "true" ]] && ok "the helper switched the adapter back on before sleeping" \
      || bad "the helper saw the sleep but the adapter wasn't confirmed on"
  else
    bad "the helper didn't see the sleep (lastSleepAt unchanged: '$AFTER')"
  fi
  [[ "$(field "$S" mode)" == "discharge" ]] && ok "after waking it resumes the policy (discharge)" || echo "  note: after wake mode = $(field "$S" mode)"
fi

say "Restoring your settings"
restore
if [[ "$ORIG_ENABLED" == "true" ]]; then
  echo "  your charge-control settings are back (they manage charging, so the Mac is on: $(source_state))"
  ok "settings restored"
else
  wait_for source_state 20 "AC Power" && ok "on AC power, charging normally" || bad "source = $(source_state)"
fi
open -a KwikBattery >/dev/null 2>&1 || open "$HOME/Applications/KwikBattery.app" >/dev/null 2>&1

if [[ -n "$LPM_BATTERY" && -n "$LPM_AC" && "$LPM_BATTERY" != "$LPM_AC" ]]; then
  echo
  echo "  Note: Low Power Mode was set differently for battery ($LPM_BATTERY) and charger ($LPM_AC)."
  echo "  Check System Settings > Battery > Low Power Mode and set it back if it changed."
fi

echo
echo "Helper live test: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
