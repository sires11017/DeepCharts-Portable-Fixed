# DeepCharts Portable (Fixed)

A working build of DeepCharts Portable — a Volumetrica-based order-flow charting app with a local bridge that feeds it CQG market data. This repo fixes the bugs that stopped the original from working on a clean PC and adds a real one-click installer.

## Install (the easy way)

1. Download **`DeepCharts-Portable-Fixed-Setup.zip`** from the [**Releases**](../../releases) page.
2. Extract it anywhere.
3. Double-click **`Install DeepCharts.bat`** and click **Yes** on the Windows admin prompt.
4. Done — it installs and launches on its own. After that, open it with the **DeepCharts** shortcut on your Desktop.

One download, one admin click. The installer:

- installs the app to `C:\Deepchart`
- generates a certificate **unique to your PC** and trusts it (no shared key)
- adds the data-feed host entries and flushes DNS
- loads the chart templates and workspaces into `C:\Deepchart\data`
- sets the speed flag, makes a Desktop shortcut, and launches

**Requirements:** Windows 10/11 64-bit, and administrator rights for the single prompt.

**Uninstall:** run `Uninstall DeepCharts.bat` (removes the app, hosts entries, certificate, and shortcut).

## What was broken → what's fixed

The original connected to the feed but charts sat on "building chart" forever, and a fresh clone couldn't build or install. Full breakdown in [**BUGFIXES.md**](BUGFIXES.md). The headline items:

- **History routing** — the proxy now sends the chart's history request to the local history server instead of a dead socket.
- **History server** — proper `ServerMsg` bar serialization, plus a missing `import sys` that crashed it on launch.
- **Python / protobuf** — pinned to Python 3.12 and `protobuf>=5.29.0,<6` (the CQG stubs are gencode 5.29.2; a protobuf 7.x runtime silently disables all decoding).
- **Setup** — hosts entries and a per-machine trusted certificate are now done automatically by the installer.
- **Speed** — dropped per-frame debug logging (`LOG_LEVEL=INFO`), which was throttling the whole data stream and making chart builds crawl.

## Build from source

The runnable app binaries ship in the **Release**, not the repo. To rebuild the Python proxy bundles yourself:

```powershell
# Python 3.12
py -3.12 -m venv venv; .\venv\Scripts\Activate.ps1
pip install pyinstaller "protobuf>=5.29.0,<6" "websockets>=14.0" "cryptography>=44"
.\installer\build.ps1   # also needs Inno Setup 6 and .NET Framework 4.8 (csc)
```

## Security

The MITM certificate authority is **generated on each machine at install time** and is never committed to this repo. The app installs a local root certificate and redirects the CQG/DeepCharts hostnames to a local proxy — that is how it delivers data to the chart. Only install it on a machine you own.

## Disclaimer

Provided as-is, for personal use with your own broker/data access. You are responsible for complying with the terms of service of CQG, your broker (FCM), and Volumetrica.
