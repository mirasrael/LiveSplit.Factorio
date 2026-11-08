// LiveSplit auto splitter for Factorio 2.x (incl. Space Age).
//
// Reads game state from memory. All memory offsets are resolved at runtime from
// factorio.pdb (shipped with the game next to factorio.exe), so no addresses are
// hard-coded and the script keeps working across game updates as long as the
// structures it relies on keep their names.
//
// The script only READS memory. It does not change the game and does not disable
// achievements.
//
// Splits are driven by tags in segment names:
//   [research:railway]      split when the technology is researched
//   [build:locomotive]      split when at least 1 entity of that type was built
//   [build:lab=40]          ... at least 40 built
//   [rocket]  [rocket=2]    split when the player force has launched N rockets
//   [inventory:transport-belt=100]  (or [inv:...]) split when the player's
//                           character carries at least N of that item
// Segments without a tag are split manually.

state("factorio") {}

startup
{
    refreshRate = 20;

    settings.Add("gametime", true, "Use in-game time (ticks played, the same clock achievements use)");
    settings.Add("autostart", true, "Start the timer when a new map starts");
    settings.Add("autoreset", false, "Reset the timer when a new map starts");
    settings.Add("rewind", true, "Loading an earlier save undoes splits made after it (retry a segment)");
    settings.Add("catchup", true, "Loading a save skips segments it has already completed (starts the timer if needed)");
    settings.Add("tags", true, "Split on tags in segment names: [research:x] [build:x=N] [rocket=N] [inventory:x=N]");
    settings.Add("debug", false, "Log state changes (view with DebugView)");

    // P/Invoke into dbghelp.dll via Reflection.Emit: ASL scripts cannot declare
    // [DllImport] methods directly.
    var asmName = new System.Reflection.AssemblyName("FactorioAslDbgHelp");
    var asm = AppDomain.CurrentDomain.DefineDynamicAssembly(asmName, System.Reflection.Emit.AssemblyBuilderAccess.Run);
    var mod = asm.DefineDynamicModule("FactorioAslDbgHelp");
    var tb = mod.DefineType("DbgHelp", System.Reflection.TypeAttributes.Public | System.Reflection.TypeAttributes.Abstract | System.Reflection.TypeAttributes.Sealed);
    Action<string, Type, Type[]> def = (name, ret, args) =>
    {
        var m = tb.DefinePInvokeMethod(name, "dbghelp.dll",
            System.Reflection.MethodAttributes.Public | System.Reflection.MethodAttributes.Static | System.Reflection.MethodAttributes.PinvokeImpl,
            System.Reflection.CallingConventions.Standard, ret, args,
            System.Runtime.InteropServices.CallingConvention.Winapi,
            System.Runtime.InteropServices.CharSet.Unicode);
        m.SetImplementationFlags(m.GetMethodImplementationFlags() | System.Reflection.MethodImplAttributes.PreserveSig);
    };
    def("SymSetOptions", typeof(uint), new[] { typeof(uint) });
    def("SymInitializeW", typeof(bool), new[] { typeof(IntPtr), typeof(string), typeof(bool) });
    def("SymCleanup", typeof(bool), new[] { typeof(IntPtr) });
    def("SymLoadModuleExW", typeof(ulong), new[] { typeof(IntPtr), typeof(IntPtr), typeof(string), typeof(string), typeof(ulong), typeof(uint), typeof(IntPtr), typeof(uint) });
    def("SymFromNameW", typeof(bool), new[] { typeof(IntPtr), typeof(string), typeof(byte[]) });
    def("SymGetTypeFromNameW", typeof(bool), new[] { typeof(IntPtr), typeof(ulong), typeof(string), typeof(byte[]) });
    def("SymGetTypeInfo", typeof(bool), new[] { typeof(IntPtr), typeof(ulong), typeof(uint), typeof(int), typeof(byte[]) });
    vars.DbgHelp = tb.CreateType();

    vars.Log = (Action<string>)(msg => print("[Factorio] " + msg));
}

