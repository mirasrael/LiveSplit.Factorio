// LiveSplit layout component: shows what the current segment needs (items to craft,
// entities to build, research) with Factorio icons and live have/need counters.
//
// Counters come from Factorio.asl, which publishes a query delegate in the AppDomain
// ("LiveSplit.Factorio.Query"). Without the script the component still shows the list.
//
// Written for the C# 5 compiler that ships with .NET Framework (csc v4.0.30319).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Xml;
using LiveSplit.Model;
using LiveSplit.UI;
using LiveSplit.UI.Components;

[assembly: ComponentFactory(typeof(LiveSplit.Factorio.FactorioStepFactory))]

namespace LiveSplit.Factorio
{
    public class FactorioStepFactory : IComponentFactory
    {
        public string ComponentName { get { return "Factorio Step"; } }
        public string Description { get { return "Shows the current Factorio step with icons and live item / build / research counters."; } }
        public ComponentCategory Category { get { return ComponentCategory.Information; } }
        public IComponent Create(LiveSplitState state) { return new FactorioStepComponent(state); }
        public string UpdateName { get { return ComponentName; } }
        public string XMLURL { get { return ""; } }
        public string UpdateURL { get { return ""; } }
        public Version Version { get { return new Version(1, 0, 0); } }
    }

    // One thing the step asks for.
    class Entry
    {
        public string Kind;   // inv | build | research | rocket
        public string Name;
        public long Need;
        public long Have = -1; // -1 = unknown (no game / no script)
        public bool Done { get { return Have >= 0 && Have >= Need; } }
    }

    // Parsed steps file: segment-name prefix -> entries (+ optional note).
    class StepsFile
    {
        public readonly List<KeyValuePair<string, List<Entry>>> Steps = new List<KeyValuePair<string, List<Entry>>>();
        public readonly Dictionary<string, string> Notes = new Dictionary<string, string>();

        static readonly Regex Token = new Regex(@"^(?:(inv|inventory|build|research|rocket):)?([A-Za-z0-9_\-]+)?(?:=(\d+))?$");

