# KwikBattery

A free, native macOS menu bar app for your battery and power. Every feature is included: no paywalls, subscriptions, accounts or tracking.

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
- **Notifications.** Alerts for 100% while plugged in, low battery, low battery health and slow charging. You set every threshold.
- **Settings.** Launch at login, percentage on or off, and °C or °F.

## Install

1. Download `KwikBattery-x.y.zip` from the [Releases](https://github.com/ranvirskh/kwikbattery/releases) page and unzip it.
2. Move **KwikBattery.app** to your **Applications** folder and open it.
3. This build isn't notarized by Apple, so macOS will warn that it can't verify the app. To open it anyway, go to **System Settings › Privacy & Security** and click **Open Anyway** next to the KwikBattery message.

Requires macOS 14 Sonoma or later. Works on Apple silicon and Intel Macs. Detailed power-flow data is available on Apple silicon only.

### Optional: iPhone and iPad battery levels

```bash
brew install libimobiledevice
```

KwikBattery detects the tool on its own and shows your iPhone's model and battery level over USB or Wi-Fi.

## Help test

If you have an **Intel Mac** or an older Apple silicon model, please follow [TESTING.md](TESTING.md) and send the report.

## Build from source

You only need Apple's Command Line Tools (`xcode-select --install`). Xcode isn't required.

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
- **App Sandbox:** turned off so the app can run the tools above. It needs no special entitlements and makes no network requests.

## License

See [LICENSE](LICENSE).
