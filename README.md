# AutoTuneLiveMac

Minimal macOS SwiftUI app for live voice processing:
- Live autotune amount control (0-100%)
- Live reverb amount control (0-100%)
- Live mode and Record mode
- Device pickers for microphone and output
- Immediate start with current macOS default input/output

## Run in VSCode

1. Open `AutoTuneLiveMac` in VSCode.
2. Open an integrated terminal.
3. Run:

```bash
swift run
```

Or use:

```bash
./run.sh
```

The app window launches and immediately uses the current macOS default mic/speaker.

## Notes

- Switching device pickers updates the macOS default input/output device so the engine follows your selection.
- Recordings are written to:

`~/Music/AutoTuneLiveRecordings`

- Files are saved as `.caf` with timestamps.

## Toolchain requirement

You need a full Xcode toolchain selected (not only Command Line Tools), for example:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then rerun `swift run`.