        public static List<Entry> ParseEntries(string line)
        {
            var list = new List<Entry>();
            foreach (var raw in line.Split(new[] { ' ', '\t', ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var m = Token.Match(raw.Trim());
                if (!m.Success) continue;
                string kind = m.Groups[1].Success ? m.Groups[1].Value : "inv";
                if (kind == "inventory") kind = "inv";
                string name = m.Groups[2].Value;
                if (kind == "rocket") name = "rocket";
                if (name == "") continue;
                long need = m.Groups[3].Success ? long.Parse(m.Groups[3].Value) : 1;
                list.Add(new Entry { Kind = kind, Name = name, Need = need });
            }
            return list;
        }

        public static StepsFile Load(string path)
        {
            var f = new StepsFile();
            string key = null;
            List<Entry> cur = null;
            foreach (var l in File.ReadAllLines(path))
            {
                var line = l.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                if (line.StartsWith(">"))
                {
                    key = Normalize(line.Substring(1));
                    cur = new List<Entry>();
                    f.Steps.Add(new KeyValuePair<string, List<Entry>>(key, cur));
                }
                else if (cur != null && line.StartsWith("note:", StringComparison.OrdinalIgnoreCase))
                    f.Notes[key] = line.Substring(5).Trim();
                else if (cur != null)
                {
                    // "split:" is the auto splitter's condition; show it too (once).
                    bool split = line.StartsWith("split:", StringComparison.OrdinalIgnoreCase);
                    foreach (var e in ParseEntries(split ? line.Substring(6) : line))
                    {
                        bool dup = false;
                        foreach (var o in cur) if (o.Kind == e.Kind && o.Name == e.Name) { dup = true; o.Need = Math.Max(o.Need, e.Need); }
                        if (!dup) cur.Add(e);
                    }
                }
            }
            return f;
        }

        // Segment name without the subsplit prefix ("-", "{Group}") and without tags.
        public static string Normalize(string s)
        {
            s = (s ?? "").Trim();
            if (s.StartsWith("-")) s = s.Substring(1);
            else if (s.StartsWith("{") && s.IndexOf('}') > 0) s = s.Substring(s.IndexOf('}') + 1);
            s = Regex.Replace(s, @"\[[^\]]*\]", "");
            return Regex.Replace(s, @"\s+", " ").Trim();
        }

        // Longest prefix match.
        public bool Find(string segmentName, out List<Entry> entries, out string note)
        {
            string n = Normalize(segmentName), best = null;
            entries = null; note = null;
            foreach (var kv in Steps)
                if (kv.Key.Length > 0 && n.StartsWith(kv.Key, StringComparison.OrdinalIgnoreCase) && (best == null || kv.Key.Length > best.Length))
                { best = kv.Key; entries = kv.Value; }
            if (best == null) return false;
            Notes.TryGetValue(best, out note);
            return true;
        }
    }

    // Loads 64x64 icons from the game's data folder by prototype name.
    class IconCache
    {
        static readonly string[] Mods = { "space-age", "base", "quality", "elevated-rails", "recycler", "core" };
        readonly Dictionary<string, Image> cache = new Dictionary<string, Image>();
        public string DataDir;

        public Image Get(string kind, string name)
        {
            string key = kind + ":" + name;
            Image img;
            if (cache.TryGetValue(key, out img)) return img;
            img = null;
            if (DataDir != null && Directory.Exists(DataDir))
            {
                var names = new List<string> { name };
                if (kind == "research")
                {
                    // Levelled technologies: "physical-projectile-damage-7" -> "...-damage-1" / "...-damage".
                    var m = Regex.Match(name, @"^(.*)-(\d+)$");
                    if (m.Success) { names.Add(m.Groups[1].Value + "-1"); names.Add(m.Groups[1].Value); }
                    else names.Add(name + "-1");   // "automation" -> automation-1.png
                    if (name.StartsWith("planet-discovery-")) names.Add(name.Substring("planet-discovery-".Length));
                }
                if (kind == "rocket") names = new List<string> { "rocket-part", "rocket-silo" };
                var dirs = kind == "research"
                    ? new[] { "graphics/technology", "graphics/icons", "graphics/icons/fluid" }
                    : new[] { "graphics/icons", "graphics/icons/fluid", "graphics/technology" };
                foreach (var n in names)
                {
                    foreach (var d in dirs)
                    {
                        foreach (var mod in Mods)
                        {
                            var p = Path.Combine(Path.Combine(DataDir, mod), Path.Combine(d, n + ".png"));
                            if (File.Exists(p)) { img = LoadSquare(p); break; }
                        }
                        if (img != null) break;
                    }
                    if (img != null) break;
                }
            }
            cache[key] = img;
            return img;
        }

        // Factorio icons hold mipmaps side by side; keep the largest (left, square) one.
        static Image LoadSquare(string path)
        {
            try
            {
                using (var src = Image.FromFile(path))
                {
                    int h = src.Height;
                    var dst = new Bitmap(64, 64);
                    using (var g = Graphics.FromImage(dst))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.DrawImage(src, new Rectangle(0, 0, 64, 64), new Rectangle(0, 0, h, h), GraphicsUnit.Pixel);
                    }
                    return dst;
                }
            }
            catch (Exception) { return null; }
        }

        public void Clear() { cache.Clear(); }
    }

    public class FactorioStepComponent : IComponent
    {
        readonly LiveSplitState state;
        readonly IconCache icons = new IconCache();
        readonly FactorioStepSettings settings = new FactorioStepSettings();

        StepsFile steps;
        string stepsPath;
        DateTime stepsTime;
        DateTime nextPoll = DateTime.MinValue, nextFileCheck = DateTime.MinValue;

        int segIndex = -2;
        List<Entry> entries = new List<Entry>();
        string note;

        // layout
        float height = 30, hWidth = 100, lastWidth = -1;
        List<RectangleF> cells = new List<RectangleF>();
        Font font, noteFont;
        float fontBase = -1;

        public FactorioStepComponent(LiveSplitState state) { this.state = state; }

        public string ComponentName { get { return "Factorio Step"; } }
        public float HorizontalWidth { get { return hWidth; } }
        public float MinimumHeight { get { return 20; } }
        public float VerticalHeight { get { return height; } }
        public float MinimumWidth { get { return 60; } }
        public float PaddingTop { get { return 0; } }
        public float PaddingBottom { get { return 0; } }
        public float PaddingLeft { get { return 6; } }
        public float PaddingRight { get { return 6; } }
        public IDictionary<string, Action> ContextMenuControls { get { return null; } }

