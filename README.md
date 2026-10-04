# KwikBattery

A free, native macOS menu bar app for your battery and power. Every feature is included: no paywalls, subscriptions or accounts, and no tracking of you.

## Features

- **Menu bar battery icon.** The percentage sits inside the icon, and the fill moves in 10% steps. It's green above 20%, orange from 20% down to 10% and red below 10%, and it stays green while charging.
- **Live dropdown.** Readings refresh every second while the dropdown is open.
  - **Battery information:** health, cycle count, temperature in °C and °F, capacity and adapter. A service warning appears only when the battery needs attention.
  - **Power & Electrical:**
    - Power usage, voltage and current, with a voltage check.
    - An animated power-flow diagram: charger → battery, MacBook and the connected devices your Mac is powering over USB-C.
  - **Connected devices:**
    - AirPods (left, right and case), Magic Mouse, Keyboard and Trackpad, other Bluetooth accessories, and USB-powered devices with their live wattage.
    - iPhone and iPad battery levels if the optional libimobiledevice tool is installed (see Optional).
- **App energy over time.** Tap the chart icon on **Top Energy Users** to see which apps used the most battery today, over 7 days and over 30 days, in watt-hours and as a share of everything the Mac used. KwikBattery samples every 5 minutes (15 in Low Power Mode), only while you're on battery. The figures are approximate, because macOS's Energy Impact score is spread over the Mac's measured power. You can switch this off or reset it in Settings.
- **Notifications.** Alerts for 100% while plugged in, low battery, low battery health and slow charging. You set every threshold.
  - **Hot battery** (on by default): an alert when the battery reaches 40 °C, or whatever threshold you set between 30 and 50 °C. It fires once and re-arms after the battery cools 3 °C. It only alerts: it doesn't pause charging.
  - **Charger can't keep up** (on by default): an alert when the Mac is plugged in but the battery has drained for 3 minutes, because the Mac draws more than the adapter supplies. A **Charger check** line under Power & Electrical reads OK, Weak adapter or Charging slowly.
  - **Charging paused** (off by default): a notice, with the reason, when macOS has held the charge for 2 minutes while plugged in.
- **Menu bar text** (off by default): percent, time left or battery watts next to the icon.
- **Smoother time-remaining estimate** (off by default): time left from how fast the percentage has fallen over the last 45 minutes, instead of the momentary draw. Until there's enough data, macOS's own figure is shown.
- **Settings.** Launch at login, percentage on or off, and °C or °F.

## Command line and Shortcuts

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

## Install

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

### Optional: iPhone and iPad battery levels

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
- **App Sandbox:** turned off so the app can run the tools above. It needs no special entitlements and makes no network requests apart from the update check and the optional usage count described below.

## Privacy: energy history stays on your Mac

App energy history is saved only in `~/Library/Application Support/KwikBattery/energy-history.json`, with up to 35 days kept. It's never uploaded or sent anywhere. Turn it off with **Settings → General → Track app energy over time**, and delete it with **Reset energy history…** in the same place.

## Privacy: anonymous usage count

So the developer can see roughly how many people use KwikBattery, the app sends **one anonymous request per day** to a counter. It contains only the app version (for example `/launch/1.7.1`): no install ID, no account, no battery or device data, no cookies. It is **on by default**, you're told about it once when it first applies, and you can switch it off any time in **Settings → General → Share an anonymous daily usage count**. When it's off, nothing is sent. The code is in `UsagePing.swift`.

## License

See [LICENSE](LICENSE).
