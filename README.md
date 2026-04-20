# CableCanvas

CableCanvas is a low-latency, wired second-display solution that turns your Android tablet or phone into a dedicated monitor for your Mac.

It uses native macOS APIs to create a "real" virtual display—meaning your Mac treats the Android device as a hardware monitor with its own resolution, HiDPI (Retina) support, and desktop space.

## Setup

1. **Android Device**: Enable **USB Debugging** in Developer Options and connect it to your Mac via USB.
2. **Mac Host**: Download the latest `CableCanvas.dmg` from the [Releases](https://github.com/tui2019/CableCanvas/releases) page and drag it to your Applications folder.
3. **Launch & Stream**: Open CableCanvas on your Mac. Once a device is connected and authorized, the Mac app will automatically detect it and show a popup asking to start the stream.
4. **Automatic Install**: On the first launch, the app will also automatically prompt to install the Android receiver app onto your connected device if it isn't already there.

## How it Works

CableCanvas is designed for performance and universal compatibility:

- **ADB Transport**: Unlike other solutions that rely on USB Tethering (which often fails on macOS due to missing NCM protocol support on many Android devices), CableCanvas uses an ADB tunnel. This ensures it "just works" on virtually any Android device with a stable, high-bandwidth connection.
- **H.264 Encoding**: The host captures the virtual display using `ScreenCaptureKit` and encodes it in real-time using macOS hardware acceleration (`VideoToolbox`) for minimal CPU usage.
- **Native Virtual Display**: It utilizes the `CGVirtualDisplay` API (macOS 13+) to create a true virtual monitor, allowing for native resolution scaling and proper desktop management.
- **Zero-Config**: The Mac app handles the entire lifecycle—detecting the device, setting up the network tunnel, and launching the Android app—so you don't have to touch the terminal.

## Project Structure

- `mac-host/`: Native Swift menu bar app and H.264 encoder.
- `android-client/`: Kotlin-based receiver app using hardware decoding.