        string ResolveStepsPath()
        {
            if (!string.IsNullOrEmpty(settings.StepsPath)) return settings.StepsPath;
            var run = state.Run;
            if (run == null || string.IsNullOrEmpty(run.FilePath)) return null;
            return Path.ChangeExtension(run.FilePath, ".steps.txt");
        }

        string ResolveDataDir()
        {
            if (!string.IsNullOrEmpty(settings.FactorioDir))
            {
                var d = settings.FactorioDir;
                return Directory.Exists(Path.Combine(d, "data")) ? Path.Combine(d, "data") : d;
            }
            try
            {
                foreach (var p in Process.GetProcessesByName("factorio"))
                {
                    var exe = p.MainModule.FileName;          // ...\Factorio\bin\x64\factorio.exe
                    var root = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(exe)));
                    var data = Path.Combine(root, "data");
                    if (Directory.Exists(data)) return data;
                }
            }
            catch (Exception) { }
            var steam = @"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data";
            return Directory.Exists(steam) ? steam : null;
        }

        void ReloadSteps(bool force)
        {
            var p = ResolveStepsPath();
            DateTime t = DateTime.MinValue;
            try { if (p != null && File.Exists(p)) t = File.GetLastWriteTimeUtc(p); } catch (Exception) { }
            if (!force && p == stepsPath && t == stepsTime) return;
            stepsPath = p; stepsTime = t;
            try { steps = t != DateTime.MinValue ? StepsFile.Load(p) : null; }
            catch (Exception) { steps = null; }
            segIndex = -2; // re-select entries
        }

        void SelectSegment(int idx)
        {
            segIndex = idx;
            entries = new List<Entry>();
            note = null;
            var run = state.Run;
            if (run == null || run.Count == 0 || idx >= run.Count) return;
            string name = run[Math.Max(idx, 0)].Name;
            List<Entry> found;
            if (steps != null && steps.Find(name, out found, out note))
            {
                foreach (var e in found) entries.Add(new Entry { Kind = e.Kind, Name = e.Name, Need = e.Need });
            }
            else
            {
                // No steps file entry: fall back to the tags in the segment name.
                foreach (Match m in Regex.Matches(name ?? "", @"\[((?:research|build|rocket|inventory|inv)[^\]]*)\]"))
                    entries.AddRange(StepsFile.ParseEntries(m.Groups[1].Value));
            }
            lastWidth = -1;
            nextPoll = DateTime.MinValue;
        }

        void Poll()
        {
            Func<string, string, long> q = null;
            try { q = AppDomain.CurrentDomain.GetData("LiveSplit.Factorio.Query") as Func<string, string, long>; } catch (Exception) { }
            foreach (var e in entries)
            {
                long v = -1;
                if (q != null) { try { v = q(e.Kind, e.Name); } catch (Exception) { v = -1; } }
                e.Have = v;
            }
        }

        void EnsureFonts()
        {
            float size = settings.IconSize;
            if (font != null && fontBase == size) return;
            var fam = state.LayoutSettings.TextFont.FontFamily;
            if (font != null) font.Dispose();
            if (noteFont != null) noteFont.Dispose();
            font = new Font(fam, Math.Max(8f, size * 0.5f), FontStyle.Bold, GraphicsUnit.Pixel);
            noteFont = new Font(fam, Math.Max(8f, size * 0.45f), FontStyle.Regular, GraphicsUnit.Pixel);
            fontBase = size;
            lastWidth = -1;
        }

        string Label(Entry e)
        {
            if (e.Kind == "research") return e.Have < 0 ? "" : (e.Done ? "✓" : "…");
            string need = e.Need.ToString();
            if (e.Have < 0) return "×" + need;
            return Math.Min(e.Have, 99999).ToString() + "/" + need;
        }

