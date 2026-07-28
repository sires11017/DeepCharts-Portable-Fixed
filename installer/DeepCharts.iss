; DeepCharts Portable — Inno Setup Script
; Compile: iscc DeepCharts.iss
; Requires: Inno Setup 6.3+

#define AppName "DeepCharts"
#define AppVersion "1.0.0"
#define AppPublisher "DeepCharts"
#define AppURL "https://github.com/sires11017/DeepCharts-Portable"
#define AppExeName "Deepchart.exe"
#define AppId "{{A3F8C2E1-4B7D-4E9A-8F1C-2D5E6B7A8C9D}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=..
OutputBaseFilename=DeepCharts-Setup-{#AppVersion}
SetupIconFile=..\app\deepchart_icon_dark.ico
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
DisableDirPage=yes
DisableProgramGroupPage=yes
WizardStyle=modern
AppCopyright=Copyright © 2024 DeepCharts

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Start DeepCharts automatically on Windows login"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; --- Main Launcher ---
Source: "payload\Deepchart.exe"; DestDir: "{app}"; Flags: ignoreversion

; --- App binaries (Core + Bridge + all DLLs) ---
Source: "payload\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- Proxy (PyInstaller bundle: bridge MITM proxy) ---
Source: "payload\proxy\DeepChartsProxy\*"; DestDir: "{app}\proxy\DeepChartsProxy"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- Historical mock server (PyInstaller bundle) ---
Source: "payload\proxy\DeepChartsHistServer\*"; DestDir: "{app}\proxy\DeepChartsHistServer"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- CA Certificates (installed to CommonAppData) ---
Source: "payload\certs\*"; DestDir: "{commonappdata}\DeepCharts\certs"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- User templates (copied on first run) ---
Source: "payload\userdata\*"; DestDir: "{app}\userdata"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\DeepCharts"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Comment: "Launch DeepCharts Portable"
Name: "{commondesktop}\DeepCharts"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Comment: "Launch DeepCharts Portable"; Tasks: desktopicon

[Registry]
; Install path for startup scripts
Root: HKCU; Subkey: "Software\DeepCharts"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey

; Uninstall display
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}"; ValueType: string; ValueName: "DisplayName"; ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}"; ValueType: string; ValueName: "DisplayVersion"; ValueData: "{#AppVersion}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}"; ValueType: string; ValueName: "Publisher"; ValueData: "{#AppPublisher}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}"; ValueType: string; ValueName: "URLInfoAbout"; ValueData: "{#AppURL}"; Flags: uninsdeletekey

[Run]
; Launch DeepCharts
Filename: "{app}\{#AppExeName}"; Description: "Launch DeepCharts"; Flags: nowait postinstall skipifsilent runascurrentuser

[UninstallRun]
; Stop processes before uninstall
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM Deepchart.exe /IM DeepChartsProxy.exe /IM DeepChartsHistServer.exe /IM Deepchart.Core.exe /IM VolumetricaBridge.exe"; Flags: runhidden waituntilterminated

[Code]
var
  CACertPath: String;

procedure ModifyHostsFile(Add: Boolean); forward;
procedure AddDefenderExclusions(Add: Boolean); forward;
procedure InstallCACert(Install: Boolean); forward;

procedure InitializeWizard();
begin
  CACertPath := ExpandConstant('{commonappdata}\DeepCharts\certs\mitm_ca\ca.pem');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  OldApp: String;
begin
  if CurStep = ssInstall then begin
    { Remove v15.6.7 leftover files from previous install }
    OldApp := ExpandConstant('{app}\app\Deepchart.exe');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\Deepchart.dll');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\Deepchart.deps.json');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\Deepchart.dll.config');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\Deepchart.dll.manifest');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\Deepchart.runtimeconfig.json');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\Deepchart.application');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\deepchart.dll.hash');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\ZstdSharp.dll');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\System.Management.dll');
    if FileExists(OldApp) then DeleteFile(OldApp);
    OldApp := ExpandConstant('{app}\app\System.Runtime.Caching.dll');
    if FileExists(OldApp) then DeleteFile(OldApp);
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpReady then begin
    ModifyHostsFile(True);
    AddDefenderExclusions(True);
    InstallCACert(True);
  end;
