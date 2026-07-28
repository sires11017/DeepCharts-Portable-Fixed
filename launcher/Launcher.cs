using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

class DeepChartsApp
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool firstCreated;
        Mutex mtx = new Mutex(true, "DeepChartsLauncher", out firstCreated);
        if (!firstCreated)
        {
            MessageBox.Show("DeepCharts is already running.", "DeepCharts", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        using (mtx)
        {
            Application.Run(new MainForm());
        }
    }
}

class MainForm : Form
{
    string BaseDir;
    string DataDir;
    string PythonExe;
    bool IsNewVersion;
    int ProxyPort;
    int HistPort;
    Process ProxyProc;
    Process HistProc;
    Process BridgeProc;
    Process AppProc;
    System.Windows.Forms.Timer HealthTimer;
    System.Windows.Forms.Timer LogTimer;
    TextBox TxtLog;
    Label LblProxy;
    Label LblHistSrv;
    Label LblApp;
    Label LblCQG;
    Button BtnStart;
    Button BtnStop;
    Button BtnCred;
    bool Running;
    string SavedUser;
    string SavedPass;
    string LastLogPath;
    long LastLogOffset;
    int LauncherPid;
    NotifyIcon TrayIcon;

    public MainForm()
    {
        BaseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        LauncherPid = Process.GetCurrentProcess().Id;
        DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DeepCharts");
        Directory.CreateDirectory(DataDir);
        Directory.CreateDirectory(Path.Combine(DataDir, "logs"));

        // Port configuration (can be overridden via environment variables)
        int p;
        ProxyPort = int.TryParse(Environment.GetEnvironmentVariable("BRIDGE_PROXY_PORT"), out p) ? p : 443;
        int h;
        HistPort = int.TryParse(Environment.GetEnvironmentVariable("BRIDGE_LOCAL_MOCK_PORT"), out h) ? h : 12010;

        this.Text = "DeepCharts Portable";
        this.Size = new Size(720, 540);
        this.MinimumSize = new Size(600, 400);
        this.StartPosition = FormStartPosition.CenterScreen;
        this.Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
        this.FormClosing += MainForm_FormClosing;

        IsNewVersion = File.Exists(Path.Combine(BaseDir, "app", "Deepchart.exe"))
                    && !File.Exists(Path.Combine(BaseDir, "app", "Deepchart.Core.exe"));
        PythonExe = FindPython();
        LoadCreds();

        TableLayoutPanel tbl = new TableLayoutPanel();
        tbl.Dock = DockStyle.Fill;
        tbl.Padding = new Padding(10);
        tbl.ColumnCount = 1;
        tbl.RowCount = 4;
        tbl.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        tbl.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        tbl.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        tbl.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        Label header = new Label();
        header.Text = "DeepCharts Portable";
        header.Font = new Font("Segoe UI", 18, FontStyle.Bold);
        header.Dock = DockStyle.Top;
        header.Height = 40;
        header.TextAlign = ContentAlignment.MiddleLeft;
        tbl.Controls.Add(header);

        FlowLayoutPanel statusPanel = new FlowLayoutPanel();
        statusPanel.Dock = DockStyle.Fill;
        statusPanel.Height = 60;
        statusPanel.Padding = new Padding(0, 5, 0, 5);
        statusPanel.AutoSize = true;

        LblProxy = MakeStatus("Proxy");
        LblHistSrv = MakeStatus("HistSrv");
        LblApp = MakeStatus(IsNewVersion ? "App" : "Core");
        LblCQG = MakeStatus("CQG");

        statusPanel.Controls.Add(LblProxy);
        statusPanel.Controls.Add(LblHistSrv);
        statusPanel.Controls.Add(LblApp);
        statusPanel.Controls.Add(LblCQG);
        tbl.Controls.Add(statusPanel);

        TxtLog = new TextBox();
        TxtLog.Dock = DockStyle.Fill;
        TxtLog.Multiline = true;
        TxtLog.ReadOnly = true;
        TxtLog.ScrollBars = ScrollBars.Vertical;
        TxtLog.Font = new Font("Consolas", 9);
        TxtLog.BackColor = Color.Black;
        TxtLog.ForeColor = Color.Lime;
        tbl.Controls.Add(TxtLog);

        FlowLayoutPanel btnPanel = new FlowLayoutPanel();
        btnPanel.Dock = DockStyle.Fill;
        btnPanel.Height = 40;
        btnPanel.AutoSize = true;
        btnPanel.FlowDirection = FlowDirection.RightToLeft;

        BtnCred = new Button();
        BtnCred.Text = "Credentials";
        BtnCred.Width = 100;
        BtnCred.Height = 32;
        BtnCred.Click += BtnCred_Click;

        BtnStop = new Button();
        BtnStop.Text = "Stop All";
        BtnStop.Width = 100;
        BtnStop.Height = 32;
        BtnStop.Enabled = false;
        BtnStop.Click += BtnStop_Click;

        BtnStart = new Button();
        BtnStart.Text = "Start All";
        BtnStart.Width = 100;
        BtnStart.Height = 32;
        BtnStart.Click += BtnStart_Click;

        btnPanel.Controls.Add(BtnStart);
        btnPanel.Controls.Add(BtnStop);
        btnPanel.Controls.Add(BtnCred);
        tbl.Controls.Add(btnPanel);

        this.Controls.Add(tbl);

        TrayIcon = new NotifyIcon();
        TrayIcon.Icon = this.Icon;
        TrayIcon.Text = "DeepCharts Portable";
        TrayIcon.Visible = true;
        TrayIcon.DoubleClick += (s, e) => {
            this.Show();
            this.WindowState = FormWindowState.Normal;
            this.BringToFront();
        };
        TrayIcon.ContextMenuStrip = new ContextMenuStrip();
        TrayIcon.ContextMenuStrip.Items.Add("Show", null, (s, e) => {
            this.Show();
            this.WindowState = FormWindowState.Normal;
            this.BringToFront();
        });
        TrayIcon.ContextMenuStrip.Items.Add("Exit", null, (s, e) => {
            TrayIcon.Visible = false;
            Running = false;
            StopAll();
            Application.Exit();
        });

        Log("DeepCharts Portable v1.3");
        Log("Base: " + BaseDir);
        Log("Data: " + DataDir);
        Log("Version: " + (IsNewVersion ? "v15.6.7 (new)" : "legacy"));
        Log("Python: " + (PythonExe ?? "NOT FOUND"));

        HealthTimer = new System.Windows.Forms.Timer();
        HealthTimer.Interval = 3000;
        HealthTimer.Tick += HealthTimer_Tick;
        HealthTimer.Start();

        LogTimer = new System.Windows.Forms.Timer();
        LogTimer.Interval = 2000;
        LogTimer.Tick += LogTimer_Tick;
        LogTimer.Start();

        Thread startup = new Thread(AutoStart);
        startup.IsBackground = true;
        startup.Start();
    }

