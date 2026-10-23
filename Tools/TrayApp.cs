// DPS Report Exporter -- the tray app (2026-10-23).
//
// Sits in the notification area and follows the newest WoW combat log. When
// a boss pull ends (outside a key) or a Mythic+ key ends, that pull or key is
// exported (Exporter.cs) and copied, with a Windows notification -- in game it
// is just DPS Graph > Import, Ctrl+V. The same logic as the PowerShell
// script's -Watch mode, without a console window.
//
// Built by Build.cmd with the csc.exe that ships with Windows, so C# 5 only:
// no string interpolation, no ?. and no => members.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// Shown in the exe's Properties > Details, and by Windows' own prompts.
[assembly: AssemblyTitle("DPS Report Exporter")]
[assembly: AssemblyProduct("DPS Report Exporter")]
[assembly: AssemblyDescription("Copies WoW boss pulls and Mythic+ keys from the combat log for the DPS Report addon")]
[assembly: AssemblyCompany("Squizzcheeze")]
[assembly: AssemblyCopyright("MIT licence")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static void Main(string[] args)
    {
        // Build.cmd's first pass: write the icon the second pass embeds.
        if (args.Length == 2 && args[0] == "--write-icon")
        {
            TrayIcon.WriteIco(args[1]);
            return;
        }
        bool created;
        using (var mutex = new Mutex(true, "DPSReportExporterTray", out created))
        {
            if (!created)
            {
                MessageBox.Show("DPS Report Exporter is already running - look for its icon by the clock.",
                    "DPS Report Exporter", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
        }
    }
}

// The app's icon, drawn rather than shipped: three rising bars, DPS Report's
// accent blue, on a dark rounded square.
static class TrayIcon
{
    public static Bitmap Draw(int size)
    {
        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            float r = size * 0.18f;
            using (var path = new GraphicsPath())
            {
                float s = size - 1;
                path.AddArc(0, 0, r * 2, r * 2, 180, 90);
                path.AddArc(s - r * 2, 0, r * 2, r * 2, 270, 90);
                path.AddArc(s - r * 2, s - r * 2, r * 2, r * 2, 0, 90);
                path.AddArc(0, s - r * 2, r * 2, r * 2, 90, 90);
                path.CloseFigure();
                using (var bg = new SolidBrush(Color.FromArgb(255, 24, 28, 36))) g.FillPath(bg, path);
            }
            float pad = size * 0.17f, gap = size * 0.07f;
            float w = (size - pad * 2 - gap * 2) / 3f;
            float[] heights = { 0.38f, 0.58f, 0.80f };
            Color[] colours = { Color.FromArgb(255, 0, 140, 200), Color.FromArgb(255, 0, 175, 235), Color.FromArgb(255, 60, 210, 255) };
            for (int i = 0; i < 3; i++)
            {
                float h = (size - pad * 2) * heights[i];
                using (var b = new SolidBrush(colours[i]))
                    g.FillRectangle(b, pad + i * (w + gap), size - pad - h, w, h);
            }
        }
        return bmp;
    }

    public static Icon Small()
    {
        int size = SystemInformation.SmallIconSize.Width;
        using (var bmp = Draw(Math.Max(16, size)))
            return Icon.FromHandle(bmp.GetHicon());
    }

    // An .ico holding PNG images (Vista and later read these), for the .exe.
    public static void WriteIco(string path)
    {
        int[] sizes = { 16, 24, 32, 48, 256 };
        var pngs = new List<byte[]>();
        foreach (int s in sizes)
        {
            using (var bmp = Draw(s))
            using (var ms = new MemoryStream())
            {
                bmp.Save(ms, ImageFormat.Png);
                pngs.Add(ms.ToArray());
            }
        }
        using (var fs = new FileStream(path, FileMode.Create))
        using (var w = new BinaryWriter(fs))
        {
            w.Write((short)0); w.Write((short)1); w.Write((short)sizes.Length);
            int offset = 6 + 16 * sizes.Length;
            for (int i = 0; i < sizes.Length; i++)
            {
                w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
                w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
                w.Write((byte)0); w.Write((byte)0);
                w.Write((short)1); w.Write((short)32);
                w.Write(pngs[i].Length); w.Write(offset);
                offset += pngs[i].Length;
            }
            foreach (var p in pngs) w.Write(p);
        }
    }
}

// One export the app has made: kept so any of the recent ones can be copied
// again (the clipboard only holds the newest, and you may have copied
// something else since).
class ExportEntry
{
    public DateTime At;
    public string What;
    public string Text;
}

class TrayContext : ApplicationContext
{
    const string AppName = "DPS Report Exporter";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const int MaxRecent = 20;

    readonly NotifyIcon tray;
    readonly SynchronizationContext ui;
    readonly System.Threading.Timer poll;
    readonly List<ExportEntry> recent = new List<ExportEntry>();
    readonly ToolStripMenuItem pauseItem, startupItem;
    StatusWindow window;

    string logFolder;
    bool paused;
    int busy;                       // 1 while a poll or an export is running

    // Watch state: the log being followed and how far it has been read.
    string current;
    long pos;
    string carry = "";
    bool inKey, first = true;
    string lastId = "";

    public TrayContext()
    {
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        logFolder = Settings.Get("logFolder") ?? DefaultLogFolder();
        paused = Settings.Get("paused") == "1";

        var menu = new ContextMenuStrip();
        menu.Items.Add("Show recent exports", null, delegate { ShowWindow(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Copy last key", null, delegate { ManualExport("key"); });
        menu.Items.Add("Copy last boss pull", null, delegate { ManualExport("boss"); });
        menu.Items.Add(new ToolStripSeparator());
        pauseItem = new ToolStripMenuItem("Pause watching", null, delegate { SetPaused(!paused); });
        menu.Items.Add(pauseItem);
        startupItem = new ToolStripMenuItem("Start with Windows", null, delegate { ToggleStartup(); });
        menu.Items.Add(startupItem);
        menu.Items.Add("Open log folder", null, delegate { OpenLogFolder(); });
        menu.Items.Add("Change log folder...", null, delegate { ChooseLogFolder(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { ExitThread(); });
        menu.Opening += delegate
        {
            pauseItem.Checked = paused;
            startupItem.Checked = StartsWithWindows();
        };

        tray = new NotifyIcon();
        tray.Icon = TrayIcon.Small();
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.DoubleClick += delegate { ShowWindow(); };
        UpdateTooltip();

        if (!Directory.Exists(logFolder))
        {
            Notify("Combat log folder not found",
                "Right-click the tray icon > Change log folder... and pick World of Warcraft\\_retail_\\Logs.");
        }
        else if (Settings.Get("welcomed") != "1")
        {
            Settings.Set("welcomed", "1");
            Notify("Running in the tray",
                "Boss pulls and finished keys are copied as they end. Double-click the icon for recent exports.");
        }
        poll = new System.Threading.Timer(delegate { Poll(); }, null, 500, 2000);
    }

    // The first of these that exists: four levels up when run from
    // Interface\AddOns\DPSReport\Tools; the install the Battle.net launcher
    // registered (the exe downloaded from the website runs from anywhere);
    // then the two usual install folders. Falls back to the first, so the
    // "not found" notification names somewhere sensible.
    static string DefaultLogFolder()
    {
        var candidates = new List<string>();
        string dir = Path.GetDirectoryName(Application.ExecutablePath);
        candidates.Add(Path.GetFullPath(Path.Combine(dir, @"..\..\..\..\Logs")));
        try
        {
            using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft"))
            {
                string install = k == null ? null : k.GetValue("InstallPath") as string;
                if (!string.IsNullOrEmpty(install)) candidates.Add(Path.Combine(install, "Logs"));
            }
        }
        catch { }
        candidates.Add(@"C:\Program Files (x86)\World of Warcraft\_retail_\Logs");
        candidates.Add(@"C:\World of Warcraft\_retail_\Logs");
        foreach (string c in candidates)
            if (Directory.Exists(c)) return c;
        return candidates[0];
    }

    // ---- watching -------------------------------------------------------

    void Poll()
    {
        if (paused) return;
        if (Interlocked.Exchange(ref busy, 1) == 1) return;
        try
        {
            string trigger = ReadNewLines();
            if (trigger != null) RunExport(trigger, true);
        }
        catch (Exception e)
        {
            Debug.WriteLine(e);
        }
        finally
        {
            Interlocked.Exchange(ref busy, 0);
        }
    }

    // Reads what WoW has appended since last time (complete lines only) and
    // returns "key" or "boss" when one just ended. The log open when the app
    // starts is followed from its END; one created later from its start.
    string ReadNewLines()
    {
        string newest = NewestLog();
        if (newest == null) return null;
        if (current == null || !string.Equals(newest, current, StringComparison.OrdinalIgnoreCase))
        {
            current = newest;
            pos = first ? new FileInfo(newest).Length : 0;
            carry = "";
            inKey = false;
            Post(UpdateTooltip);
        }
        first = false;

        string trigger = null;
        using (var fs = new FileStream(current, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            if (fs.Length < pos) { pos = 0; carry = ""; }       // the file was replaced
            if (fs.Length == pos) return null;
            fs.Position = pos;
            var buf = new byte[fs.Length - pos];
            int read = fs.Read(buf, 0, buf.Length);
            pos += read;
            string text = carry + Encoding.UTF8.GetString(buf, 0, read);
            int cut = text.LastIndexOf('\n');
            if (cut < 0) { carry = text; return null; }
            carry = text.Substring(cut + 1);
            foreach (string line in text.Substring(0, cut).Split('\n'))
            {
                if (line.Contains("  CHALLENGE_MODE_START,")) inKey = true;
                else if (line.Contains("  CHALLENGE_MODE_END,")) { inKey = false; trigger = "key"; }
                else if (line.Contains("  ENCOUNTER_END,") && !inKey) trigger = "boss";
            }
        }
        return trigger;
    }

    string NewestLog()
    {
        if (!Directory.Exists(logFolder)) return null;
        string best = null;
        DateTime bestAt = DateTime.MinValue;
        foreach (string f in Directory.GetFiles(logFolder, "WoWCombatLog*.txt"))
        {
            DateTime at = File.GetLastWriteTimeUtc(f);
            if (at > bestAt) { best = f; bestAt = at; }
        }
        return best;
    }

    // ---- exporting ------------------------------------------------------

    // Runs on a worker thread. `auto`: from watching, so a repeat of the last
    // export (the reset CHALLENGE_MODE_END the game logs before a key) and a
    // failure are both silent.
    void RunExport(string mode, bool auto)
    {
        string log = auto ? current : NewestLog();
        if (log == null)
        {
            if (!auto) Post(delegate { Notify("No combat log", "Nothing found in " + logFolder); });
            return;
        }
        var sw = Stopwatch.StartNew();
        string text;
        try { text = DRKeyExport.Export(log, mode); }
        catch (Exception e)
        {
            if (!auto) Post(delegate { Notify("Couldn't read the log", e.Message); });
            return;
        }
        if (text.StartsWith("ERROR:"))
        {
            if (!auto)
            {
                string msg = text.Substring(6).Trim();
                Post(delegate { Notify("Nothing to copy", msg); });
            }
            return;
        }
        string id = text.Split('~')[1];
        if (auto && id == lastId) return;
        lastId = id;
        var entry = new ExportEntry { At = DateTime.Now, What = Describe(text), Text = text };
        double secs = sw.Elapsed.TotalSeconds;
        Post(delegate
        {
            recent.Insert(0, entry);
            if (recent.Count > MaxRecent) recent.RemoveAt(recent.Count - 1);
            if (CopyText(entry.Text))
                Notify("Copied: " + entry.What, string.Format("Read in {0:0.0}s. In game: DPS Graph > Import, Ctrl+V.", secs));
            else
                Notify("Couldn't copy", entry.What + " - the clipboard was busy. Copy it from the recent exports.");
            if (window != null && !window.IsDisposed) window.Fill(recent);
        });
    }

    void ManualExport(string mode)
    {
        tray.Text = "DPS Report Exporter - reading the log...";
        ThreadPool.QueueUserWorkItem(delegate
        {
            // Wait for a watch poll in progress rather than run alongside it.
            while (Interlocked.Exchange(ref busy, 1) == 1) Thread.Sleep(100);
            try { RunExport(mode, false); }
            finally
            {
                Interlocked.Exchange(ref busy, 0);
                Post(UpdateTooltip);
            }
        });
    }

    // "Ula'tek (Heroic) Kill, 9:29, 285 KB" / "Altar of Fangs +12, 34:21, 412 KB"
    public static string Describe(string text)
    {
        string[] head = text.Split('~')[1].Split('^');
        string what;
        int secs;
        int.TryParse(head[3], out secs);
        if (head.Length > 6 && head[6] == "raid")
            what = string.Format("{0} ({1}) {2}", head[1], head[2], head[4] == "1" ? "Kill" : "Wipe");
        else
            what = string.Format("{0} +{1}", head[1], head[2]);
        return string.Format("{0}, {1}:{2:00}, {3} KB", what, secs / 60, secs % 60, (int)Math.Round(text.Length / 1024.0));
    }

    public static bool CopyText(string text)
    {
        try
        {
            Clipboard.SetDataObject(text, true, 10, 100);
            return true;
        }
        catch { return false; }
    }

    // ---- UI -------------------------------------------------------------

    void Post(Action a)
    {
        ui.Post(delegate { a(); }, null);
    }

    void Notify(string title, string text)
    {
        tray.ShowBalloonTip(4000, title, text, ToolTipIcon.None);
    }

    void UpdateTooltip()
    {
        string state = paused ? "paused" : current != null ? "watching " + Path.GetFileName(current) : "waiting for a combat log";
        string tip = "DPS Report Exporter - " + state;
        tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;   // NotifyIcon's limit
        if (window != null && !window.IsDisposed) window.SetStatus(Status());
    }

    public string Status()
    {
        if (paused) return "Paused. Right-click the tray icon > Pause watching to resume.";
        if (!Directory.Exists(logFolder)) return "Log folder not found: " + logFolder;
        if (current == null) return "Waiting for a combat log in " + logFolder;
        return "Watching " + Path.GetFileName(current) + " - boss pulls and finished keys are copied as they end.";
    }

    void SetPaused(bool p)
    {
        paused = p;
        Settings.Set("paused", p ? "1" : "0");
        if (!p) first = true;           // resume from now, not from where it stopped
        current = null;
        UpdateTooltip();
    }

    void ShowWindow()
    {
        if (window == null || window.IsDisposed)
        {
            window = new StatusWindow();
            window.CopyKey += delegate { ManualExport("key"); };
            window.CopyBoss += delegate { ManualExport("boss"); };
        }
        window.Fill(recent);
        window.SetStatus(Status());
        window.Show();
        if (window.WindowState == FormWindowState.Minimized) window.WindowState = FormWindowState.Normal;
        window.Activate();
    }

    void OpenLogFolder()
    {
        if (Directory.Exists(logFolder)) Process.Start("explorer.exe", "\"" + logFolder + "\"");
        else Notify("Log folder not found", logFolder);
    }

    void ChooseLogFolder()
    {
        using (var dlg = new FolderBrowserDialog())
        {
            dlg.Description = "Pick World of Warcraft\\_retail_\\Logs (where WoWCombatLog files are written).";
            if (Directory.Exists(logFolder)) dlg.SelectedPath = logFolder;
            if (dlg.ShowDialog() != DialogResult.OK) return;
            logFolder = dlg.SelectedPath;
            Settings.Set("logFolder", logFolder);
            current = null;
            first = true;
            UpdateTooltip();
        }
    }

    static bool StartsWithWindows()
    {
        using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
            return k != null && k.GetValue(AppName) != null;
    }

    void ToggleStartup()
    {
        using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
        {
            if (k.GetValue(AppName) != null) k.DeleteValue(AppName, false);
            else k.SetValue(AppName, "\"" + Application.ExecutablePath + "\"");
        }
    }

    protected override void ExitThreadCore()
    {
        poll.Dispose();
        tray.Visible = false;
        tray.Dispose();
        if (window != null && !window.IsDisposed) window.Close();
        base.ExitThreadCore();
    }
}

// Double-click the tray icon: the recent exports, any of which can be copied
// again, and the two manual copies.
class StatusWindow : Form
{
    public event EventHandler CopyKey, CopyBoss;
    readonly ListView list;
    readonly Label status;
    List<ExportEntry> entries = new List<ExportEntry>();

    public StatusWindow()
    {
        Text = "DPS Report Exporter";
        Icon = TrayIcon.Small();
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);
        ClientSize = new Size(560, 330);
        MinimumSize = new Size(420, 240);

        status = new Label { Dock = DockStyle.Top, Height = 36, Padding = new Padding(10, 10, 10, 0), AutoEllipsis = true };

        list = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false };
        list.Columns.Add("Time", 70);
        list.Columns.Add("Export", 440);
        list.DoubleClick += delegate { CopySelected(); };

        var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(6) };
        var copySel = new Button { Text = "Copy selected", AutoSize = true };
        copySel.Click += delegate { CopySelected(); };
        var boss = new Button { Text = "Copy last boss pull", AutoSize = true };
        boss.Click += delegate { if (CopyBoss != null) CopyBoss(this, EventArgs.Empty); };
        var key = new Button { Text = "Copy last key", AutoSize = true };
        key.Click += delegate { if (CopyKey != null) CopyKey(this, EventArgs.Empty); };
        bar.Controls.Add(copySel);
        bar.Controls.Add(boss);
        bar.Controls.Add(key);

        var pad = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10, 4, 10, 0) };
        pad.Controls.Add(list);
        Controls.Add(pad);
        Controls.Add(bar);
        Controls.Add(status);
        Resize += delegate { list.Columns[1].Width = Math.Max(100, list.ClientSize.Width - list.Columns[0].Width - 4); };
    }

    public void SetStatus(string s) { status.Text = s; }

    public void Fill(List<ExportEntry> recent)
    {
        entries = new List<ExportEntry>(recent);
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var e in entries)
            list.Items.Add(new ListViewItem(new[] { e.At.ToString("HH:mm"), e.What }));
        if (entries.Count == 0)
            list.Items.Add(new ListViewItem(new[] { "", "Nothing yet - exports appear here as boss pulls and keys end." }));
        list.EndUpdate();
    }

    void CopySelected()
    {
        if (list.SelectedIndices.Count == 0) return;
        int i = list.SelectedIndices[0];
        if (i >= entries.Count) return;
        if (TrayContext.CopyText(entries[i].Text))
            status.Text = "Copied: " + entries[i].What + ". In game: DPS Graph > Import, Ctrl+V.";
        else
            status.Text = "The clipboard was busy - try again.";
    }

    // Closing the window only hides it; the app keeps running in the tray.
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnFormClosing(e);
    }
}

// A few key=value lines in %AppData%\DPSReportExporter\settings.txt.
static class Settings
{
    static string FilePath
    {
        get
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DPSReportExporter");
            return Path.Combine(dir, "settings.txt");
        }
    }

    static Dictionary<string, string> Load()
    {
        var d = new Dictionary<string, string>();
        try
        {
            if (File.Exists(FilePath))
                foreach (string line in File.ReadAllLines(FilePath))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) d[line.Substring(0, eq)] = line.Substring(eq + 1);
                }
        }
        catch { }
        return d;
    }

    public static string Get(string key)
    {
        string v;
        return Load().TryGetValue(key, out v) ? v : null;
    }

    public static void Set(string key, string value)
    {
        try
        {
            var d = Load();
            d[key] = value;
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            var lines = new List<string>();
            foreach (var kv in d) lines.Add(kv.Key + "=" + kv.Value);
            File.WriteAllLines(FilePath, lines.ToArray());
        }
        catch { }
    }
}