end;

procedure ModifyHostsFile(Add: Boolean);
var
  HostsFile, Script: String;
  ResCode: Integer;
begin
  HostsFile := ExpandConstant('{win}\System32\drivers\etc\hosts');
  if not FileExists(HostsFile) then Exit;
  if Add then
    Script :=
      '$hosts=@(''demoapi.cqg.com'',''api.cqg.com'',''depth-it.historical.deepcharts.com'',''data-b.historical.deepcharts.com''); ' +
      '$c=Get-Content ''' + HostsFile + '''; ' +
      'foreach($h in $hosts){ ' +
      '  $r = [regex]''127\.0\.0\.1\s+'' + [regex]::Escape($h) + ''$''; ' +
      '  if($c -notmatch $r){ Add-Content ''' + HostsFile + ''' "127.0.0.1 $h" } ' +
      '}; ipconfig /flushdns'
  else
    Script :=
      '$hosts=@(''demoapi.cqg.com'',''api.cqg.com'',''depth-it.historical.deepcharts.com'',''data-b.historical.deepcharts.com''); ' +
      '$c=Get-Content ''' + HostsFile + '''; ' +
      '$regex = ''127\.0\.0\.1\s+('' + (($hosts | ForEach-Object {[regex]::Escape($_)}) -join ''|'') + '')$''; ' +
      '$c = $c | Where-Object {$_ -notmatch $regex}; ' +
      '$c | Set-Content ''' + HostsFile + '''; ipconfig /flushdns';
  Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "' + Script + '"', '', SW_HIDE, ewWaitUntilTerminated, ResCode);
end;

procedure AddDefenderExclusions(Add: Boolean);
var
  Path, Cmd: String;
  ResCode: Integer;
begin
  if Add then begin
    Path := ExpandConstant('{app}');
    Cmd := 'Add-MpPreference -ExclusionPath "' + Path + '" -Force';
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "' + Cmd + '"', '', SW_HIDE, ewWaitUntilTerminated, ResCode);
    Path := ExpandConstant('{app}\app');
    Cmd := 'Add-MpPreference -ExclusionPath "' + Path + '" -Force';
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "' + Cmd + '"', '', SW_HIDE, ewWaitUntilTerminated, ResCode);
  end else begin
    Path := ExpandConstant('{app}');
    Cmd := 'Remove-MpPreference -ExclusionPath "' + Path + '" -Force';
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "' + Cmd + '"', '', SW_HIDE, ewWaitUntilTerminated, ResCode);
    Path := ExpandConstant('{app}\app');
    Cmd := 'Remove-MpPreference -ExclusionPath "' + Path + '" -Force';
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "' + Cmd + '"', '', SW_HIDE, ewWaitUntilTerminated, ResCode);
  end;
end;

procedure InstallCACert(Install: Boolean);
var
  Cmd: String;
  ResCode: Integer;
begin
  if not FileExists(CACertPath) then Exit;
  if Install then begin
    Cmd := 'certutil.exe -addstore -f Root "' + CACertPath + '"';
    Exec('cmd.exe', '/c ' + Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResCode);
    Cmd := 'certutil.exe -user -addstore -f Root "' + CACertPath + '"';
    Exec('cmd.exe', '/c ' + Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResCode);
  end else begin
    Cmd := 'certutil.exe -delstore Root "' + CACertPath + '"';
    Exec('cmd.exe', '/c ' + Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResCode);
    Cmd := 'certutil.exe -user -delstore Root "' + CACertPath + '"';
    Exec('cmd.exe', '/c ' + Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResCode);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    ModifyHostsFile(False);
    AddDefenderExclusions(False);
    InstallCACert(False);
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = wpLicense then Result := True;
  if PageID = wpInfoBefore then Result := True;
  if PageID = wpInfoAfter then Result := True;
end;
