# Live Mix Desktop

[日本語](README.md) | English

An **unofficial Mac app** for controlling the I-O DATA GV-LSMIXER/I (an ATEN UC9020 StreamLIVE HD family device).
Connect the device over USB and use this app instead of the official iPad control app.
It never modifies the device firmware; it only uses the RESTful API the device already exposes.

> **Unofficial.** This project is not affiliated with I-O DATA or ATEN and is not supported by either company.
> There is no warranty. The app can change the device's state, including starting a live stream,
> importing settings, and factory reset. Use it at your own risk.

> **Note:** The app's user interface is in Japanese only.

Keywords: GV-LSMIXER/I, GV-LSMIXER, ATEN UC9020, StreamLIVE HD, LIVEACROSS, OnAir, Mac, macOS, live streaming, video switcher

## Features

- **Live**: switch Preview / Program (CUT, AUTO, number keys 1–8), audio volume and mute, start and stop the live stream
- **Program monitor**: view and record the device's RTSP output on the Mac (only while not streaming; see Limitations).
  Choose "iPad Stream" to view the iPad app's video feed instead (720p, 15 fps, no audio). This does not touch the streaming settings
- **Scene editor**: layout and cropping of input windows, background, image and text overlays, copy and templates
- **Streaming settings**: destinations (RTMP / RTSP / USB recording), encoding, pause screen
- **Images**: add, delete, and save images stored on the device
- **Device management**: back up and restore settings, set the clock, LAN settings
- A small control panel in the menu bar
- Guidance and automatic reconnection when the USB cable is unplugged

## Requirements

- macOS 15 or later on an Apple silicon Mac (Intel Macs are not supported)
- Xcode Command Line Tools (`xcode-select --install`)
- ffmpeg for the Program monitor (`brew install ffmpeg`)
- Tested device: GV-LSMIXER/I (firmware V1.4.136)
- Tested Mac: Apple silicon Mac, macOS 27.2

### Does it work with the ATEN UC9020?

The GV-LSMIXER/I belongs to the same family as the ATEN UC9020 (StreamLIVE HD), and its API follows the same documentation.
However, the app has not been tested on an ATEN UC9020 itself. The login method, the device's IP address, the number of stream destinations and so on may differ.
If you try it on a UC9020 or with other firmware, please let us know whether it worked in [Issues](https://github.com/tomo-klotho/LiveMixDesktop/issues).

## Build and run

```bash
git clone https://github.com/tomo-klotho/LiveMixDesktop.git
cd LiveMixDesktop/app
./build.sh
open build/LiveMixDesktop.app
```

If you have an Apple Development certificate, the app is signed with it. Otherwise it is ad-hoc signed,
and macOS may ask for local network permission after every build.
Choose the signing certificate with `SIGN_IDENTITY`.

After launching, log in with the device's administrator account. The factory default is `administrator` / `password`.

### Environment variables

| Variable | Meaning |
| --- | --- |
| `LMD_HOST` | Device address (default `192.168.254.1`) |
| `LMD_SECTION` | Screen to open first (`live` `scenes` `broadcast` `assets` `device` `settings`) |
| `LMD_NOWINDOW=1` | Start in the menu bar only, without opening a window |

## Command-line tool

`livemix.py` is a CLI that uses only the Python standard library.

```bash
./livemix.py login
./livemix.py scenes
./livemix.py prv 3 && ./livemix.py cut
```

## Limitations

- The device can enable only one destination that sends the Program (RTMP 2, RTMP 3, RTSP 5) at a time. USB recording can be enabled separately and has been confirmed to run together with RTMP streaming or RTSP.
  As a result, the high-quality (RTSP) monitor cannot be used while streaming to YouTube or elsewhere.
- The iPad Stream monitor works only when the device's iPad Stream destination is this Mac's IP address (192.168.254.2 when connected directly to the device).
  While it is shown, the iPad app's screen (channel 3) is switched to a full-screen Program view and switched back when you close it.
- The streaming engine cannot start unless a cable is plugged into the device's LAN port (this also applies to the RTSP monitor).
- The device uses a self-signed certificate, so the app and the CLI connect without verifying it. They are meant for a direct USB connection.
  If you use `LMD_HOST` to reach a device over a LAN, others on the same network could read or alter the traffic, including login details and stream keys.

## Features not tested on a real device

The following features are implemented but have not yet been tried on a real device. The app marks them as untested on screen too.
Do not use them if the device holds important settings or data.

- Factory reset (the current settings are exported automatically first)
- The iPad Stream monitor while a live stream is running

## What is stored on the Mac

- Login details: saved in the Keychain when "save to Keychain and log in automatically" is on in the login screen (the default)
- `~/.config/livemixdesktop/` (the folder is created so only you can open it, and the files so only you can read them)
  - `cookies.txt`: the current login session
  - `app.log`: an activity log (passwords and cookies are never written)
  - `scene-templates.json`: scene templates
  - `profile-backup/`: backups of the device settings. **These include stream keys and the login password**, so do not share them
  - `pause-backup/`, `monitor-restore.json`, `monitor-ipad-restore.json`: records used to restore the previous state

## About the API

The device API follows the documentation published by ATEN. Differences found on the real device are collected in [docs/API.md](docs/API.md) (in Japanese).

## License

MIT License. See [LICENSE](LICENSE). The change history is in [CHANGELOG.md](CHANGELOG.md) (in Japanese).

I-O DATA and GV-LSMIXER are trademarks or registered trademarks of I-O DATA DEVICE, INC. ATEN and StreamLIVE are trademarks or registered trademarks of ATEN International Co., Ltd.