        void Layout(Graphics g, float width)
        {
            EnsureFonts();
            cells.Clear();
            float icon = settings.IconSize, gap = 4, cellGap = 10, x = 0, y = 4, rowH = icon + 4;
            float maxX = 0;
            foreach (var e in entries)
            {
                float tw = g.MeasureString(Label(e), font).Width;
                float w = icon + gap + tw;
                if (width > 0 && x > 0 && x + w > width) { x = 0; y += rowH; }
                cells.Add(new RectangleF(x, y, w, icon));
                x += w + cellGap;
                maxX = Math.Max(maxX, x);
            }
            float h = (entries.Count == 0 ? rowH : y + rowH) + 2;
            if (!string.IsNullOrEmpty(note)) h += noteFont.GetHeight(g) * NoteLines(g, width) + 2;
            height = Math.Max(h, icon + 8);
            hWidth = Math.Max(60, maxX);
            lastWidth = width;
        }

        int NoteLines(Graphics g, float width)
        {
            if (string.IsNullOrEmpty(note) || width <= 0) return string.IsNullOrEmpty(note) ? 0 : 1;
            var sz = g.MeasureString(note, noteFont, (int)Math.Max(10, width));
            return Math.Max(1, (int)Math.Ceiling(sz.Height / noteFont.GetHeight(g) - 0.01));
        }

        public void Update(IInvalidator invalidator, LiveSplitState lsState, float width, float h, LayoutMode mode)
        {
            var now = DateTime.UtcNow;
            if (now >= nextFileCheck) { ReloadSteps(false); nextFileCheck = now.AddSeconds(2); }
            if (icons.DataDir == null) icons.DataDir = ResolveDataDir();

            int idx = lsState.CurrentPhase == TimerPhase.NotRunning ? 0 : lsState.CurrentSplitIndex;
            if (lsState.CurrentPhase == TimerPhase.Ended) idx = int.MaxValue;
            if (idx != segIndex) SelectSegment(idx);

            if (now >= nextPoll) { Poll(); nextPoll = now.AddMilliseconds(500); lastWidth = -1; }
            if (invalidator != null) invalidator.Invalidate(0, 0, width, h);
        }

        void Draw(Graphics g, float width, float heightAvail)
        {
            float inner = width - PaddingLeft - PaddingRight;
            if (lastWidth != inner) Layout(g, inner);
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            var ls = state.LayoutSettings;
            float icon = settings.IconSize;
            float bottom = 0;
            for (int i = 0; i < entries.Count && i < cells.Count; i++)
            {
                var e = entries[i];
                var c = cells[i];
                float x = PaddingLeft + c.X, y = c.Y;
                var img = icons.Get(e.Kind, e.Name);
                var ir = new RectangleF(x, y, icon, icon);
                if (img != null)
                {
                    if (e.Done)
                    {
                        using (var b = new SolidBrush(Color.FromArgb(60, ls.AheadGainingTimeColor))) g.FillRectangle(b, ir);
                    }
                    g.DrawImage(img, ir);
                }
                else
                {
                    using (var p = new Pen(ls.TextColor)) g.DrawRectangle(p, x, y, icon - 1, icon - 1);
                    using (var b = new SolidBrush(ls.TextColor))
                    using (var f = new Font(font.FontFamily, Math.Max(6f, icon * 0.22f), FontStyle.Regular, GraphicsUnit.Pixel))
                        g.DrawString(e.Name, f, b, new RectangleF(x + 1, y + 1, icon - 2, icon - 2));
                }
                Color tc = e.Have < 0 ? ls.TextColor : e.Done ? ls.AheadGainingTimeColor : ls.TextColor;
                var label = Label(e);
                var sz = g.MeasureString(label, font);
                float ty = y + (icon - sz.Height) / 2;
                if (ls.DropShadows)
                    using (var sb = new SolidBrush(ls.ShadowsColor)) g.DrawString(label, font, sb, x + icon + 5, ty + 1);
                using (var b = new SolidBrush(tc)) g.DrawString(label, font, b, x + icon + 4, ty);
                bottom = Math.Max(bottom, y + icon);
            }
            if (!string.IsNullOrEmpty(note))
            {
                float ny = (entries.Count == 0 ? 4 : bottom + 4);
                using (var b = new SolidBrush(ls.TextColor))
                    g.DrawString(note, noteFont, b, new RectangleF(PaddingLeft, ny, Math.Max(10, inner), heightAvail - ny));
            }
        }

        public void DrawVertical(Graphics g, LiveSplitState lsState, float width, Region clipRegion)
        {
            Draw(g, width, VerticalHeight);
        }

