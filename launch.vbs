Set WshShell = CreateObject("WScript.Shell")
Set WshEnv = WshShell.Environment("PROCESS")
Set Fso = CreateObject("Scripting.FileSystemObject")
Set Net = CreateObject("WScript.Network")

strComputer = "."
strRepo = Fso.GetParentFolderName(WScript.ScriptFullName)

' ─── Helpers ───────────────────────────────────────────────────────────────
Function Log(msg)
    WScript.Echo "[launch.vbs] " & msg
End Function

Function ResolveIP(hostname, dnsServer)
    Dim cmd, output, lines, line, i, ip
    cmd = "nslookup " & hostname & " " & dnsServer & " 2>nul"
    output = WshShell.Exec("%COMSPEC% /C " & cmd).StdOut.ReadAll()
    lines = Split(output, vbCrLf)
    For i = 0 To UBound(lines)
        line = Trim(lines(i))
        If InStr(line, "Address:") > 0 Then
            ip = Trim(Mid(line, InStr(line, "Address:") + 8))
            If IsIP(ip) Then
                ResolveIP = ip
                Exit Function
            End If
        End If
        If InStr(line, "Addresses:") > 0 Then
            ip = Trim(Mid(line, InStr(line, "Addresses:") + 10))
            If IsIP(ip) Then
                ResolveIP = ip
                Exit Function
            End If
        End If
    Next
    ResolveIP = ""
End Function

Function IsIP(str)
    Dim parts, i, octet
    parts = Split(str, ".")
    If UBound(parts) <> 3 Then IsIP = False: Exit Function
    For i = 0 To 3
        If Not IsNumeric(parts(i)) Then IsIP = False: Exit Function
        octet = CInt(parts(i))
        If octet < 0 Or octet > 255 Then IsIP = False: Exit Function
    Next
    IsIP = True
End Function

Function IsAdmin()
    IsAdmin = WshShell.Run("net session >nul 2>&1", 0, True) = 0
End Function

Function ReadPythonPath()
    Dim pyFile
    pyFile = strRepo & "\.python_path"
    If Fso.FileExists(pyFile) Then
        ReadPythonPath = Trim(Fso.OpenTextFile(pyFile).ReadLine())
    Else
        ReadPythonPath = ""
    End If
End Function

' ─── 0. Check admin ────────────────────────────────────────────────────────
If Not IsAdmin() Then
    Log "ERROR: Administrator privileges required."
    Log "Right-click launch.vbs and select 'Run as administrator'."
    WScript.Quit 1
End If

' ─── 1. Kill old processes ────────────────────────────────────────────────
Log "Killing old processes..."
On Error Resume Next
strCmd = "%COMSPEC% /C taskkill /F /IM python.exe /T 2>nul & taskkill /F /IM pythonw.exe /T 2>nul & taskkill /F /IM BridgeWrapper.exe /T 2>nul & taskkill /F /IM VolumetricaBridge.exe /T 2>nul & taskkill /F /IM Deepchart.Core.exe /T 2>nul & taskkill /F /IM Deepchart.exe /T 2>nul"
WshShell.Run strCmd, 0, True
On Error Goto 0

WScript.Sleep 3000

' ─── 2. Resolve upstream CQG IP (before hosts redirect blocks it) ─────────
Log "Resolving upstream CQG IP via Google DNS (8.8.8.8)..."
cqgIP = ResolveIP("demoapi.cqg.com", "8.8.8.8")
If cqgIP = "" Then
    Log "WARNING: Could not resolve demoapi.cqg.com via Google DNS, trying default DNS..."
    cqgIP = ResolveIP("demoapi.cqg.com", "")
End If
If cqgIP = "" Then
    Log "WARNING: Using fallback IP 208.48.16.22"
    cqgIP = "208.48.16.22"
End If
Log "CQG upstream IP: " & cqgIP

WshEnv("CQG_UPSTREAM_IP") = cqgIP
WshEnv("REAL_CQG_HOST") = cqgIP

' ─── 3. Stop iphlpsvc (HTTP SSL) to free port 443 ─────────────────────────
Log "Stopping iphlpsvc (HTTP SSL) to free port 443..."
WshShell.Run "%COMSPEC% /C net stop iphlpsvc /y >nul 2>&1 & sc config iphlpsvc start=disabled >nul 2>&1", 0, True
WScript.Sleep 1000

' ─── 4. Start PowerShell launcher ─────────────────────────────────────────
Log "Starting DeepCharts..."
ps1Path = strRepo & "\scripts\start-deepcharts.ps1"
If Not Fso.FileExists(ps1Path) Then
    Log "ERROR: " & ps1Path & " not found"
    WScript.Quit 1
End If

pyPath = ReadPythonPath()
If pyPath <> "" And Fso.FileExists(pyPath) Then
    WshEnv("PYTHON_EXE") = pyPath
End If

' Run PowerShell with admin bypass, hidden window, no profile
psCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """"
WshShell.Run psCmd, 0, False

Log "DeepCharts launched successfully. Check the app window."