init
{
    vars.Ready = false;
    vars.Map = IntPtr.Zero;
    vars.Ticks = 0UL;
    vars.FreshMapStart = false;
    vars.FreshMapReset = false;
    vars.IndexError = false;
    Action<string> log = vars.Log;

    string exe = modules.First().FileName;
    string pdb = Path.ChangeExtension(exe, ".pdb");
    var O = new Dictionary<string, long>();

    string cacheDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LiveSplit.Factorio");
    var fi = new FileInfo(exe);
    string cacheFile = Path.Combine(cacheDir, "offsets-" + fi.Length + "-" + fi.LastWriteTimeUtc.Ticks + ".txt");

    // Bump when the set of resolved offsets changes; the cache is only trusted when
    // it was written by the same schema.
    const string SCHEMA = "3";
    if (File.Exists(cacheFile))
    {
        foreach (var line in File.ReadAllLines(cacheFile))
        {
            var kv = line.Split('=');
            if (kv.Length == 2) O[kv[0]] = long.Parse(kv[1]);
        }
        long schema;
        if (O.TryGetValue("schema", out schema) && schema.ToString() == SCHEMA) log("offsets loaded from cache " + cacheFile);
        else { O.Clear(); log("offset cache is outdated, resolving again"); }
    }
    if (O.Count > 0) { }
    else if (!File.Exists(pdb))
    {
        log("factorio.pdb not found next to " + exe + " - cannot resolve offsets");
    }
    else
    {
        log("resolving offsets from " + pdb + " (one-time, takes a few seconds)");
        Type D = vars.DbgHelp;
        Func<string, object[], object> call = (n, a) => D.GetMethod(n).Invoke(null, a);
        IntPtr h = new IntPtr(0x46414354);
        call("SymSetOptions", new object[] { (uint)0x6 });
        call("SymInitializeW", new object[] { h, null, false });
        try
        {
            ulong modBase = (ulong)call("SymLoadModuleExW", new object[] { h, IntPtr.Zero, exe, null, 0x140000000UL, 0u, IntPtr.Zero, 0u });
            if (modBase == 0) throw new Exception("SymLoadModuleExW failed");

            Func<byte[]> symBuf = () =>
            {
                var b = new byte[88 + 2 * 2048];
                BitConverter.GetBytes(88u).CopyTo(b, 0);     // SizeOfStruct
                BitConverter.GetBytes(2048u).CopyTo(b, 80);  // MaxNameLen
                return b;
            };
            Func<string, long> symRva = n =>
            {
                var b = symBuf();
                if (!(bool)call("SymFromNameW", new object[] { h, n, b })) throw new Exception("symbol not found: " + n);
                return (long)(BitConverter.ToUInt64(b, 56) - modBase);
            };
            Func<string, uint> typeId = n =>
            {
                var b = symBuf();
                if (!(bool)call("SymGetTypeFromNameW", new object[] { h, modBase, n, b })) throw new Exception("type not found: " + n);
                return BitConverter.ToUInt32(b, 4);
            };
            Func<uint, int, byte[], bool> info = (id, kind, b) => (bool)call("SymGetTypeInfo", new object[] { h, modBase, id, kind, b });
            Func<uint, int, ulong> infoNum = (id, kind) =>
            {
                var b = new byte[8];
                return info(id, kind, b) ? BitConverter.ToUInt64(b, 0) : ulong.MaxValue;
            };
            Func<uint, string> infoName = id =>
            {
                var b = new byte[8];
                if (!info(id, 1, b)) return null;
                return System.Runtime.InteropServices.Marshal.PtrToStringUni(new IntPtr(BitConverter.ToInt64(b, 0)));
            };
            Func<string, long> sizeOf = udt => (long)infoNum(typeId(udt), 2);
            Func<string, string, long> member = (udt, name) =>
            {
                uint t = typeId(udt);
                uint count = (uint)infoNum(t, 13);
                var b = new byte[8 + 4 * count];
                BitConverter.GetBytes(count).CopyTo(b, 0);
                if (!info(t, 7, b)) throw new Exception("no children: " + udt);
                for (int i = 0; i < count; i++)
                {
                    uint c = BitConverter.ToUInt32(b, 8 + 4 * i);
                    if ((uint)infoNum(c, 0) == 7 && infoName(c) == name) return (long)(uint)infoNum(c, 10);
                }
                throw new Exception("member not found: " + udt + "." + name);
            };
            // Offset of a (possibly indirect) base class inside a derived class.
            Func<uint, string, long, long> baseOffsetRec = null;
            baseOffsetRec = (t, want, acc) =>
            {
                uint count = (uint)infoNum(t, 13);
                var b = new byte[8 + 4 * count];
                BitConverter.GetBytes(count).CopyTo(b, 0);
                if (!info(t, 7, b)) return -1;
                for (int i = 0; i < count; i++)
                {
                    uint c = BitConverter.ToUInt32(b, 8 + 4 * i);
                    if ((uint)infoNum(c, 0) != 18) continue;   // SymTagBaseClass
                    uint bt = (uint)infoNum(c, 4);
                    long o = acc + (long)(uint)infoNum(c, 10);
                    if (infoName(bt) == want) return o;
                    long deeper = baseOffsetRec(bt, want, o);
                    if (deeper >= 0) return deeper;
                }
                return -1;
            };
            Func<string, string, long> baseOffset = (udt, want) =>
            {
                long o = baseOffsetRec(typeId(udt), want, 0);
                if (o < 0) throw new Exception("base not found: " + udt + " : " + want);
                return o;
            };

            const string FLOW = "FlowStatistics<IDWithQuality<ID<EntityPrototype,unsigned short> >,unsigned __int64,void>";
            O["global"] = symRva("global");
            O["entityPrototypes"] = symRva("PrototypeList<EntityPrototype>::indexToPrototype");
            O["gc.scenario"] = member("GlobalContext", "scenario");
            O["scenario.map"] = member("Scenario", "map");
            O["map.ticksPlayed"] = member("Map", "ticksPlayed");
            O["map.forceManager"] = member("Map", "forceManager");
            O["fm.forceDataList"] = member("ForceManager", "forceDataList");
            O["force.name"] = member("ForceData", "name");
            O["force.technologies"] = member("ForceData", "technologies");
            O["force.rocketsLaunched"] = member("ForceData", "rocketsLaunched");
            O["force.statistics"] = member("ForceData", "statistics");
            O["stats.size"] = sizeOf("ForceStatistics");
            O["stats.build"] = member("ForceStatistics", "buildCountStatistics");
            O["flow.input"] = member(FLOW, "inputRunningCounts");
            O["techs.list"] = member("Technologies", "indexToInstance");
            O["tech.size"] = sizeOf("Technology");
            O["tech.prototype"] = member("Technology", "prototype");
            O["tech.researchCount"] = member("Technology", "researchCount");
            O["proto.name"] = member("PrototypeBase", "name");
            // Character inventory: map.players[0] -> controllerManager.physicalController
            // (CharacterController) -> character targeter -> Character -> main inventory.
            O["itemPrototypes"] = symRva("PrototypeList<ItemPrototype>::indexToPrototype");
            O["map.players"] = member("Map", "players");
            O["player.controllerManager"] = member("Player", "controllerManager");
            O["cm.physicalController"] = member("ControllerManager", "physicalController");
            O["cc.character"] = member("CharacterController", "character");
            O["targeter.target"] = member("TargeterBase", "target");
            O["character.targetable"] = baseOffset("Character", "Targetable");
            O["character.inventory"] = member("Character", "inventory");
            O["inv.data"] = member("Inventory", "data");
            O["inv.size"] = member("Inventory", "dataSize");
            O["stack.size"] = sizeOf("ItemStack");
            O["stack.count"] = member("ItemStack", "count");
            O["stack.item"] = member("ItemStack", "itemID");

            O["schema"] = long.Parse(SCHEMA);
            Directory.CreateDirectory(cacheDir);
            File.WriteAllLines(cacheFile, O.Select(kv => kv.Key + "=" + kv.Value).ToArray());
            log("offsets resolved and cached");
        }
        catch (Exception e)
        {
            log("offset resolution failed: " + e.Message);
            O.Clear();
        }
        finally
        {
            call("SymCleanup", new object[] { h });
        }
    }

    if (O.Count > 0)
    {
        vars.O = O;
        long baseAddr = modules.First().BaseAddress.ToInt64();
        vars.Base = baseAddr;

        Func<IntPtr, long, IntPtr> add = (p, o) => new IntPtr(p.ToInt64() + o);
        Func<IntPtr, long, IntPtr> ptr = (p, o) => p == IntPtr.Zero ? IntPtr.Zero : memory.ReadPointer(add(p, o));
        Func<IntPtr, string> str = p =>
        {
            ulong size = memory.ReadValue<ulong>(add(p, 0x10));
            ulong cap = memory.ReadValue<ulong>(add(p, 0x18));
            IntPtr data = cap >= 16 ? memory.ReadPointer(p) : p;
            if (size == 0 || size > 512 || data == IntPtr.Zero) return "";
            return Encoding.UTF8.GetString(memory.ReadBytes(data, (int)size));
        };
        // std::vector<T> -> element addresses
        Func<IntPtr, long, List<IntPtr>> vec = (p, stride) =>
        {
            var res = new List<IntPtr>();
            IntPtr b = memory.ReadPointer(p), e = memory.ReadPointer(add(p, 8));
            if (b == IntPtr.Zero || e.ToInt64() < b.ToInt64()) return res;
            long n = (e.ToInt64() - b.ToInt64()) / stride;
            if (n > 100000) return res;
            for (long i = 0; i < n; i++) res.Add(add(b, i * stride));
            return res;
        };
        vars.Add = add; vars.Ptr = ptr; vars.Str = str; vars.Vec = vec;

        // Called whenever a different map is loaded: find the player force and index
        // technologies and entity prototypes by name.
        vars.IndexMap = (Action<IntPtr>)(map =>
        {
            vars.Force = IntPtr.Zero;
            var techs = new Dictionary<string, IntPtr>();
            foreach (var fp in vec(add(map, O["map.forceManager"] + O["fm.forceDataList"]), 8))
            {
                IntPtr f = memory.ReadPointer(fp);
                if (f == IntPtr.Zero || str(add(f, O["force.name"])) != "player") continue;
                vars.Force = f;
                IntPtr tl = ptr(f, O["force.technologies"]);
                if (tl != IntPtr.Zero)
                    foreach (var t in vec(add(tl, O["techs.list"]), O["tech.size"]))
                    {
                        IntPtr pr = memory.ReadPointer(add(t, O["tech.prototype"]));
                        if (pr != IntPtr.Zero) techs[str(add(pr, O["proto.name"]))] = t;
                    }
            }
            vars.Techs = techs;
            var ents = new Dictionary<string, int>();
            int idx = 0;
            foreach (var pp in vec(new IntPtr(baseAddr + O["entityPrototypes"]), 8))
            {
                IntPtr pr = memory.ReadPointer(pp);
                if (pr != IntPtr.Zero) { string n = str(add(pr, O["proto.name"])); if (n != "" && !ents.ContainsKey(n)) ents[n] = idx; }
                idx++;
            }
            vars.Entities = ents;
            var items = new Dictionary<string, int>();
            idx = 0;
            foreach (var pp in vec(new IntPtr(baseAddr + O["itemPrototypes"]), 8))
            {
                IntPtr pr = memory.ReadPointer(pp);
                if (pr != IntPtr.Zero) { string n = str(add(pr, O["proto.name"])); if (n != "" && !items.ContainsKey(n)) items[n] = idx; }
                idx++;
            }
            vars.Items = items;
            log("map indexed: " + techs.Count + " technologies, " + ents.Count + " entity prototypes, " + items.Count + " items");
        });

        vars.Researched = (Func<string, bool>)(name =>
        {
            Dictionary<string, IntPtr> techs = vars.Techs;
            IntPtr t;
            return techs.TryGetValue(name, out t) && memory.ReadValue<uint>(add(t, O["tech.researchCount"])) > 0;
        });

        vars.BuiltCount = (Func<string, ulong>)(name =>
        {
            Dictionary<string, int> ents = vars.Entities;
            IntPtr f = vars.Force;
            int id;
            if (f == IntPtr.Zero || !ents.TryGetValue(name, out id)) return 0UL;
            ulong total = 0;
            foreach (var s in vec(add(f, O["force.statistics"]), O["stats.size"]))
            {
                IntPtr flow = memory.ReadPointer(add(s, O["stats.build"]));
                if (flow == IntPtr.Zero) continue;
                foreach (var e in vec(add(flow, O["flow.input"]), 16))
                    if (memory.ReadValue<ushort>(e) == id) total += memory.ReadValue<ulong>(add(e, 8));
            }
            return total;
        });

        // Total count of an item in the first player's character main inventory
        // (all qualities). 0 when there is no character (e.g. god/editor mode).
        vars.InventoryCount = (Func<string, ulong>)(name =>
        {
            Dictionary<string, int> items = vars.Items;
            IntPtr map = vars.Map;
            int id;
            if (map == IntPtr.Zero || !items.TryGetValue(name, out id)) return 0UL;
            var players = vec(add(map, O["map.players"]), 8);
            if (players.Count == 0) return 0UL;
            IntPtr player = memory.ReadPointer(players[0]);
            IntPtr cc = ptr(player, O["player.controllerManager"] + O["cm.physicalController"]);
            IntPtr target = ptr(cc, O["cc.character"] + O["targeter.target"]);
            if (target == IntPtr.Zero) return 0UL;
            IntPtr inv = add(target, O["character.inventory"] - O["character.targetable"]);
            IntPtr data = memory.ReadPointer(add(inv, O["inv.data"]));
            int slots = memory.ReadValue<ushort>(add(inv, O["inv.size"]));
            if (data == IntPtr.Zero || slots > 2000) return 0UL;
            byte[] raw = memory.ReadBytes(data, slots * (int)O["stack.size"]);
            if (raw == null) return 0UL;
            ulong total = 0;
            for (int i = 0; i < slots; i++)
            {
                int o = i * (int)O["stack.size"];
                uint count = BitConverter.ToUInt32(raw, o + (int)O["stack.count"]);
                if (count > 0 && BitConverter.ToUInt16(raw, o + (int)O["stack.item"]) == id) total += count;
            }
            return total;
        });

        vars.Rockets = (Func<uint>)(() =>
        {
            IntPtr f = vars.Force;
            return f == IntPtr.Zero ? 0u : memory.ReadValue<uint>(add(f, O["force.rocketsLaunched"]));
        });

        // Evaluates the tag in a segment name: -1 = no tag (or not usable for catching
        // up when monotonicOnly), 0 = condition not met yet, 1 = met.
        // Inventory counts go down when items are used, so they say nothing about
        // progress and are excluded when monotonicOnly is set.
        vars.Eval = (Func<string, bool, int>)((segName, monotonicOnly) =>
        {
            var m = System.Text.RegularExpressions.Regex.Match(segName ?? "", @"\[(research|build|rocket|inventory|inv)(?::([A-Za-z0-9_\-]+))?(?:=(\d+))?\]");
            if (!m.Success) return -1;
            string kind = m.Groups[1].Value, target = m.Groups[2].Value;
            ulong need = m.Groups[3].Success ? ulong.Parse(m.Groups[3].Value) : 1UL;
            bool ok;
            if (kind == "research") ok = vars.Researched(target);
            else if (kind == "build") ok = vars.BuiltCount(target) >= need;
            else if (kind == "rocket") ok = (ulong)vars.Rockets() >= need;
            else if (monotonicOnly) return -1;
            else ok = vars.InventoryCount(target) >= need;
            return ok ? 1 : 0;
        });

        // Number of segments already completed in the loaded map: everything up to and
        // including the last segment whose (monotonic) tag is already satisfied.
        vars.CompletedSegments = (Func<IRun, int>)(run =>
        {
            int done = 0;
            for (int i = 0; i < run.Count; i++)
                if (vars.Eval(run[i].Name, true) == 1) done = i + 1;
            return done;
        });

        vars.Ready = true;
        log("ready");
    }
}

