# Testing KwikBattery

Thanks for helping test. This takes about five minutes.

## 1. Install

Open **Terminal**, paste this and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/ranvirskh/kwikbattery/main/install.sh | bash
```

A battery icon with a percentage appears in the menu bar. Click it, then skip to step 2.

If you'd rather not use Terminal:

1. Download the latest `KwikBattery-x.y.zip` from [Releases](https://github.com/ranvirskh/kwikbattery/releases) and unzip it.
2. Move **KwikBattery.app** to **Applications** and open it.
3. macOS will warn that it can't verify the app. Go to **System Settings › Privacy & Security** and click **Open Anyway**.
4. A battery icon with a percentage appears in the menu bar. Click it.

## 2. Check these

| # | What to check | Expected |
|---|---|---|
| 1 | Menu bar icon | Shows your battery % inside the icon. The color is green above 20%, orange from 20% to 10%, and red below 10%. |
| 2 | Dropdown › Battery Information | Health %, cycle count, temperature and capacity roughly match **System Settings › Battery › Battery Health** and **System Information › Power**. |
| 3 | Dropdown › Power & Electrical, **plugged in** | The status says Charging or On Adapter. Voltage, current and watts show numbers, not "—", and change every second or two. |
| 4 | Same, **unplugged** | The status says Discharging. The charger box disappears, and "On battery • X W" shows a sensible number (usually 3–30 W). |
| 5 | Plug in a phone or USB device | A "devices" ribbon appears with a wattage. Devices plugged in over USB show "≈" because that figure is an estimate. |
| 6 | Dropdown › Connected Devices | AirPods, mouse and keyboard battery levels appear if they're connected. |
| 7 | Settings (gear icon) | The toggles work, and "Send Test Notification" shows a notification. |

Note which rows look wrong, and take screenshots if you can.


## 2b. New in 1.11

| # | What to check | Expected |
|---|---|---|
| 8 | Click the big percentage, then **Temperature** | A temperature line with your hot limit dashed; tiles for coolest, warmest and time hot. (Needs a few hours of history.) |
| 9 | Click the Health tile | After ~3 weeks of readings, a line like "Falling about 1.5% a month. On this trend it reaches 80% around …". |
| 10 | Settings › Notifications › app energy alert | Toggle and slider work. Burn CPU in one app on battery for ~10 minutes: an alert with Quit App and Don't Warn buttons. |
| 11 | Settings › Charge control (helper installed, a limit set) | A "Held below full for … h this week" line appears after the limit has held for a minute. |
| 12 | Settings › Low Power Mode (helper version 3) | Add hours covering now, with "Only while on battery" off: Low Power Mode switches on within ~10 s, and off when the window ends. |
| 13 | Terminal: `~/Applications/KwikBattery.app/Contents/MacOS/KwikBattery --charge-limit current` | Prints "Charge limit set to NN%." and Settings shows it within seconds. |
| 14 | `bash Tests/helper-live-test.sh --schedule` | Hold, discharge, heat, top-up, schedule and Low Power Mode checks all PASS (it restores your settings). |

## If your iPhone doesn't appear

Wi-Fi device lookups need **System Settings › Privacy & Security › Local Network**
turned on for KwikBattery. Check that first, then re-open the dropdown.

## 3. Send a diagnostic report

Paste this into **Terminal**. It creates `kwikbattery-report.txt` on your Desktop:

```bash
APP="/Applications/KwikBattery.app"; [ -d "$APP" ] || APP="$HOME/Applications/KwikBattery.app"; { echo "== macOS =="; sw_vers; echo "== CPU =="; sysctl -n machdep.cpu.brand_string; uname -m; echo "== Model =="; sysctl -n hw.model; echo "== KwikBattery SMC =="; "$APP/Contents/MacOS/KwikBattery" --smc-diag; echo "== Battery (IORegistry) =="; ioreg -rn AppleSmartBattery | grep -E '"(Voltage|Amperage|InstantAmperage|AppleRawMaxCapacity|MaxCapacity|NominalChargeCapacity|DesignCapacity|CycleCount|Temperature|IsCharging|ExternalConnected|FullyCharged|AdapterDetails|PowerTelemetryData)"'; echo "== pmset =="; pmset -g batt; } > ~/Desktop/kwikbattery-report.txt 2>&1; echo "Report saved to Desktop"
```

Send the file along with your notes to the developer. It contains only battery, power and hardware-model information, and no personal data.
