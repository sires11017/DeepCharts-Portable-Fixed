DeepCharts Portable (Fixed) - Easy Install
==========================================

Everything is included. You do NOT need to download or install anything else
(no Python, no DirectX, no Visual C++ - the installer handles all of it).

HOW TO INSTALL (about 1 minute):

  1. Double-click:  Install DeepCharts.bat
  2. Click YES on the Windows security prompt.
  3. Wait. The installer sets up the runtimes, the app, and the data feed,
     then DeepCharts opens by itself.

  (If double-click doesn't work, right-click "Install DeepCharts.bat"
   and choose "Run as administrator".)

HOW TO USE IT AFTER THAT:

  Open the "DeepCharts" icon on your Desktop (click Yes on the prompt).
  Always launch it from that shortcut.

WHAT THE INSTALLER DOES (all automatic, one admin click):
  - Installs the required Microsoft runtimes (Visual C++, DirectX helpers)
  - Adds a Windows Defender exclusion so nothing gets removed
  - Installs the app to C:\Deepchart
  - Generates a private certificate unique to your PC and trusts it
  - Configures the data feed (hosts entries + resolves the live server)
  - Loads the chart templates and workspaces
  - Makes a Desktop shortcut and launches
  - Writes a log to C:\Deepchart\install-log.txt

REQUIREMENTS:
  - Windows 10 or 11, 64-bit
  - Administrator rights (for the one security prompt)
  - An internet connection

IF SOMETHING GOES WRONG:
  - The installer window stays open and shows the problem, plus the log path
    (C:\Deepchart\install-log.txt). Send me that file and I can pinpoint it.
  - "Smart App Control" (some new Windows 11 PCs): it blocks unsigned apps
    with no "Run anyway" option. This app isn't code-signed, so on those PCs
    you'd have to turn Smart App Control off (Start > "Smart App Control" > Off,
    then restart) before installing. That's the one thing signing (not code)
    would fix.
  - If antivirus asks, click Allow / Keep - it's your program.

TO UNINSTALL:
  Right-click "Uninstall DeepCharts.bat" -> Run as administrator.

This build fixes the issues that stopped the original from working on a fresh
PC: missing runtimes (the chart engine now has DirectX + VC++), the launcher
now tells you if the engine can't start, history routing, the data-format bug,
Python/protobuf versions, and slow chart building. Details in the GitHub repo.