    void MainForm_FormClosing(object sender, FormClosingEventArgs e)
    {
        if (Running)
        {
            e.Cancel = true;
            this.WindowState = FormWindowState.Minimized;
            this.Hide();
            TrayIcon.ShowBalloonTip(1000, "DeepCharts Portable", "Running in background. Double-click tray icon to restore.", ToolTipIcon.Info);
        }
        else
        {
            TrayIcon.Visible = false;
        }
    }

    Label MakeStatus(string name)
    {
        Label lbl = new Label();
        lbl.Text = "  " + name + "  ";
        lbl.Width = 110;
        lbl.Height = 28;
        lbl.TextAlign = ContentAlignment.MiddleCenter;
        lbl.BorderStyle = BorderStyle.FixedSingle;
        lbl.BackColor = Color.Gray;
        lbl.ForeColor = Color.White;
        lbl.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        lbl.Margin = new Padding(4);
        return lbl;
    }

    void SetStatus(Label lbl, bool ok)
    {
        lbl.BackColor = ok ? Color.Green : Color.Red;
    }

    string FindPython()
    {
        string cfgPath = Path.Combine(BaseDir, ".python_path");
        if (File.Exists(cfgPath))
        {
            string saved = File.ReadAllText(cfgPath).Trim();
            if (saved.Length > 0 && File.Exists(saved))
                return saved;
        }
        string[] cmds = new string[] { "python", "python3" };
        foreach (string cmd in cmds)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("where", cmd);
                psi.RedirectStandardOutput = true;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process p = Process.Start(psi);
                string output = p.StandardOutput.ReadToEnd().Trim();
                p.WaitForExit();
                if (p.ExitCode == 0 && output.Length > 0)
                {
                    string path = output.Split('\n')[0].Trim();
                    if (File.Exists(path) && !path.Contains("WindowsApps"))
                        return path;
                }
            }
            catch { }
        }
        return null;
    }

    void LoadCreds()
    {
        string credFile = Path.Combine(DataDir, "creds.dat");
        if (!File.Exists(credFile)) return;
        try
        {
            byte[] data = ProtectedData.Unprotect(File.ReadAllBytes(credFile), null, DataProtectionScope.CurrentUser);
            string text = Encoding.UTF8.GetString(data);
            string[] parts = text.Split('\0');
            SavedUser = parts.Length > 0 ? parts[0] : "";
            SavedPass = parts.Length > 1 ? parts[1] : "";
        }
        catch
        {
            SavedUser = "";
            SavedPass = "";
        }
    }

    void SaveCreds(string user, string pass)
    {
        try
        {
            byte[] data = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(user + "\0" + pass),
                null,
                DataProtectionScope.CurrentUser);
            File.WriteAllBytes(Path.Combine(DataDir, "creds.dat"), data);
            SavedUser = user;
            SavedPass = pass;
            Log("Credentials saved for: " + user);
        }
        catch (Exception ex)
        {
            Log("Failed to save credentials: " + ex.Message);
        }
    }

    void ShowCredDialog()
    {
        Form f = new Form();
        f.Text = "CQG Credentials";
        f.Size = new Size(360, 200);
        f.FormBorderStyle = FormBorderStyle.FixedDialog;
        f.MaximizeBox = false;
        f.MinimizeBox = false;
        f.StartPosition = FormStartPosition.CenterParent;

        TextBox tbUser = new TextBox();
        tbUser.Text = SavedUser;
        tbUser.Location = new Point(120, 20);
        tbUser.Width = 200;

        TextBox tbPass = new TextBox();
        tbPass.Text = SavedPass;
        tbPass.Location = new Point(120, 50);
        tbPass.Width = 200;
        tbPass.UseSystemPasswordChar = true;

        Button btnSave = new Button();
        btnSave.Text = "Save";
        btnSave.Location = new Point(120, 90);
        btnSave.Width = 90;

        Button btnSkip = new Button();
        btnSkip.Text = "Skip";
        btnSkip.Location = new Point(220, 90);
        btnSkip.Width = 90;
        btnSkip.DialogResult = DialogResult.Cancel;

        f.Controls.Add(new Label { Text = "Username:", Location = new Point(20, 23) });
        f.Controls.Add(tbUser);
        f.Controls.Add(new Label { Text = "Password:", Location = new Point(20, 53) });
        f.Controls.Add(tbPass);
        f.Controls.Add(btnSave);
        f.Controls.Add(btnSkip);

        btnSave.Click += (sender, e) =>
        {
            SaveCreds(tbUser.Text.Trim(), tbPass.Text);
            f.Close();
        };

        f.ShowDialog(this);
    }

    void BtnCred_Click(object sender, EventArgs e)
    {
        ShowCredDialog();
    }

    void BtnStart_Click(object sender, EventArgs e)
    {
        Thread startThread = new Thread(StartAll);
        startThread.IsBackground = true;
        startThread.Start();
    }

    void BtnStop_Click(object sender, EventArgs e)
    {
        Thread stopThread = new Thread(StopAll);
        stopThread.IsBackground = true;
        stopThread.Start();
    }

    void AutoStart()
    {
        Thread.Sleep(500);
        if (!string.IsNullOrEmpty(SavedUser))
            Log("Credentials saved for: " + SavedUser);
        KillOld();
        Thread.Sleep(2000);
        StartAll();
    }

    void KillOld()
    {
        string[] names = new string[] {
            "VolumetricaBridge", "BridgeWrapper", "Deepchart.Core",
            "DeepChartsProxy", "DeepChartsHistServer"
        };
        foreach (string name in names)
        {
            foreach (Process proc in Process.GetProcessesByName(name))
            {
                if (proc.Id == LauncherPid) continue;
                try { proc.Kill(); Log("Killed stale " + name + " PID " + proc.Id); }
                catch { }
            }
        }
        Thread.Sleep(1000);
    }

    void SetEnv()
    {
        if (!string.IsNullOrEmpty(SavedUser))
        {
            Environment.SetEnvironmentVariable("CQG_USERNAME", SavedUser, EnvironmentVariableTarget.Process);
            Environment.SetEnvironmentVariable("CQG_PASSWORD", SavedPass, EnvironmentVariableTarget.Process);
            Log("CQG env set (user=" + SavedUser + ", len=" + SavedUser.Length + ")");
        }
    }

    void StartAll()
    {
        if (Running) return;

        string histBundle = Path.Combine(BaseDir, "proxy", "DeepChartsHistServer", "DeepChartsHistServer.exe");
        string proxyBundle = Path.Combine(BaseDir, "proxy", "DeepChartsProxy", "DeepChartsProxy.exe");
        string proxyDir = Path.Combine(BaseDir, "proxy", "mitm");
        string histScript = Path.Combine(proxyDir, "vol_hist_server.py");
        string bridgeProxy = Path.Combine(proxyDir, "bridge_mitm_proxy.py");

        bool useBundles = File.Exists(histBundle) && File.Exists(proxyBundle);
        bool useScripts = !useBundles && File.Exists(histScript) && File.Exists(bridgeProxy);

        if (!useBundles && !useScripts)
        {
            Log("ERROR: No proxy found (bundles or scripts)");
            return;
        }

        try
        {
            SetEnv();

            if (useBundles)
            {
                Log("[START] HistServer bundle: " + histBundle);
                HistProc = StartHidden(histBundle, "", Path.GetDirectoryName(histBundle));
                Log("[START] HistServer PID: " + HistProc.Id);
                Thread.Sleep(3000);

                if (HistProc.HasExited)
                {
                    Log("ERROR: HistServer exited immediately (exit=" + HistProc.ExitCode + ") — check logs");
                    string logDir = FindLogDir();
                    if (logDir != null)
                    {
                        string hlog = Path.Combine(logDir, "vol_hist_" + DateTime.Now.ToString("yyyyMMdd") + "*.log");
                        string[] hfiles = Directory.GetFiles(logDir, "vol_hist_" + DateTime.Now.ToString("yyyyMMdd") + "*.log");
                        if (hfiles.Length > 0)
                        {
                            string tail = ReadTail(hfiles[hfiles.Length - 1], 2000);
                            Log("[HIST LOG TAIL] " + tail);
                        }
                    }
                    return;
                }
                Log("[START] HistServer OK — port " + HistPort + " listening: " + IsPortOpen(HistPort));

                Log("[START] Proxy bundle: " + proxyBundle);
                ProxyProc = StartHidden(proxyBundle, "", Path.GetDirectoryName(proxyBundle));
                Log("[START] Proxy PID: " + ProxyProc.Id);
                Thread.Sleep(3000);

                if (ProxyProc.HasExited)
                {
                    Log("ERROR: Proxy exited immediately (exit=" + ProxyProc.ExitCode + ") — check logs");
                    string logDir = FindLogDir();
                    if (logDir != null)
                    {
                        string[] pfiles = Directory.GetFiles(logDir, "bridge_mitm_" + DateTime.Now.ToString("yyyyMMdd") + "*.log");
                        if (pfiles.Length > 0)
                        {
                            string tail = ReadTail(pfiles[pfiles.Length - 1], 2000);
                            Log("[PROXY LOG TAIL] " + tail);
                        }
                    }
                    return;
                }
                Log("[START] Proxy OK — port " + ProxyPort + " listening: " + IsPortOpen(ProxyPort));
            }
            else
            {
                Log("[START] Python scripts mode");
                HistProc = StartHidden(PythonExe, "\"" + histScript + "\"", proxyDir);
                Log("[START] vol_hist PID: " + HistProc.Id);
                Thread.Sleep(2000);
                ProxyProc = StartHidden(PythonExe, "\"" + bridgeProxy + "\"", proxyDir);
                Log("[START] proxy PID: " + ProxyProc.Id);
            }

            if (!WaitForPorts(30))
            {
                Log("ERROR: Ports 443/12010 not ready after 30s — aborting");
                StopAll();
                return;
            }
            Log("[START] All ports ready");

            string appDir = Path.Combine(BaseDir, "app");
            string newApp = Path.Combine(appDir, "Deepchart.exe");
            string oldApp = Path.Combine(BaseDir, "app", "Deepchart.Core.exe");
            string bridgeExe = Path.Combine(appDir, "bridge", "VolumetricaBridge.exe");
            string wrapperExe = Path.Combine(appDir, "BridgeWrapper.exe");

if (File.Exists(newApp))
            {
                Log("[START] v15.6.7 mode - launching " + newApp);
                Log("[START] Working dir: " + appDir);
                LaunchApp(newApp, appDir);
            }
            else if (File.Exists(oldApp))
            {
                Log("[START] Legacy mode - starting bridge + Core");
                if (File.Exists(bridgeExe))
                {
                    string wd = Path.Combine(appDir, "bridge");
                    if (File.Exists(wrapperExe))
                    {
                        BridgeProc = StartHidden(wrapperExe, "--wait", wd);
                        Log("[START] Bridge wrapper PID: " + BridgeProc.Id);
                    }
                    else
                    {
                        BridgeProc = StartHidden(bridgeExe, "", wd);
                        Log("[START] Bridge PID: " + BridgeProc.Id);
                    }
                }
                Thread.Sleep(3000);
                Log("[START] Launching Core: " + oldApp);
                LaunchApp(oldApp, appDir);
            }
            else
            {
                Log("ERROR: No app found in " + appDir);
                StopAll();
                return;
            }

            Running = true;
            this.BeginInvoke((MethodInvoker)delegate
            {
                BtnStart.Enabled = false;
                BtnStop.Enabled = true;
            });
            Log("=== All services started ===");
        }
        catch (Exception ex)
        {
            Log("FATAL START ERROR: " + ex.Message);
            Log(ex.StackTrace);
            StopAll();
        }
    }

    void LaunchApp(string exe, string workDir)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe);
            psi.WorkingDirectory = workDir;
            psi.UseShellExecute = true;
            AppProc = Process.Start(psi);
            Log("[APP] Launched PID: " + AppProc.Id + " — " + exe);

            if (IsNewVersion)
            {
                Thread.Sleep(5000);
                if (AppProc.HasExited)
                {
                    Log("[APP] Bootstrapper exited (exit=" + AppProc.ExitCode + ") — .NET 10 app running as child");
                    AppProc = null;
                    FindAndTrackAppChild(workDir);
                }
                else
                {
                    Log("[APP] Bootstrapper still alive after 5s (PID " + AppProc.Id + ")");
                }
            }
        }
        catch (Exception ex)
        {
            Log("[APP] Launch failed: " + ex.Message);
        }
    }

    void FindAndTrackAppChild(string appDir)
    {
        try
        {
            Process[] deepchartProcs = Process.GetProcessesByName("Deepchart");
            foreach (Process p in deepchartProcs)
            {
                if (p.Id == LauncherPid) continue;
                try
                {
                    string path = "";
                    try { path = p.MainModule.FileName; }
                    catch { path = "(access denied)"; }
                    Log("[APP] Found Deepchart process PID " + p.Id + " — " + path);

                    if (path.Contains("app") && !p.HasExited)
                    {
                        AppProc = p;
                        Log("[APP] Tracking child process PID " + p.Id);
                        return;
                    }
                }
                catch { }
            }

            Process[] allProcs = Process.GetProcesses();
            foreach (Process p in allProcs)
            {
                try
                {
                    string name = p.ProcessName;
                    if (name.Contains("Deepchart") || name.Contains("deepchart"))
                    {
                        if (p.Id == LauncherPid) continue;
                        try
                        {
                            string path = p.MainModule.FileName;
                            if (!p.HasExited)
                            {
                                Log("[APP] Found candidate PID " + p.Id + " (" + name + ") — " + path);
                                AppProc = p;
                                return;
                            }
                        }
                        catch { }
                    }
                }
                catch { }
            }
            Log("[APP] No child process found — app may have a UI waiting (license/login)");
        }
        catch (Exception ex)
        {
            Log("[APP] FindAndTrackAppChild error: " + ex.Message);
        }
    }

    void StopAll()
    {
        Log("[STOP] Stopping all services...");

        if (ProxyProc != null && !ProxyProc.HasExited)
        {
            try { ProxyProc.Kill(); ProxyProc.WaitForExit(3000); Log("[STOP] Proxy killed"); } catch { }
        }
        if (HistProc != null && !HistProc.HasExited)
        {
            try { HistProc.Kill(); HistProc.WaitForExit(3000); Log("[STOP] HistServer killed"); } catch { }
        }
        if (BridgeProc != null && !BridgeProc.HasExited)
        {
            try { BridgeProc.Kill(); BridgeProc.WaitForExit(3000); Log("[STOP] Bridge killed"); } catch { }
        }

        string[] appNames = IsNewVersion
            ? new string[] { "Deepchart" }
            : new string[] { "Deepchart.Core", "VolumetricaBridge", "BridgeWrapper" };
        foreach (string name in appNames)
        {
            foreach (Process proc in Process.GetProcessesByName(name))
            {
                if (proc.Id == LauncherPid) continue;
                try
                {
                    Log("[STOP] Killing " + name + " PID " + proc.Id);
                    proc.Kill();
                    proc.WaitForExit(2000);
                }
                catch { }
            }
        }

        ProxyProc = null;
        HistProc = null;
        BridgeProc = null;
        AppProc = null;
        Running = false;
        this.BeginInvoke((MethodInvoker)delegate
        {
            BtnStart.Enabled = true;
            BtnStop.Enabled = false;
        });
        Log("=== All services stopped ===");
    }

    bool IsProcessAlive(Process p)
    {
        if (p == null) return false;
        try { return !p.HasExited; }
        catch { return false; }
    }

    bool IsAppRunning()
    {
        if (IsProcessAlive(AppProc))
            return true;

        try
        {
            string[] names = IsNewVersion
                ? new string[] { "Deepchart" }
                : new string[] { "Deepchart.Core" };
            foreach (string name in names)
            {
                foreach (Process proc in Process.GetProcessesByName(name))
                {
                    if (proc.Id == LauncherPid) continue;
                    if (!proc.HasExited)
                    {
                        AppProc = proc;
                        Log("[HEALTH] Found running app PID " + proc.Id);
                        return true;
                    }
                }
            }
        }
        catch { }
        return false;
    }