update
{
    if (!vars.Ready) return false;
    Dictionary<string, long> O = vars.O;
    Func<IntPtr, long, IntPtr> ptr = vars.Ptr;
    long b = vars.Base;

    IntPtr gc = memory.ReadPointer(new IntPtr(b + O["global"]));
    IntPtr sc = ptr(gc, O["gc.scenario"]);
    IntPtr map = ptr(sc, O["scenario.map"]);
    ulong ticks = map == IntPtr.Zero ? 0UL : memory.ReadValue<ulong>(new IntPtr(map.ToInt64() + O["map.ticksPlayed"]));

    IntPtr prevMap = vars.Map;
    if (map != prevMap)
    {
        vars.Map = map;
        if (map != IntPtr.Zero)
        {
            // A map that is still loading can be half-initialised: retry on the next
            // update, but only log the first failure.
            try
            {
                vars.IndexMap(map);
                vars.IndexError = false;
                // Warn about tags that name nothing in this game (typos, wrong prototype
                // names, mods missing) - such a segment would never split on its own.
                Dictionary<string, IntPtr> techs = vars.Techs;
                Dictionary<string, int> ents = vars.Entities, items = vars.Items;
                foreach (var seg in timer.Run)
                    foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(seg.Name ?? "", @"\[(research|build|inventory|inv):([A-Za-z0-9_\-]+)(?:=\d+)?\]"))
                    {
                        string k = m.Groups[1].Value, n = m.Groups[2].Value;
                        bool known = k == "research" ? techs.ContainsKey(n) : k == "build" ? ents.ContainsKey(n) : items.ContainsKey(n);
                        if (!known) vars.Log("unknown " + k + " name '" + n + "' in segment: " + seg.Name);
                    }
            }
            catch (Exception e)
            {
                if (!vars.IndexError) vars.Log("indexing failed (will retry): " + e.Message);
                vars.IndexError = true;
                vars.Map = IntPtr.Zero;
            }
            bool fresh = ticks < 600;   // less than 10 s played: a new game, not a loaded save
            vars.FreshMapStart = fresh;
            vars.FreshMapReset = fresh;
            if (settings["debug"]) vars.Log("map " + map.ToString("X") + " ticks " + ticks + (fresh ? " (new game)" : ""));

            // A save was loaded (not a new game): bring the splits in line with it.
            //  - rewind:  undo splits made after the save was taken (retrying a segment)
            //  - catchup: skip forward over segments the save has already completed,
            //             starting the timer first if it is not running
            if (!fresh && vars.Map != IntPtr.Zero && (settings["rewind"] || settings["catchup"]))
            {
                var model = new TimerModel { CurrentState = timer };
                var saveTime = TimeSpan.FromSeconds((double)ticks / 60.0);
                int done = 0;
                try { done = vars.CompletedSegments(timer.Run); } catch (Exception) { }
                done = Math.Min(done, timer.Run.Count - 1);   // the last segment is never skipped
                string where = "save loaded at " + saveTime.ToString(@"h\:mm\:ss") + ": ";

                if (settings["rewind"] && (timer.CurrentPhase == TimerPhase.Running || timer.CurrentPhase == TimerPhase.Ended))
                {
                    int undone = 0;
                    while (timer.CurrentSplitIndex != 0)
                    {
                        int last = timer.CurrentPhase == TimerPhase.Ended ? timer.Run.Count - 1 : timer.CurrentSplitIndex - 1;
                        var st = timer.Run[last].SplitTime.GameTime;
                        // Timed split: undo when it happened after the save.
                        // Skipped split (no time): undo unless the save proves it done.
                        bool undo = st.HasValue ? st.Value > saveTime : last >= done;
                        if (!undo) break;
                        model.UndoSplit();
                        undone++;
                    }
                    if (undone > 0) vars.Log(where + "undid " + undone + " split(s)");
                }

                if (settings["catchup"] && done > 0)
                {
                    if (timer.CurrentPhase == TimerPhase.NotRunning)
                    {
                        model.Start();
                        vars.Log(where + "timer started");
                    }
                    int skipped = 0;
                    while (timer.CurrentPhase == TimerPhase.Running && timer.CurrentSplitIndex < done)
                    {
                        model.SkipSplit();
                        skipped++;
                    }
                    if (skipped > 0) vars.Log(where + "skipped " + skipped + " already completed segment(s)");
                }
            }
        }
    }
    vars.Ticks = ticks;
}

start
{
    if (settings["autostart"] && vars.FreshMapStart && vars.Ticks > 0UL)
    {
        vars.FreshMapStart = false;
        return true;
    }
}

reset
{
    if (settings["autoreset"] && vars.FreshMapReset)
    {
        vars.FreshMapReset = false;
        return true;
    }
}

split
{
    if (!settings["tags"] || vars.Map == IntPtr.Zero || timer.CurrentSplitIndex < 0) return false;
    try { return vars.Eval(timer.Run[timer.CurrentSplitIndex].Name, false) == 1; }
    catch (Exception) { return false; }
}

isLoading
{
    return settings["gametime"];
}

gameTime
{
    if (settings["gametime"]) return TimeSpan.FromSeconds((double)vars.Ticks / 60.0);
}

exit
{
    vars.Ready = false;
}
