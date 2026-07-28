# Bug fixes

What stopped the original DeepCharts-Portable from working on a clean PC, and what this build does about it. The shipped binaries in the original were also stale relative to its own source, so several "fixes" here are really "rebuild from the current source so the fix actually ships."

## Why the chart sat on "building chart"

1. **History request was misrouted (biggest one).**
   When you open a chart, the app opens a second connection to fetch history (`GET / HTTP/1.1`, no SNI). The shipped proxy dumped that into a dead "dummy WebSocket," so bars never came back. `bridge_mitm_proxy.py` → `is_historical_route()` routes `path == "/"` to the local history server on port 12010. Rebuilt so the running binary matches.

2. **History server crashed on launch.**
   `vol_hist_server.py` referenced `sys` (`getattr(sys, '_MEIPASS', ...)`) without importing it → `NameError`, instant exit. **Fixed:** added `sys` to the imports.

3. **History server serialized bars in the wrong shape.**
   `build_signed_response()` returns a proper `ServerMsg` with `time_bar_reports` populated when protobuf is available (the old form buried the bar data where the client never looks). Confirmed the field names against the CQG stubs (`ServerMsg.time_bar_reports`, `TimeBarReport.time_bars`, `TimeBar.scaled_*`).

## Why the feed wouldn't connect at all

4. **No hosts redirect.**
   The bridge only routes through the local proxy if these resolve to `127.0.0.1`:
   `demoapi.cqg.com`, `api.cqg.com`, `depth-it.historical.deepcharts.com`, `data-b.historical.deepcharts.com`.
   Without them the bridge talks straight to the real CQG servers and the proxy sees nothing. The installer writes them.

5. **Certificate wasn't trusted.**
   The proxy does TLS interception, so its CA has to be in the Windows Root store. The installer **generates a per-machine CA** (by running the proxy once) and trusts it with `certutil`. The original committed a CA private key to a public repo — a security hole — and then excluded it from the installer, which also broke trust. This build commits no key and makes one locally.

## Build / dependency problems

6. **protobuf version gate.**
   The CQG `*_pb2.py` stubs are gencode **5.29.2** and reject a mismatched major runtime. A protobuf **7.x** runtime raises `VersionError`, which the proxy swallows and runs with all decoding/patching disabled — so it *looks* alive (port open) but never patches the logon or decodes bars. **Fixed:** `requirements.txt` pinned to `protobuf>=5.29.0,<6`, built on Python 3.12 (the bundled wheels are cp312).

7. **Templates went to the wrong folder.**
   The app's in-app File Picker reads user data from `C:\Deepchart\data` (`\Workspace`, `\Template`, `\Indicator Template`) — not `Documents\Deepchart`. The installer deploys the templates to the folder the app actually reads.

## Why it was slow

8. **Per-frame disk logging throttled the stream.**
   At `LOG_LEVEL=DEBUG` the proxy wrote one log line per forwarded frame (~170/sec) with a blocking file write inside its single-threaded async loop. That serialized the whole data path, so history loads and timeframe changes crawled (minutes). **Fixed:** installer sets `LOG_LEVEL=INFO`; important events still log, per-frame spam is gone. Chart builds went from minutes to seconds.

## Known limitations

- Binaries are unsigned → SmartScreen / antivirus may warn (it installs a root cert and redirects a data feed — inherently "suspicious" to heuristics). Allow it if prompted.
- The CQG **demo** login built into the closed-source bridge can expire. If the feed won't connect, set your own in `proxy/mitm/.env` (`CQG_USERNAME` / `CQG_PASSWORD`).
- The mock history server can't fully parse every request shape (`bars=False` in some cases); in practice the real bars come from CQG's own stream, so this isn't blocking.

## Fresh-PC hardening (making it bulletproof to share)

A deep audit of the whole install→launch flow on a *clean* PC (no dev tools, no prior runtimes) found the real reasons it failed for other people. All fixed:

- **Missing runtimes = "launcher runs but the chart never opens."** The chart engine uses **SlimDX**, which needs **DirectX 9** (`d3dx9_43`, `d3dx10_43`, `d3dx11_43`, `d3dcompiler_43`) and the **Visual C++ Redistributables** (2010 `msvcr100` + 2015–2022 `vcruntime140`). A clean Windows 10/11 has none of these, so `Deepchart.Core.exe` crashed instantly with no window. **Fix:** the DirectX `_43` DLLs are shipped next to the app, and the VC++ redists are bundled and installed silently by `Install.ps1`. Nobody downloads anything.
- **The launcher never checked the engine came up** (the liveness check was gated to a code path that never runs here), so every runtime gap read as a silent "started successfully" with no chart. **Fix:** `Launcher.cs` now verifies `Deepchart.Core` stayed alive and shows a plain-English dialog naming the likely missing runtime.
- **Installer silent half-failures.** The CA step was a blind 7-second wait (too short on a fresh PC where Defender scans the unsigned proxy for 15–40s), the elevated window vanished on any error, and cert-trust/robocopy results were never checked. **Fix:** `Install.ps1` polls for the CA (~45s, with a retry), verifies the cert was trusted, verifies every exe survived the copy, adds a Defender exclusion, keeps the window open on any error, and writes `C:\Deepchart\install-log.txt`.
- **Feed reliability.** The live CQG IP is now resolved at install time (via public DNS, before the hosts redirect) and baked into a machine env var; the proxy + history server bind to `127.0.0.1` and get pre-approved firewall rules, so there are no extra "Allow access?" pop-ups and no LAN exposure.
- **Launcher startup timing.** The 30-second port wait aborted (and tore everything down) on a slow first run; raised to 120s and it no longer kills the proxies if they're still coming up.
- **CQG status light** now matches the proxy's actual success log line, so a connected feed shows green instead of a permanent (misleading) red.

**Honest ceiling:** the app is unsigned, so **Smart App Control** (default-on on some new Win11 machines) blocks it outright with no "Run anyway" — the only clean fix is code-signing with a paid certificate.