int CountProxyConnections()
        {
            try
            {
                string logDir = FindLogDir();
                if (logDir == null) return 0;
                string[] files = Directory.GetFiles(logDir, "bridge_mitm_*.log");
                if (files.Length == 0) return 0;
                string latest = files[0];
                foreach (string f in files)
                {
                    if (File.GetLastWriteTime(f) > File.GetLastWriteTime(latest)) latest = f;
                }
                string content = File.ReadAllText(latest, Encoding.UTF8);
                int count = 0;
                foreach (string line in content.Split('\n'))
                {
                    if (line.Contains("[+] Connected") || line.Contains("[C->S] WebSocket") || line.Contains("login_success"))
                        count++;
                }
                return count;
            }
            catch { return 0; }
        }

    bool IsCqgConnected()
    {
        try
        {
            string logDir = FindLogDir();
            if (logDir == null) return false;
            string[] files = Directory.GetFiles(logDir, "bridge_mitm_*.log");
            if (files.Length == 0) return false;
            string latest = files[0];
            foreach (string f in files)
            {
                if (File.GetLastWriteTime(f) > File.GetLastWriteTime(latest)) latest = f;
            }
            string content = File.ReadAllText(latest, Encoding.UTF8);
            // Check for LOGON_RESULT with code=0 (successful CQG login)
            return content.Contains("LOGON_RESULT: code=0");
        }
        catch { return false; }
    }

    void HealthTimer_Tick(object sender, EventArgs e)
    {
        try
        {
            bool proxyOk = IsProcessAlive(ProxyProc);
            bool histOk = IsProcessAlive(HistProc);
            bool appOk = IsAppRunning();
            bool portProxy = IsPortOpen(ProxyPort);
            bool portHist = IsPortOpen(HistPort);
            bool cqgConnected = IsCqgConnected();

            SetStatus(LblProxy, Running && proxyOk && portProxy);
            SetStatus(LblHistSrv, Running && histOk && portHist);
            SetStatus(LblApp, Running && appOk);
            SetStatus(LblCQG, Running && proxyOk && cqgConnected);

            if (!Running) return;

            if (!proxyOk && ProxyProc != null && ProxyProc.HasExited)
            {
                Log("[!] Proxy crashed (exit=" + ProxyProc.ExitCode + ") — restarting...");
                ProxyProc = null;
                Thread restart = new Thread(RestartProxy);
                restart.IsBackground = true;
                restart.Start();
            }

            if (!histOk && HistProc != null)
            {
                Log("[!] HistServer crashed — restarting...");
                HistProc = null;
                Thread restart = new Thread(RestartHist);
                restart.IsBackground = true;
                restart.Start();
            }
        }
        catch (Exception ex)
        {
            Log("[HealthTimer] Error: " + ex.Message);
        }
    }

    void RestartProxy()
    {
        try
        {
            string proxyBundle = Path.Combine(BaseDir, "proxy", "DeepChartsProxy", "DeepChartsProxy.exe");
            if (File.Exists(proxyBundle))
            {
                ProxyProc = StartHidden(proxyBundle, "", Path.GetDirectoryName(proxyBundle));
                Log("[RESTART] Proxy PID: " + ProxyProc.Id);
            }
            else if (PythonExe != null)
            {
                string proxyDir = Path.Combine(BaseDir, "proxy", "mitm");
                string bridgeProxy = Path.Combine(proxyDir, "bridge_mitm_proxy.py");
                if (File.Exists(bridgeProxy))
                {
                    ProxyProc = StartHidden(PythonExe, "\"" + bridgeProxy + "\"", proxyDir);
                    Log("[RESTART] Proxy (script) PID: " + ProxyProc.Id);
                }
            }
        }
        catch (Exception ex)
        {
            Log("[RESTART] Proxy failed: " + ex.Message);
        }
    }

    void RestartHist()
    {
        try
        {
            string histBundle = Path.Combine(BaseDir, "proxy", "DeepChartsHistServer", "DeepChartsHistServer.exe");
            if (File.Exists(histBundle))
            {
                HistProc = StartHidden(histBundle, "", Path.GetDirectoryName(histBundle));
                Log("[RESTART] HistServer PID: " + HistProc.Id);
            }
            else if (PythonExe != null)
            {
                string proxyDir = Path.Combine(BaseDir, "proxy", "mitm");
                string histScript = Path.Combine(proxyDir, "vol_hist_server.py");
                if (File.Exists(histScript))
                {
                    HistProc = StartHidden(PythonExe, "\"" + histScript + "\"", proxyDir);
                    Log("[RESTART] HistServer (script) PID: " + HistProc.Id);
                }
            }
        }
        catch (Exception ex)
        {
            Log("[RESTART] HistServer failed: " + ex.Message);
        }
    }

    bool WaitForPorts(int maxSec)
    {
        for (int i = 0; i < maxSec; i++)
        {
            if (IsPortOpen(ProxyPort) && IsPortOpen(HistPort)) return true;
            Thread.Sleep(1000);
        }
        return false;
    }

    bool IsPortOpen(int port)
    {
        try
        {
            IPGlobalProperties props = IPGlobalProperties.GetIPGlobalProperties();
            foreach (System.Net.IPEndPoint ep in props.GetActiveTcpListeners())
                if (ep.Port == port) return true;
        }
        catch { }
        return false;
    }

    Process StartHidden(string exe, string args, string wd)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.WorkingDirectory = wd;
        psi.CreateNoWindow = true;
        psi.UseShellExecute = false;
        psi.RedirectStandardError = true;
        psi.RedirectStandardOutput = false;
        Process p = Process.Start(psi);
        Thread errThread = new Thread(() => {
            try
            {
                using (StreamReader reader = p.StandardError)
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        Log("[" + Path.GetFileName(exe) + "][stderr] " + line);
                    }
                }
            }
            catch { }
        });
        errThread.IsBackground = true;
        errThread.Start();
        return p;
    }

    string FindLogDir()
    {
        string localLogs = Path.Combine(DataDir, "logs");
        if (Directory.Exists(localLogs)) return localLogs;
        string baseLogs = Path.Combine(BaseDir, "logs");
        if (Directory.Exists(baseLogs)) return baseLogs;
        return null;
    }

    string ReadTail(string path, int bytes)
    {
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                int len = (int)Math.Min(bytes, fs.Length);
                fs.Seek(-len, SeekOrigin.End);
                byte[] buf = new byte[len];
                int read = fs.Read(buf, 0, len);
                return Encoding.UTF8.GetString(buf, 0, read);
            }
        }
        catch (Exception ex) { return "(read error: " + ex.Message + ")"; }
    }

    void LogTimer_Tick(object sender, EventArgs e)
    {
        if (!Running) return;
        try
        {
            string logDir = FindLogDir();
            if (logDir == null) return;
            string[] files = Directory.GetFiles(logDir, "bridge_mitm_*.log");
            if (files.Length == 0) return;

            string latest = files[0];
            foreach (string f in files)
            {
                if (File.GetLastWriteTime(f) > File.GetLastWriteTime(latest)) latest = f;
            }

            FileInfo info = new FileInfo(latest);
            if (LastLogPath != latest)
            {
                LastLogPath = latest;
                LastLogOffset = Math.Max(0, info.Length - 50000);
            }

            if (LastLogOffset >= info.Length) return;

            using (FileStream fs = new FileStream(latest, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                fs.Seek(LastLogOffset, SeekOrigin.Begin);
                byte[] buf = new byte[Math.Min(4096, info.Length - LastLogOffset)];
                int read = fs.Read(buf, 0, buf.Length);
                if (read > 0)
                {
                    string text = Encoding.UTF8.GetString(buf, 0, read);
                    string[] lines = text.Split('\n');
                    foreach (string line in lines)
                    {
                        string trimmed = line.Trim();
                        if (trimmed.Length > 0)
                            AppendLog(trimmed);
                    }
                    LastLogOffset += read;
                }
            }
        }
        catch { }
    }

    void AppendLog(string msg)
    {
        if (TxtLog.InvokeRequired)
        {
            try { TxtLog.BeginInvoke((MethodInvoker)delegate { AppendLog(msg); }); }
            catch { }
            return;
        }
        TxtLog.AppendText(msg + Environment.NewLine);
        if (TxtLog.TextLength > 100000)
            TxtLog.Text = TxtLog.Text.Substring(TxtLog.TextLength - 60000);
        TxtLog.SelectionStart = TxtLog.TextLength;
        TxtLog.ScrollToCaret();
    }

    void Log(string msg)
    {
        AppendLog(DateTime.Now.ToString("HH:mm:ss") + " " + msg);
        try
        {
            string logFile = Path.Combine(DataDir, "launcher.log");
            using (StreamWriter sw = new StreamWriter(logFile, true))
                sw.WriteLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg);
        }
        catch { }
    }
}
