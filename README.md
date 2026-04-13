# CableCanvas (v1)

CableCanvas is a wired Mac host -> Android client second-display prototype.

This first version validates protocol + transport by repeatedly streaming one JPEG frame.

## Architecture

- **Protocol layer**: frame envelope (`CCF1` magic + length + payload).
- **Transport layer**: socket connection provider.
- **App layer**: send/receive loop and rendering.

This separation makes transport replacement straightforward later (ADB tunnel -> direct USB/AOA).

## v1 transport

ADB reverse over USB:

```bash
adb reverse tcp:27183 tcp:27183
```

Android app connects to `127.0.0.1:27183`; ADB carries traffic over USB to the host process.

## Project layout

- `host/` macOS sender (Python 3)
- `android-client/` Android receiver app (Kotlin)

## Run v1

1. Enable USB debugging on the tablet and authorize the Mac.
2. Set up tunnel:
   ```bash
   cd host
   ./setup_adb.sh
   ```
3. Start sender:
   ```bash
   python3 send_jpeg_stream.py --image /absolute/path/to/frame.jpg --fps 10
   ```
4. Open `android-client` in Android Studio, run app on the tablet.

