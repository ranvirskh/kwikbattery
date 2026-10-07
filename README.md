# KwikBattery

A free, native macOS menu bar app for your battery and power. Every feature is included: no paywalls, subscriptions or accounts, and no tracking of you.

## Install

### Recommended: one line in Terminal

Open **Terminal** (press ⌘-Space, type *Terminal*, press Return), paste this and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/ranvirskh/kwikbattery/main/install.sh | bash
```

It downloads the latest release, checks its signature, puts it in Applications, sets up iPhone and iPad battery levels and opens it. There are no Gatekeeper steps, because a file downloaded with Terminal isn't quarantined the way a browser download is. Run the same line again any time to update. You can read [install.sh](install.sh) first if you like.

### Other way: download it yourself

**1. Download it.**
Go to the [Releases](https://github.com/ranvirskh/kwikbattery/releases) page and
click `KwikBattery-x.y.zip` under **Assets**. It lands in your **Downloads**
folder. Safari unzips it for you; in Chrome or Firefox, double-click the `.zip`.

**2. Move it to Applications.**
Open a Finder window, drag **KwikBattery.app** from Downloads into
**Applications**.

**3. Open it — macOS will refuse the first time.**
Double-click **KwikBattery**. You'll get one of two dialogs:

- *"Apple could not verify "KwikBattery" is free of malware…"* → click **Done**.
- *""KwikBattery" is damaged and can't be opened."* → click **Cancel**, then skip
  to the Terminal method below. This wording means macOS won't offer the
  Open Anyway button, so clicking through Settings won't work.

**4. Approve it in System Settings.**

1. Click the  menu in the top-left corner → **System Settings**.
2. In the sidebar, scroll down and click **Privacy & Security**.
3. Scroll the right-hand pane all the way to the bottom, to the **Security**
   section.
4. You'll see: *""KwikBattery" was blocked to protect your Mac."* Click the
   **Open Anyway** button next to it.
5. Authenticate with Touch ID, or type your Mac login password and click
   **Unlock**.
6. A final dialog asks *"Are you sure you want to open it?"* — click
   **Open Anyway**.

**5. Done.** The battery icon appears in your menu bar, on the right. There's no
Dock icon and no window — click the menu bar icon to open the panel.

You only do this once. Updates you install from inside the app don't trigger it
again.

### Terminal method (faster, and the fix if you got the "damaged" message)

Open **Terminal** (Applications › Utilities › Terminal, or press ⌘Space and type
"Terminal"), paste this and press Return:

```bash
xattr -dr com.apple.quarantine /Applications/KwikBattery.app && open /Applications/KwikBattery.app
```

Nothing prints if it worked — the app just opens.

### Why any of this is necessary

macOS tags every file a browser downloads with a "quarantine" flag, and refuses
to launch a quarantined app unless it's notarized by Apple. Notarizing requires
a paid Apple Developer account ($99/year), which KwikBattery doesn't have, so
the app is signed locally instead. The app isn't damaged and nothing is wrong
with it; macOS simply can't trace it to a paying developer. You can read every
line of source in this repo and build it yourself if you'd rather not take my
word for it.

Requires macOS 14 Sonoma or later. Works on Apple silicon and Intel Macs.
Detailed power-flow data is available on Apple silicon only.

### iPhone and iPad battery levels

The Terminal installer sets this up for you. It installs `libimobiledevice` with Homebrew, installing Homebrew first if your Mac has none, which asks for your Mac password once. If you installed by downloading the zip instead, run:

```bash
brew install libimobiledevice
```

KwikBattery picks the tool up on its own and shows your iPhone's model and battery level.

**Over Wi-Fi, macOS also needs one permission.** Finding a device on your network
counts as local network access, and without it KwikBattery simply sees no phone:

1. Open **System Settings › Privacy & Security › Local Network**.
2. Turn **KwikBattery** on. (If it isn't listed yet, open the dropdown once so it asks.)

KwikBattery shows a reminder with an **Open** button in Connected Devices when this
is the likely reason your phone is missing. Your iPhone must also be on the same
Wi-Fi network, unlocked for the first read, and paired with this Mac — plug it in
once and tap **Trust**. In Finder, tick "Show this iPhone when on Wi-Fi".

## Features

- **Menu bar battery icon.** The percentage sits inside the icon, and the fill moves in 10% steps. It's green above 20%, orange from 20% down to 10% and red below 10%, and it stays green while charging.
- **Live dropdown.** Readings refresh every second while the dropdown is open.
  - **Battery information:** health, cycle count, temperature in °C and °F, capacity and adapter. A service warning appears only when the battery needs attention.
  - **Power & Electrical:**
    - Power usage, voltage and current, with a voltage check.
    - An animated power-flow diagram: charger → battery, MacBook and the connected devices your Mac is powering over USB-C.
  - **Connected devices:**
    - AirPods (left, right and case), Magic Mouse, Keyboard and Trackpad, other Bluetooth accessories, and USB-powered devices with their live wattage.
    - iPhone and iPad battery levels (the Terminal installer sets this up).
- **App energy over time.** Tap the chart icon on **Top Energy Users** to see which apps used the most battery today, over 7 days and over 30 days, in watt-hours and as a share of everything the Mac used. KwikBattery samples every 5 minutes (15 in Low Power Mode), only while you're on battery. The figures are approximate, because macOS's Energy Impact score is spread over the Mac's measured power. You can switch this off or reset it in Settings.
- **Notifications.** Alerts for 100% while plugged in, low battery, low battery health and slow charging. You set every threshold.
  - **Hot battery** (on by default): an alert when the battery reaches 40 °C, or whatever threshold you set between 30 and 50 °C. It fires once and re-arms after the battery cools 3 °C. With the charge-control helper installed, KwikBattery can also pause charging at the same temperature (see Charge control).
  - **Charger can't keep up** (on by default): an alert when the Mac is plugged in but the battery has drained for 3 minutes, because the Mac draws more than the adapter supplies. A **Charger check** line under Power & Electrical reads OK, Weak adapter or Charging slowly.
  - **Charging paused** (off by default): a notice, with the reason, when macOS has held the charge for 2 minutes while plugged in.
- **Charge timeline.** Tap the big percentage to see the charge level over the last 24 hours, with time spent plugged in shaded, plus the lowest and highest level and the last sleep. Switch to **Temperature** to see how warm the battery ran, with your hot-battery limit marked and the time spent above it.
- **Health forecast.** In the Health panel (click the Health tile), once there are about three weeks of daily readings, KwikBattery fits a trend line and says how fast health is falling (for example "about 1.5% a month") and roughly when it would reach 80%, where Apple considers a Mac battery worn. It marks early estimates as early and shows health lost per 100 charge cycles. Nothing is guessed from fewer than five readings.
- **Charge limit payoff** (with the helper). Settings › Charge control and the charge timeline show how long the limit held the battery below full while plugged in this week and since you started, and how far under 100% it sat. It counts only time the limit actually held the charge, and makes no claim about capacity.
- **App energy alerts** (on by default). If an app stays above 8 W (you set it, 3–25 W) for about 10 minutes on battery, you get an alert that says how much longer the battery would last without it, with buttons to **Quit App** or **Don't Warn About This App**. It reuses the app energy history samples, so it costs nothing extra, and needs "Track app energy over time" on.
- **Sleep drain report.** After at least 30 minutes asleep on battery, KwikBattery notes how much charge was lost (for example "Lost 3% while asleep for 7h 0m (0.4%/h)"). It alerts you (on by default) when the loss is 3 points or more and faster than your threshold (1.5%/h by default).
- **Since unplugged.** On battery, Power & Electrical shows the time since you unplugged, the charge used and the average watts.
- **Low battery alerts for your devices** (on by default): AirPods, mice, keyboards and other Bluetooth accessories, at 20% or a level you choose. Each device alerts once, then re-arms after charging. iPhones are left to their own alerts.
- **Keyboard shortcut** (off by default): open the panel from any app with ⌃⌥B, ⌥⌘B or ⌃⌥⌘B. No extra permissions are needed.
- **Export history as CSV** from Settings: health, app energy and charge history, for Numbers or Excel.
- **Menu bar text** (off by default): percent, time left or battery watts next to the icon.
- **Smoother time-remaining estimate** (off by default): time left from how fast the percentage has fallen over the last 45 minutes, instead of the momentary draw. Until there's enough data, macOS's own figure is shown.
- **Settings.** Launch at login, percentage on or off, and °C or °F.

## Command line and Shortcuts

Besides `--status` below, the same program controls charging and Low Power Mode, so Terminal, scripts and the Shortcuts app can do it too (these need the charge-control helper):

```bash
KW=~/Applications/KwikBattery.app/Contents/MacOS/KwikBattery
$KW --charge-limit 80        # hold the battery at 80% (50-100; 100 = no limit)
$KW --charge-limit current   # hold it at the charge it has right now ("pause charging")
$KW --charge-limit off       # stop managing charging
$KW --top-up                 # charge to 100% now (or --top-up 90)
$KW --cancel-top-up
$KW --low-power on           # or off
$KW --restore                # charge normally right now
$KW --helper-status          # what the helper is doing, as JSON
```

Each prints one line and exits (0 = done, 1 = helper not installed, 2 = bad command). Settings in the app pick up the change within a few seconds.

In **Shortcuts**, use a **Run Shell Script** action with any of these. KwikBattery doesn't ship native Shortcuts actions: those need Apple's Xcode build tooling to generate, and KwikBattery builds with just the Command Line Tools.

`--status` prints a JSON snapshot of the battery and exits. It doesn't open the app or disturb a copy that's already running:

```bash
~/Applications/KwikBattery.app/Contents/MacOS/KwikBattery --status
```

(Use `/Applications/...` if you installed the app there.)

```json
{
  "adapterWatts" : 87,
  "batteryWatts" : 58.04,
  "charging" : true,
  "cycles" : 120,
  "healthPercent" : 90,
  "inputWatts" : 86.04,
  "percent" : 68,
  "pluggedIn" : true,
  "state" : "charging",
  "systemLoadWatts" : 28,
  "temperatureC" : 31.2,
  "timeToEmptyMinutes" : null,
  "timeToFullMinutes" : 52,
  "voltage" : 12.55
}
```

`state` is one of `charging`, `discharging`, `full`, `notCharging` or `noBattery`. Anything the Mac doesn't report is `null`. `batteryWatts` is positive while charging and negative on battery. The time estimates are macOS's own; the smoothed estimate needs the running app's history.

In the terminal, pipe it to `jq`, for example `... --status | jq .percent`.

In **Shortcuts**, add a **Run Shell Script** action with the command above, then a **Get Dictionary from Input** action. Use **Get Dictionary Value** to pull out `percent`, `state` or any other key, and use it in an If, a notification or a log.

## Charge control (optional, needs the helper)

Settings → **Charge control** adds five things:

- **Charge limit.** Hold the battery at, say, 80% while plugged in; charging resumes a few points below the limit.
- **Automatic discharge.** If the battery is above the limit (you charged to 100% for a trip), run on the battery until it falls to the limit.
- **Clamshell discharge.** Optionally keep discharging with the lid closed, for use with an external display. Without a display the Mac sleeps when the lid closes, so KwikBattery switches the adapter back on *before* sleep and never lets a Mac sleep on a draining battery.
- **Pause charging when hot.** Uses the same temperature as the Hot battery alert (40 °C by default). While the battery is at or above it, KwikBattery stops charging; charging resumes once the battery has cooled 3 °C, and never stays paused below 30% charge.
- **Top-up scheduling.** "Top up now", or schedules like *weekdays 07:00 → 100%*: charge past the limit at that time, then return to the limit.

Settings → **Low Power Mode** (same helper) switches macOS's Low Power Mode on automatically when the charge falls to a level you choose (say 20%), and/or during set hours (say 22:00 to 07:00), and off again afterwards. Only an administrator can change it from outside System Settings, hence the helper. It only switches off what it switched on, never fights you if you turn it off by hand during a window, and puts back an "Only on Battery" setting if you had one.

Only an administrator can tell the battery to stop charging, so this uses a small root helper (`kwikbatteryd`, a LaunchDaemon) installed on request: press **Install Helper…** in Settings, or run `sudo bash install-helper.sh`. The app itself never writes to the SMC and everything else works without the helper. Remove it any time with **Remove Helper…** or `sudo bash uninstall-helper.sh`.

App updates replace the app but not the helper. When an update needs a newer helper, Settings → Charge control shows **Update Helper…**.

Safeguards: the helper restores normal charging when it starts, stops, receives SIGTERM, or before every sleep; every SMC write is read back and, if the value doesn't stick, charge control pauses itself and says why; keys that don't exist on your Mac are never touched; settings are clamped to safe ranges. To check what your Mac supports without changing anything, run `/Library/PrivilegedHelperTools/kwikbatteryd --probe` (or `bash build.sh` and look at the SMC check). If anything ever looks wrong: `sudo /Library/PrivilegedHelperTools/kwikbatteryd --restore`.

The SMC switches used are `CHTE` / `CH0B`+`CH0C` (inhibit charging) and `CHIE` / `CH0I` (adapter off). Apple doesn't document them and they have changed between macOS releases, so please report what `--probe` prints on your Mac.

## Help test

If you have an **Intel Mac** or an older Apple silicon model, please follow [TESTING.md](TESTING.md) and send the report.

## Build from source

**On macOS 26 and earlier,** Apple's Command Line Tools are enough
(`xcode-select --install`).

**On macOS 27 and later, you need Xcode.** That release turned SwiftUI's
`@State` and friends into Swift macros, and the plugin that expands them at
build time ships only inside Xcode — the Command Line Tools don't include it.
After installing Xcode, point the toolchain at it once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`build.sh` checks for the plugin before compiling and tells you if it's missing,
rather than failing with a few hundred lines of macro errors.

```bash
git clone https://github.com/ranvirskh/kwikbattery.git
cd kwikbattery
bash build.sh --install     # build, install to ~/Applications, launch
bash build.sh --watch       # rebuild + relaunch automatically on every change
bash build.sh --release     # universal build → release/KwikBattery-<version>.zip
```

If you do have Xcode, you can also open `KwikBattery.xcodeproj` and press ⌘R.

## How it works

- **Battery data:** `IOPSCopyPowerSourcesInfo` and the `AppleSmartBattery` entry in the IORegistry. The code in `BatteryMonitor.swift` has detailed comments.
- **Live power (Apple silicon):** `PowerTelemetryData` for system input, system load and battery power. `PowerOutDetails` gives the power sent out through each USB-C port.
- **Bluetooth levels:** `system_profiler SPBluetoothDataType` and HID battery properties.
- **App Sandbox:** turned off so the app can run the tools above. It needs no special entitlements and makes no network requests apart from the update check and the optional usage count described below. The charge-control helper talks to the app over a local Unix socket only.

## Privacy: histories stay on your Mac

App energy history is saved only in `~/Library/Application Support/KwikBattery/energy-history.json`, with up to 35 days kept. The 48-hour charge timeline is in `charge-history.json` in the same folder. It's never uploaded or sent anywhere. Turn it off with **Settings → General → Track app energy over time**, and delete it with **Reset energy history…** in the same place.

## Privacy: anonymous usage count

So the developer can see roughly how many people use KwikBattery, the app sends **one anonymous request per day** to a counter. It contains only the app version (for example `/launch/1.7.1`): no install ID, no account, no battery or device data, no cookies. It is **on by default**, you're told about it once when it first applies, and you can switch it off any time in **Settings → General → Share an anonymous daily usage count**. When it's off, nothing is sent. The code is in `UsagePing.swift`.

## License

See [LICENSE](LICENSE).
