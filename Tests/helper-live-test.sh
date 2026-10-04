#!/bin/bash
#
# Live test of the charge-control helper on real hardware. Run from the
# repository folder AFTER installing the helper (sudo bash install-helper.sh),
# with the charger plugged in and the battery above 57%:
#
#     bash Tests/helper-live-test.sh            # hold, discharge, heat, top-up
#     bash Tests/helper-live-test.sh --sleep    # also the sleep-safety check
#
# It talks to the helper exactly like the app does (one JSON line over
# /var/run/kwikbattery.sock), checks what macOS and the SMC report, and always
# puts charging back to normal at the end, even if interrupted.
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
}
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

say "4. Pause charging when hot (limit dropped to 30 °C so it triggers now)"
S="$(policy '{"enabled":false,"pauseWhenHot":true,"hotLimitCelsius":30}')"
T="$(field "$S" temperatureC)"
if [[ -z "$T" ]]; then
  bad "the helper can't read the battery temperature"
elif [[ "$(field "$S" hotPaused)" == "true" && "$(field "$S" mode)" == "hold" ]]; then
  ok "paused at ${T} °C ($(field "$S" reason))"
  [[ "$(field "$S" emulatedHold)" == "true" ]] && { wait_for source_state 20 "Battery Power" && ok "charging stopped (adapter off)" || bad "source = $(source_state)"; }
else
  bad "not paused at ${T} °C: mode=$(field "$S" mode) hotPaused=$(field "$S" hotPaused)"
fi
S="$(policy '{"enabled":false,"pauseWhenHot":true,"hotLimitCelsius":50}')"
[[ "$(field "$S" mode)" == "normal" && "$(field "$S" hotPaused)" != "true" ]] && ok "limit raised to 50 °C: charging resumes" || bad "mode=$(field "$S" mode) hotPaused=$(field "$S" hotPaused)"
wait_for source_state 20 "AC Power" && ok "back on AC power" || bad "source = $(source_state)"

say "5. Top up past the limit"
policy "{\"enabled\":true,\"limit\":$LIMIT,\"pauseWhenHot\":false}" >/dev/null
S="$(send '{"cmd":"topUpNow","target":100}')"
[[ "$(field "$S" topUpActive)" == "true" && "$(field "$S" mode)" == "normal" ]] && ok "topping up: $(field "$S" reason)" || bad "mode=$(field "$S" mode) topUp=$(field "$S" topUpActive)"
S="$(send '{"cmd":"cancelTopUp"}')"
[[ "$(field "$S" topUpActive)" != "true" && "$(field "$S" mode)" == "hold" ]] && ok "cancelled: back to holding" || bad "mode=$(field "$S" mode) topUp=$(field "$S" topUpActive)"

if [[ "${1:-}" == "--sleep" ]]; then
  say "6. Sleep safety: discharge, then sleep. WAKE THE MAC (press a key) after ~20 s."
  policy "{\"enabled\":true,\"limit\":$((P - 3)),\"autoDischarge\":true,\"dischargeTolerance\":1,\"pauseWhenHot\":false}" >/dev/null
  wait_for source_state 20 "Battery Power" || bad "didn't start discharging"
  MARK="$(date '+%Y-%m-%d %H:%M:%S')"
  sleep 2; pmset sleepnow >/dev/null; sleep 15
  if log show --style compact --start "$MARK" --predicate 'eventMessage CONTAINS "kwikbatteryd: system will sleep"' 2>/dev/null \
       | grep -q 'adapter switched back on: true'; then
    ok "the helper switched the adapter on before sleeping"
  else
    bad "no 'adapter switched back on' log entry before sleep"
  fi
fi

say "Restoring normal charging"
restore
wait_for source_state 20 "AC Power" && ok "on AC power, charging normally" || bad "source = $(source_state)"
open -a KwikBattery >/dev/null 2>&1 || open "$HOME/Applications/KwikBattery.app" >/dev/null 2>&1

echo
echo "Helper live test: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