        public void DrawHorizontal(Graphics g, LiveSplitState lsState, float h, Region clipRegion)
        {
            Draw(g, 0, h);   // width 0 = a single row
        }

        public Control GetSettingsControl(LayoutMode mode) { return settings.Control(this); }
        public XmlNode GetSettings(XmlDocument document) { return settings.ToXml(document); }

        public void SetSettings(XmlNode node)
        {
            settings.FromXml(node);
            SettingsChanged();
        }

        internal void SettingsChanged()
        {
            icons.Clear();
            icons.DataDir = null;
            fontBase = -1;
            ReloadSteps(true);
        }

        public void Dispose()
        {
            if (font != null) font.Dispose();
            if (noteFont != null) noteFont.Dispose();
        }
    }

    public class FactorioStepSettings
    {
        public string StepsPath = "";
        public string FactorioDir = "";
        public int IconSize = 28;

        public XmlNode ToXml(XmlDocument doc)
        {
            var root = doc.CreateElement("Settings");
            Add(doc, root, "Version", "1");
            Add(doc, root, "StepsPath", StepsPath);
            Add(doc, root, "FactorioDir", FactorioDir);
            Add(doc, root, "IconSize", IconSize.ToString());
            return root;
        }

        static void Add(XmlDocument doc, XmlElement root, string name, string value)
        {
            var e = doc.CreateElement(name);
            e.InnerText = value;
            root.AppendChild(e);
        }

        public void FromXml(XmlNode node)
        {
            if (node == null) return;
            var n = node["StepsPath"]; if (n != null) StepsPath = n.InnerText;
            n = node["FactorioDir"]; if (n != null) FactorioDir = n.InnerText;
            n = node["IconSize"]; int s; if (n != null && int.TryParse(n.InnerText, out s)) IconSize = Math.Max(12, Math.Min(64, s));
        }

        public Control Control(FactorioStepComponent owner)
        {
            var t = new TableLayoutPanel { ColumnCount = 3, RowCount = 4, Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(7) };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

            var steps = new TextBox { Text = StepsPath, Dock = DockStyle.Fill };
            var dir = new TextBox { Text = FactorioDir, Dock = DockStyle.Fill };
            var size = new NumericUpDown { Minimum = 12, Maximum = 64, Value = IconSize, Width = 60 };
            var b1 = new Button { Text = "Browse...", AutoSize = true };
            var b2 = new Button { Text = "Browse...", AutoSize = true };

            steps.TextChanged += (s, e) => { StepsPath = steps.Text.Trim(); owner.SettingsChanged(); };
            dir.TextChanged += (s, e) => { FactorioDir = dir.Text.Trim(); owner.SettingsChanged(); };
            size.ValueChanged += (s, e) => { IconSize = (int)size.Value; owner.SettingsChanged(); };
            b1.Click += (s, e) =>
            {
                using (var d = new OpenFileDialog { Filter = "Steps file (*.steps.txt;*.txt)|*.steps.txt;*.txt|All files|*.*" })
                    if (d.ShowDialog() == DialogResult.OK) steps.Text = d.FileName;
            };
            b2.Click += (s, e) =>
            {
                using (var d = new FolderBrowserDialog { Description = "Factorio folder (the one with data\\ and bin\\)" })
                    if (d.ShowDialog() == DialogResult.OK) dir.Text = d.SelectedPath;
            };

            t.Controls.Add(new Label { Text = "Steps file:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
            t.Controls.Add(steps, 1, 0); t.Controls.Add(b1, 2, 0);
            t.Controls.Add(new Label { Text = "Factorio folder:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
            t.Controls.Add(dir, 1, 1); t.Controls.Add(b2, 2, 1);
            t.Controls.Add(new Label { Text = "Icon size:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 2);
            t.Controls.Add(size, 1, 2);
            var hint = new Label
            {
                AutoSize = true,
                MaximumSize = new Size(420, 0),
                Text = "Empty = automatic: <splits>.steps.txt next to the .lss, and the folder of the running game.\n" +
                       "Live counters need the Factorio.asl auto splitter in the same layout."
            };
            t.Controls.Add(hint, 0, 3);
            t.SetColumnSpan(hint, 3);
            return t;
        }
    }
}
