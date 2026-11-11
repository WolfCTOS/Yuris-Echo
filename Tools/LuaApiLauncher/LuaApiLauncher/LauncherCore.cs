using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;

namespace LuaApiLauncher;

public sealed class ModFile
{
    public string RelPath { get; set; } = "";
    public long Size { get; set; }
}

public sealed class ModInfo
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
    public string Author { get; set; } = "";
    public string Description { get; set; } = "";
    public string NameEn { get; set; } = "";
    public string DescriptionEn { get; set; } = "";
    public string Folder { get; set; } = "";
    public List<string> Conflicts { get; set; } = new();
    public List<string> Dependencies { get; set; } = new();
    public string RawWarnings { get; set; } = "";
    public List<ModFile> LuaFiles { get; set; } = new();
    public List<ModFile> JsonFiles { get; set; } = new();
    public int TotalFileCount { get; set; }

    /// <summary>Display name for UI: English translation when available in English mode, otherwise original.</summary>
    public string DisplayName => L10n.Current == L10n.English && !string.IsNullOrWhiteSpace(NameEn) ? NameEn : Name;

    /// <summary>Display description for UI: English translation when available in English mode, otherwise original.</summary>
    public string DisplayDescription => L10n.Current == L10n.English && !string.IsNullOrWhiteSpace(DescriptionEn) ? DescriptionEn : Description;

    /// <summary>True when the mod has a main.lua, which is what the LuaAPI loader executes.</summary>
    public bool IsLuaApi { get; set; }

    /// <summary>
    /// Whether the mod is enabled out of the box. The mod declares it itself
    /// in mod.json ("load": { "active": false } for debug/optional mods); mods
    /// without a mod.json stay off.
    /// </summary>
    public bool DefaultActive { get; set; }

    /// <summary>Short category shown next to the mod name (Баланс / ИИ / Контент / LuaAPI).</summary>
    public string Tag { get; set; } = "";

    /// <summary>Development-only mod - hidden unless the user asks for it.</summary>
    public bool IsDev { get; set; }

    /// <summary>What the mod changes in the rules (mod.json "rules").</summary>
    public string Rules { get; set; } = "";
}

public sealed class MapEntry
{
    public string Name { get; set; } = "";
    public string FilePath { get; set; } = "";
    public string Relative { get; set; } = "";
    public string Extension { get; set; } = "";

    // Catalog/metadata fields (populated by MapCatalog).
    public string DisplayName { get; set; } = "";
    public string Author { get; set; } = "";
    public List<string> GameModes { get; set; } = new();
    public int MinPlayers { get; set; } = 1;
    public int MaxPlayers { get; set; } = 8;
    public bool MaxPlayersKnown { get; set; }
    public bool EnforceMaxPlayers { get; set; }
    public string PreviewPath { get; set; } = "";
    public bool InMpMaps { get; set; }
    public bool HasMpSection { get; set; }

    public override string ToString() => string.IsNullOrWhiteSpace(DisplayName) ? Name : DisplayName;
}

/// <summary>
/// The CnCNet client's own way of starting the game, read from
/// Resources\ClientDefinitions.ini. The launcher reuses it so a mission is
/// started exactly like the client starts it.
/// </summary>
public sealed class ClientLaunchDefinition
{
    /// <summary>The launcher executable the client uses (Syringe.exe).</summary>
    public string LauncherExe { get; set; } = "Syringe.exe";

    /// <summary>Everything after the launcher executable, split into arguments.</summary>
    public List<string> ExtraParams { get; set; } = new();

    /// <summary>True when the client definition file was found and parsed.</summary>
    public bool Found { get; set; }
}

/// <summary>Line-preserving INI access: only the keys we set are rewritten.</summary>
public sealed class IniFile
{
    private readonly List<string> _lines;
    private IniFile(List<string> lines) => _lines = lines;

    public static IniFile Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return new(new List<string>());
            return new(File.ReadAllLines(path).ToList());
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Failed to read INI file: " + path, ex);
            return new(new List<string>());
        }
    }

    public IEnumerable<(string Key, string Value)> Section(string section)
    {
        var start = SectionStart(section);
        if (start < 0) yield break;
        for (var i = start + 1; i < _lines.Count; i++)
        {
            var t = _lines[i].Trim();
            if (t.StartsWith('[')) yield break;
            if (t.Length == 0 || t.StartsWith(';')) continue;
            var eq = t.IndexOf('=');
            if (eq <= 0) continue;
            yield return (t[..eq].Trim(), t[(eq + 1)..].Trim());
        }
    }

    public string? Get(string section, string key)
    {
        foreach (var (k, v) in Section(section))
            if (k.Equals(key, StringComparison.OrdinalIgnoreCase)) return v;
        return null;
    }

    public void Set(string section, string key, string value)
    {
        var start = SectionStart(section);
        if (start < 0)
        {
            _lines.Add("[" + section + "]");
            _lines.Add(key + "=" + value);
            _lines.Add("");
            return;
        }

        var insertAt = start;
        for (var i = start + 1; i < _lines.Count; i++)
        {
            var t = _lines[i].Trim();
            if (t.StartsWith('[')) break;
            var eq = t.IndexOf('=');
            if (eq <= 0) continue; // keep new keys with the section's keys, not after its trailing comments
            if (t[..eq].Trim().Equals(key, StringComparison.OrdinalIgnoreCase))
            {
                _lines[i] = key + "=" + value;
                return;
            }
            insertAt = i;
        }
        _lines.Insert(insertAt + 1, key + "=" + value);
    }

    public void Save(string path) => File.WriteAllLines(path, _lines);

    private int SectionStart(string section)
    {
        for (var i = 0; i < _lines.Count; i++)
            if (_lines[i].Trim().Equals("[" + section + "]", StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }
}

/// <summary>The client's own settings, stored in RA2MD.INI.</summary>
public sealed class ClientSettings
{
    public int ResolutionX = 1366, ResolutionY = 768;
    public int DetailLevel = 2, GameSpeed = 1, Difficulty = 1;
    public string Renderer = "Default", Language = "en";
    public bool BorderlessClient = true, WindowedMode, IntegerScaling, ToolTips = true;
    public int GameResX = 1366, GameResY = 768;
    public bool BorderlessFrame, BackBuffer;
    public bool QuickExit = true, AllowChat = true, AllowTaunts = true, SkipScoreScreen, RecordReplays = true;
    public bool PrioritySelectionFiltering, ShowPowerDelta, ShowHarvesterCounter, ShowPlacementPreview;
    public double ClientVolume = 0.3, SoundVolume = 1, VoiceVolume = 1, ScoreVolume = 1;

    public static ClientSettings Load(string path)
    {
        var s = new ClientSettings();
        var ini = IniFile.Load(path);
        s.ResolutionX = Num(ini.Get("Video", "ClientResolutionX"), s.ResolutionX);
        s.ResolutionY = Num(ini.Get("Video", "ClientResolutionY"), s.ResolutionY);
        s.DetailLevel = Num(ini.Get("Options", "DetailLevel"), s.DetailLevel);
        s.GameSpeed = Num(ini.Get("Options", "GameSpeed"), s.GameSpeed);
        s.Difficulty = Num(ini.Get("Options", "Difficulty"), s.Difficulty);
        s.Renderer = ini.Get("Compatibility", "Renderer") ?? s.Renderer;
        s.Language = L10n.Normalize(ini.Get("Options", "Translation") ?? s.Language);
        s.BorderlessClient = Flag(ini.Get("Video", "BorderlessWindowedClient"), s.BorderlessClient);
        s.WindowedMode = Flag(ini.Get("Video", "Video.Windowed"), s.WindowedMode);
        s.IntegerScaling = Flag(ini.Get("Video", "IntegerScaledClient"), s.IntegerScaling);
        s.ToolTips = Flag(ini.Get("Options", "ToolTips"), s.ToolTips);
        s.ClientVolume = Real(ini.Get("Audio", "ClientVolume"), s.ClientVolume);
        s.SoundVolume = Real(ini.Get("Audio", "SoundVolume"), s.SoundVolume);
        s.VoiceVolume = Real(ini.Get("Audio", "VoiceVolume"), s.VoiceVolume);
        s.ScoreVolume = Real(ini.Get("Audio", "ScoreVolume"), s.ScoreVolume);
        s.GameResX = Num(ini.Get("Video", "ScreenWidth"), s.GameResX);
        s.GameResY = Num(ini.Get("Video", "ScreenHeight"), s.GameResY);
        s.BorderlessFrame = Flag(ini.Get("Video", "NoWindowFrame"), s.BorderlessFrame);
        s.BackBuffer = Flag(ini.Get("Video", "VideoBackBuffer"), s.BackBuffer);
        s.QuickExit = Flag(ini.Get("Options", "QuickExit"), s.QuickExit);
        s.AllowChat = Flag(ini.Get("Options", "AllowChat"), s.AllowChat);
        s.AllowTaunts = Flag(ini.Get("Options", "AllowTaunts"), s.AllowTaunts);
        s.SkipScoreScreen = Flag(ini.Get("Options", "SkipScoreScreen"), s.SkipScoreScreen);
        s.RecordReplays = Flag(ini.Get("Replays", "RecordReplays"), s.RecordReplays);
        s.PrioritySelectionFiltering = Flag(ini.Get("Phobos", "PrioritySelectionFiltering"), s.PrioritySelectionFiltering);
        s.ShowPowerDelta = Flag(ini.Get("Phobos", "ShowPowerDelta"), s.ShowPowerDelta);
        s.ShowHarvesterCounter = Flag(ini.Get("Phobos", "ShowHarvesterCounter"), s.ShowHarvesterCounter);
        s.ShowPlacementPreview = Flag(ini.Get("Phobos", "ShowPlacementPreview"), s.ShowPlacementPreview);
        return s;
    }

    public void Save(string path)
    {
        var ini = IniFile.Load(path);
        ini.Set("Video", "ClientResolutionX", ResolutionX.ToString());
        ini.Set("Video", "ClientResolutionY", ResolutionY.ToString());
        ini.Set("Video", "BorderlessWindowedClient", BorderlessClient ? "True" : "False");
        ini.Set("Video", "Video.Windowed", WindowedMode ? "True" : "False");
        ini.Set("Video", "IntegerScaledClient", IntegerScaling ? "True" : "False");
        ini.Set("Compatibility", "Renderer", Renderer);
        ini.Set("Options", "DetailLevel", DetailLevel.ToString());
        ini.Set("Options", "GameSpeed", GameSpeed.ToString());
        ini.Set("Options", "Difficulty", Difficulty.ToString());
        ini.Set("Options", "ToolTips", ToolTips ? "True" : "False");
        ini.Set("Options", "Translation", Language);
        ini.Set("Audio", "ClientVolume", ClientVolume.ToString("0.###", CultureInfo.InvariantCulture));
        ini.Set("Audio", "SoundVolume", SoundVolume.ToString("0.###", CultureInfo.InvariantCulture));
        ini.Set("Audio", "VoiceVolume", VoiceVolume.ToString("0.###", CultureInfo.InvariantCulture));
        ini.Set("Audio", "ScoreVolume", ScoreVolume.ToString("0.###", CultureInfo.InvariantCulture));
        ini.Set("Video", "ScreenWidth", GameResX.ToString());
        ini.Set("Video", "ScreenHeight", GameResY.ToString());
        ini.Set("Video", "NoWindowFrame", BorderlessFrame ? "True" : "False");
        ini.Set("Video", "VideoBackBuffer", BackBuffer ? "True" : "False");
        ini.Set("Options", "QuickExit", QuickExit ? "True" : "False");
        ini.Set("Options", "AllowChat", AllowChat ? "True" : "False");
        ini.Set("Options", "AllowTaunts", AllowTaunts ? "True" : "False");
        ini.Set("Options", "SkipScoreScreen", SkipScoreScreen ? "True" : "False");
        ini.Set("Replays", "RecordReplays", RecordReplays ? "True" : "False");
        ini.Set("Phobos", "PrioritySelectionFiltering", PrioritySelectionFiltering ? "True" : "False");
        ini.Set("Phobos", "ShowPowerDelta", ShowPowerDelta ? "True" : "False");
        ini.Set("Phobos", "ShowHarvesterCounter", ShowHarvesterCounter ? "True" : "False");
        ini.Set("Phobos", "ShowPlacementPreview", ShowPlacementPreview ? "True" : "False");
        ini.Save(path);
    }

    private static int Num(string? v, int fallback) =>
        int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : fallback;

    private static double Real(string? v, double fallback) =>
        double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : fallback;

    private static bool Flag(string? v, bool fallback) => v == null
        ? fallback
        : v.Equals("true", StringComparison.OrdinalIgnoreCase) || v.Equals("yes", StringComparison.OrdinalIgnoreCase) || v == "1";
}

/// <summary>One player slot of the skirmish setup (CnCNet client layout).</summary>
public sealed class SkirmishPlayer
{
    public string Name { get; set; } = "";
    /// <summary>Index into the faction list (Resources\GameOptions.ini [General] Sides), or -1 for "Random".</summary>
    public int Side { get; set; } = -1;
    /// <summary>Index into the colour list (Resources\GameOptions.ini [MPColors]).</summary>
    public int Color { get; set; }
    /// <summary>Team / alliance slot, 0-7.</summary>
    public int Team { get; set; }
    /// <summary>Starting position, 1-8; 0 means "assigned by the game".</summary>
    public int Start { get; set; }
    /// <summary>Human-controlled slot (the first one) vs. AI slot.</summary>
    public bool IsHuman { get; set; }
}

/// <summary>Skirmish game options. Defaults follow the CnCNet client.</summary>
public sealed class SkirmishOptions
{
    public int Credits { get; set; } = 10000;      // cmbCredits default index 5
    public int GameSpeed { get; set; } = 6;         // cmbGameSpeedCap default index 0
    public int UnitCount { get; set; } = 0;         // cmbStartingUnits default index 10
    public bool ShortGame { get; set; } = true;     // chkShortGame
    public bool BridgeDestroy { get; set; } = true; // chkDestrBridges
    public bool BuildOffAlly { get; set; } = true;  // chkBuildOffAlly
    public bool MultiEngineer { get; set; }         // chkMultiEng (unchecked)
    public bool MCVRedeploy { get; set; } = true;   // chkRedeplMCV
    public bool AlliesAllowed { get; set; } = true; // chkIngameAllying
    public bool Crates { get; set; }                // chkCrates (unchecked)
    public bool AutoRepair { get; set; }            // chkAutoRepair (unchecked)
    public int SuperWeapons { get; set; }           // cmbSuperWeaponsModifier index 0 = All
    public int AiModifier { get; set; }             // cmbAIModifier index 0 = No change
}

/// <summary>Everything the skirmish screen remembers between launches.</summary>
public sealed class SkirmishConfig
{
    public string SelectedMap { get; set; } = "";
    /// <summary>Selected game mode in the skirmish map list (e.g. "Battle", or special All/Other keys).</summary>
    public string SelectedMode { get; set; } = "Battle";
    public int ActiveTab { get; set; }
    public bool ShowDevMods { get; set; }
    public SkirmishOptions Options { get; set; } = new();
    public List<SkirmishPlayer> Players { get; set; } = new();
    /// <summary>Saved mod presets: name -> mod ids.</summary>
    public Dictionary<string, List<string>> Presets { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class LauncherConfig
{
    public string CncNet { get; set; } = "CnCNetYRLauncher.exe";
    public string Syringe { get; set; } = "Syringe.exe";
    public List<string> SyringeArgs { get; set; } = new() { "-i=Ares.dll", "-i=Phobos.dll", "-i=LuaAPI.dll", "gamemd.exe" };
    public string Gamemd { get; set; } = "gamemd.exe";
    public List<string> GamemdArgs { get; set; } = new() { "-CD" };
    public HashSet<string> ActiveMods { get; set; } = new();

    /// <summary>Launcher UI language: "en" (default) or "ru".</summary>
    public string Language { get; set; } = L10n.English;

    /// <summary>Play interface sounds (hover/click/notice). Enabled by default.</summary>
    public bool UiSoundsEnabled { get; set; } = true;

    /// <summary>State of the skirmish screen: map, options, players, presets.</summary>
    public SkirmishConfig Skirmish { get; set; } = new();

    public LauncherConfig Normalize() => new()
    {
        CncNet = string.IsNullOrWhiteSpace(CncNet) ? "CnCNetYRLauncher.exe" : CncNet,
        Syringe = string.IsNullOrWhiteSpace(Syringe) ? "Syringe.exe" : Syringe,
        SyringeArgs = SyringeArgs is { Count: > 0 } ? SyringeArgs : new() { "-i=Ares.dll", "-i=Phobos.dll", "-i=LuaAPI.dll", "gamemd.exe" },
        Gamemd = string.IsNullOrWhiteSpace(Gamemd) ? "gamemd.exe" : Gamemd,
        GamemdArgs = GamemdArgs is { Count: > 0 } ? GamemdArgs : new() { "-CD" },
        ActiveMods = ActiveMods ?? new(),
        Language = L10n.Normalize(Language),
        UiSoundsEnabled = UiSoundsEnabled,
        Skirmish = Skirmish ?? new SkirmishConfig()
    };
}

public static class LauncherCore
{
    /// <summary>The skirmish table never drops below two slots and never grows past the colour list.</summary>
    public const int MinSkirmishSlots = 2;
    public const int MaxSkirmishSlots = 8;

    public static string Root => AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    public static string ModsDir => Path.Combine(Root, "mods");
    public static string ActiveFile => Path.Combine(ModsDir, "active_mods.txt");
    public static string CfgFile => Path.Combine(Root, "launcher_config.json");

    private static readonly JsonSerializerOptions JRead = new() { PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
    private static readonly JsonSerializerOptions JWrite = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static LauncherConfig LoadConfig(IEnumerable<ModInfo>? mods = null)
    {
        var cfg = new LauncherConfig();
        if (File.Exists(CfgFile))
        {
            try
            {
                cfg = JsonSerializer.Deserialize<LauncherConfig>(File.ReadAllText(CfgFile), JRead)?.Normalize() ?? cfg;
            }
            catch (Exception ex)
            {
                LauncherLog.Error("Failed to load launcher_config.json, using defaults", ex);
                cfg = new LauncherConfig();
            }
        }
        // active_mods.txt is the runtime source of truth for LuaAPI; mirror into config
        try { cfg.ActiveMods = ReadActiveIds(mods); }
        catch (Exception ex) { LauncherLog.Error("Failed to read active_mods.txt", ex); cfg.ActiveMods = new HashSet<string>(StringComparer.Ordinal); }
        return cfg;
    }

    public static void SaveConfig(LauncherConfig cfg)
    {
        File.WriteAllText(CfgFile, JsonSerializer.Serialize(cfg.Normalize(), JWrite));
    }

    public static string Ra2MdIniPath => Path.Combine(Root, "RA2MD.INI");

    /// <summary>Loads RA2MD.INI; on read errors logs and returns defaults so the UI can still open.</summary>
    public static ClientSettings LoadClientSettingsSafe(string? path = null)
    {
        path ??= Ra2MdIniPath;
        try
        {
            return ClientSettings.Load(path);
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Failed to load RA2MD.INI: " + path, ex);
            return new ClientSettings();
        }
    }

    /// <summary>
    /// Scans mods\&lt;folder&gt; and collects the .lua / .json files each mod ships
    /// (recursively, so helper modules in sub-folders are listed too).
    /// </summary>
    public static List<ModInfo> ScanMods()
    {
        var mods = new List<ModInfo>();
        if (!Directory.Exists(ModsDir)) return mods;

        foreach (var dir in Directory.GetDirectories(ModsDir).OrderBy(d => Path.GetFileName(d), StringComparer.OrdinalIgnoreCase))
        {
            var folder = Path.GetFileName(dir);
            var info = new ModInfo { Id = folder, Name = folder, Folder = folder };

            var mj = Path.Combine(dir, "mod.json");
            if (File.Exists(mj))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(mj), new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
                    var r = doc.RootElement;
                    info.Id = Str(r, "id") ?? info.Id;
                    info.Name = Str(r, "name") ?? info.Name;
                    info.Version = Str(r, "version") ?? "";
                    info.Author = Str(r, "author") ?? "";
                    info.Description = Str(r, "description") ?? "";
                    info.NameEn = Str(r, "name_en") ?? "";
                    info.DescriptionEn = Str(r, "description_en") ?? "";
                    info.Conflicts = StrList(r, "conflicts");
                    info.Dependencies = StrList(r, "dependencies");
                    info.Tag = Str(r, "tag") ?? "";
                    info.Rules = Str(r, "rules") ?? "";
                    // "dev": true - a development-only mod, hidden by default.
                    info.IsDev = r.TryGetProperty("dev", out var dev) && dev.ValueKind == JsonValueKind.True;
                    // "load": { "active": false } - the mod asks to stay off by default.
                    info.DefaultActive = !r.TryGetProperty("load", out var load) ||
                                         !load.TryGetProperty("active", out var active) ||
                                         active.ValueKind != JsonValueKind.False;
                    var warns = new List<string>();
                    if (info.Conflicts.Count > 0) warns.Add(L10n.T("Конфликты: ") + string.Join(", ", info.Conflicts));
                    if (info.Dependencies.Count > 0) warns.Add(L10n.T("Зависимости: ") + string.Join(", ", info.Dependencies));
                    info.RawWarnings = string.Join("\n", warns);
                }
                catch { info.Description = L10n.T("(ошибка чтения mod.json)"); }
            }

            try
            {
                foreach (var file in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                {
                    info.TotalFileCount++;
                    var ext = Path.GetExtension(file).ToLowerInvariant();
                    if (ext != ".lua" && ext != ".json") continue;
                    var entry = new ModFile
                    {
                        RelPath = Path.GetRelativePath(dir, file).Replace('\\', '/'),
                        Size = new FileInfo(file).Length
                    };
                    if (ext == ".lua") info.LuaFiles.Add(entry); else info.JsonFiles.Add(entry);
                }
            }
            catch { }

            info.LuaFiles = info.LuaFiles.OrderBy(f => f.RelPath, StringComparer.OrdinalIgnoreCase).ToList();
            info.JsonFiles = info.JsonFiles.OrderBy(f => f.RelPath, StringComparer.OrdinalIgnoreCase).ToList();
            // The LuaAPI loader executes mods/<folder>/main.lua (see mods/init.lua).
            info.IsLuaApi = File.Exists(Path.Combine(dir, "main.lua"));
            // Known development mods stay hidden unless the user asks for them.
            if (!info.IsDev && DevModIds.Contains(info.Id, StringComparer.OrdinalIgnoreCase)) info.IsDev = true;
            mods.Add(info);
        }

        return mods.OrderBy(m => m.Name, StringComparer.OrdinalIgnoreCase).ThenBy(m => m.Id, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string? Str(JsonElement r, string name) =>
        r.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;

    private static List<string> StrList(JsonElement r, string name)
    {
        var list = new List<string>();
        if (!r.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.Array) return list;
        foreach (var it in p.EnumerateArray())
            if (it.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(it.GetString()))
                list.Add(it.GetString()!);
        return list;
    }

    /// <summary>
    /// Writes the game speed the engine reads from RA2MD.INI. The rest of the
    /// skirmish options travel through spawn.ini and are applied by the spawner.
    /// </summary>
    public static void ApplySkirmishGameSpeed(SkirmishOptions? options)
    {
        if (options == null) return;
        try
        {
            var path = Path.Combine(Root, "RA2MD.INI");
            var ini = IniFile.Load(path);
            ini.Set("Options", "GameSpeed", Math.Clamp(options.GameSpeed, 1, 6).ToString());
            ini.Save(path);
        }
        catch { }
    }

    /// <summary>
    /// Factions for the skirmish player table, taken from the client's own
    /// definition (Resources\GameOptions.ini [General] Sides).
    /// </summary>
    public static List<string> SkirmishFactions()
    {
        var ini = IniFile.Load(Path.Combine(Root, "Resources", "GameOptions.ini"));
        var sides = ini.Get("General", "Sides") ?? "";
        var list = sides.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
        if (list.Count == 0) list.AddRange(new[] { "America", "Russia" });
        return list;
    }

    /// <summary>Player colours: name and "r,g,b" for the swatch.</summary>
    public static List<(string Name, string Rgb)> SkirmishColors()
    {
        var ini = IniFile.Load(Path.Combine(Root, "Resources", "GameOptions.ini"));
        var list = new List<(string, string)>();
        foreach (var (key, value) in ini.Section("MPColors"))
        {
            var parts = value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (parts.Length < 3) continue;
            list.Add((key, $"{parts[0]},{parts[1]},{parts[2]}"));
        }
        if (list.Count == 0) list.Add(("Yellow", "222,227,8"));
        return list;
    }

    /// <summary>
    /// A skirmish always needs at least one human slot and one AI slot, so the
    /// table is never empty when the screen opens.
    /// </summary>
    public static void EnsureSkirmishDefaults(SkirmishConfig? cfg)
    {
        if (cfg == null) return;
        cfg.Options ??= new SkirmishOptions();
        cfg.Players ??= new List<SkirmishPlayer>();
        cfg.Presets ??= new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        if (cfg.Players.Count > MaxSkirmishSlots)
            cfg.Players.RemoveRange(MaxSkirmishSlots, cfg.Players.Count - MaxSkirmishSlots);

        while (cfg.Players.Count < MinSkirmishSlots)
            cfg.Players.Add(NewPlayer(cfg.Players.Count == 0));

        // The first slot is the local player; keep that invariant after a delete.
        if (cfg.Players.Count > 0 && !cfg.Players.Exists(p => p.IsHuman))
            cfg.Players[0].IsHuman = true;
    }

    public static SkirmishPlayer NewPlayer(bool isHuman) => new()
    {
        Name = isHuman ? L10n.T("ИГРОК") : L10n.F("ИИ {0}", 1),
        Side = -1,
        Color = 0,
        Team = 0,
        Start = 0,
        IsHuman = isHuman
    };

    /// <summary>Maps shipped in the game root (*.mmx / *.yro) plus the Maps tree.</summary>
    public static List<MapEntry> ScanMaps(int limit = 400)
    {
        var found = new List<MapEntry>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Add(string path)
        {
            if (found.Count >= limit) return;
            var full = Path.GetFullPath(path);
            if (!seen.Add(full)) return;
            var ext = Path.GetExtension(path).ToLowerInvariant();
            found.Add(new MapEntry
            {
                Name = Path.GetFileNameWithoutExtension(path),
                FilePath = full,
                Relative = Path.GetRelativePath(Root, full).Replace('\\', '/'),
                Extension = ext
            });
        }

        if (Directory.Exists(Root))
        {
            try
            {
                foreach (var f in Directory.GetFiles(Root, "*.*", SearchOption.TopDirectoryOnly))
                {
                    var ext = Path.GetExtension(f).ToLowerInvariant();
                    if (ext is ".mmx" or ".yro") Add(f);
                }
            }
            catch { }
        }

        var mapsDir = Path.Combine(Root, "Maps");
        if (Directory.Exists(mapsDir))
        {
            try
            {
                foreach (var f in Directory.EnumerateFiles(mapsDir, "*.*", SearchOption.AllDirectories))
                {
                    if (found.Count >= limit) break;
                    var ext = Path.GetExtension(f).ToLowerInvariant();
                    if (ext is ".mmx" or ".yro" or ".map" or ".yrm") Add(f);
                }
            }
            catch { }
        }

        return found.OrderBy(m => m.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>Map editor launcher (Map Editor\*, Tools\Map Editor\FA2SP|WAE).</summary>
    public static string? FindMapEditor()
    {
        var explicitPath = Path.Combine(Root, "Map Editor", "Map Editor.bat");
        if (File.Exists(explicitPath)) return explicitPath;

        var toolDir = Path.Combine(Root, "Tools", "Map Editor");
        if (!Directory.Exists(toolDir)) return null;

        var candidates = new List<string>();
        try
        {
            candidates.AddRange(Directory.EnumerateFiles(toolDir, "*.*", SearchOption.AllDirectories)
                .Where(f => Path.GetExtension(f).ToLowerInvariant() is ".exe" or ".bat"));
        }
        catch { return null; }

        string[] preferred = { "fa2sp", "fa2", "finalsun", "wae", "mapeditor" };
        foreach (var token in preferred)
        {
            var hit = candidates.FirstOrDefault(c =>
                Path.GetFileNameWithoutExtension(c).ToLowerInvariant().Contains(token, StringComparison.Ordinal));
            if (hit != null) return hit;
        }

        return candidates.OrderBy(c => c, StringComparer.OrdinalIgnoreCase).FirstOrDefault();
    }

    // Matching Launch_LuaAPI.bat: mod.json "conflicts" is documentation only, so the
    // two AI mods that compete for the same units are checked explicitly here too.
    public const string SectorModId = "Sector";
    public const string SmartAiModId = "Smart AI";

    /// <summary>Mods that are only interesting while developing.</summary>
    public static readonly string[] DevModIds = { "AI Queue Probe", "AI Telemetry", "lua_probe" };

    public static bool HasAiModConflict(IEnumerable<string> activeIds)
    {
        var sector = false;
        var smartAi = false;
        foreach (var id in activeIds)
        {
            if (string.Equals(id, SectorModId, StringComparison.OrdinalIgnoreCase)) sector = true;
            else if (string.Equals(id, SmartAiModId, StringComparison.OrdinalIgnoreCase)) smartAi = true;
            if (sector && smartAi) return true;
        }
        return false;
    }

    /// <summary>Pairs of enabled mods that declare a conflict with each other.</summary>
    public static List<(ModInfo A, ModInfo B)> FindModConflicts(IEnumerable<ModInfo> enabled)
    {
        var list = new List<(ModInfo, ModInfo)>();
        var mods = enabled.ToList();
        for (var i = 0; i < mods.Count; i++)
        for (var j = i + 1; j < mods.Count; j++)
        {
            var a = mods[i];
            var b = mods[j];
            var hit = a.Conflicts.Any(c => Mentions(c, b.Id) || Mentions(c, b.Name))
                   || b.Conflicts.Any(c => Mentions(c, a.Id) || Mentions(c, a.Name));
            if (hit) list.Add((a, b));
        }
        return list;
    }

    private static bool Mentions(string text, string token)
    {
        if (string.IsNullOrWhiteSpace(text) || string.IsNullOrWhiteSpace(token)) return false;
        var idx = text.IndexOf(token, StringComparison.OrdinalIgnoreCase);
        while (idx >= 0)
        {
            var before = idx == 0 ? ' ' : text[idx - 1];
            var after = idx + token.Length >= text.Length ? ' ' : text[idx + token.Length];
            if (!char.IsLetterOrDigit(before) && !char.IsLetterOrDigit(after)) return true;
            idx = text.IndexOf(token, idx + 1, StringComparison.OrdinalIgnoreCase);
        }
        return false;
    }

    public static HashSet<string> ReadActiveIds(IEnumerable<ModInfo>? mods = null)
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        if (!File.Exists(ActiveFile))
        {
            // First run: fall back to the defaults the mods declare themselves.
            if (mods != null) foreach (var id in DefaultActiveIds(mods)) set.Add(id);
            return set;
        }
        foreach (var raw in File.ReadAllLines(ActiveFile))
        {
            var s = raw.Trim();
            if (s.Length == 0 || s.StartsWith('#')) continue;
            set.Add(s);
        }
        return set;
    }

    /// <summary>
    /// The mod this launcher ships with. It is always part of the default set,
    /// so a fresh install runs the mod without any manual step.
    /// </summary>
    public const string FlagshipModId = "Yuris-Echo";

    /// <summary>
    /// The mods that are enabled on a fresh install: every mod that declares
    /// itself active (mod.json "load.active"), plus the mod this launcher
    /// ships with.
    /// </summary>
    public static IEnumerable<string> DefaultActiveIds(IEnumerable<ModInfo> mods) =>
        mods.Where(m => m.DefaultActive || m.Id == FlagshipModId).Select(m => m.Id);

    public static void SaveActiveIds(IEnumerable<ModInfo> mods, HashSet<string> selected, LauncherConfig? cfg = null)
    {
        Directory.CreateDirectory(ModsDir);
        var header = new List<string> { "# Active mods - one mod ID per line (read by the LuaAPI loader)" };
        if (File.Exists(ActiveFile))
        {
            foreach (var raw in File.ReadAllLines(ActiveFile))
            {
                var s = raw.Trim();
                if (s.StartsWith('#')) { if (!header.Contains(raw.TrimEnd())) header.Add(raw.TrimEnd()); }
                else if (s.Length > 0) break;
            }
        }
        var lines = new List<string>(header) { "" };
        foreach (var m in mods) if (selected.Contains(m.Id)) lines.Add(m.Id);
        foreach (var id in selected.OrderBy(x => x, StringComparer.Ordinal))
            if (!mods.Any(m => string.Equals(m.Id, id, StringComparison.Ordinal))) lines.Add(id);

        File.WriteAllLines(ActiveFile, lines, new UTF8Encoding(false));
        if (cfg != null) { cfg.ActiveMods = new HashSet<string>(selected, StringComparer.Ordinal); SaveConfig(cfg); }
    }

    public static (bool ok, string? missing) CheckExe(string exe)
    {
        if (string.IsNullOrWhiteSpace(exe)) return (false, L10n.T("путь не задан"));
        var path = Path.IsPathRooted(exe) ? exe : Path.Combine(Root, exe);
        return File.Exists(path) ? (true, null) : (false, Path.GetFileName(exe) + L10n.T(" не найден"));
    }

    public static bool Exists(string relative) => File.Exists(Path.Combine(Root, relative));

    public static void Launch(string exe, List<string>? args = null)
    {
        var path = Path.IsPathRooted(exe) ? exe : Path.Combine(Root, exe);
        if (!File.Exists(path)) throw new FileNotFoundException(L10n.T("Не найден: ") + path);
        var psi = new ProcessStartInfo(path) { WorkingDirectory = Root, UseShellExecute = false };
        if (args != null) foreach (var a in args) if (!string.IsNullOrWhiteSpace(a)) psi.ArgumentList.Add(a);
        Process.Start(psi);
    }

    /// <summary>
    /// LuaAPI launch plan (evidence: Launch_LuaAPI.bat):
    /// Syringe.exe -i=Ares.dll -i=Phobos.dll -i=LuaAPI.dll gamemd.exe
    /// Falls back to gamemd.exe directly when Syringe is absent.
    /// Returns the UTC start time, used to find the gamemd process for LuaAPI injection.
    /// </summary>
    public static DateTime LaunchGame(LauncherConfig cfg)
    {
        ApplyGameWindowMode(cfg, ClientSettings.Load(Path.Combine(Root, "RA2MD.INI")));
        var (sOk, _) = CheckExe(cfg.Syringe);
        if (sOk)
        {
            // The game executable is the last Syringe argument; the game
            // arguments travel in one "--args=..." group after it, the way the
            // CnCNet client passes them. Syringe only forwards the whole group
            // when it is a single argument.
            var args = new List<string>(cfg.SyringeArgs.Where(a => !string.IsNullOrWhiteSpace(a)));
            var gameArgs = cfg.GamemdArgs.Where(a => !string.IsNullOrWhiteSpace(a)).ToList();
            if (gameArgs.Count > 0) args.Add("--args=" + string.Join(' ', gameArgs));
            Launch(cfg.Syringe, args);
        }
        else Launch(cfg.Gamemd, cfg.GamemdArgs);
        return DateTime.UtcNow;
    }

    /// <summary>
    /// Launches a single campaign mission the same way the CnCNet client does:
    /// Syringe starts the game executable and CnCNet-Spawner.dll reads the
    /// mission from spawn.ini (see Resources\ClientDefinitions.ini for the
    /// command line the client uses).
    /// </summary>
    public static DateTime LaunchCampaignMission(LauncherConfig cfg)
    {
        var gameExe = Exists("gamemd-spawn.exe") ? "gamemd-spawn.exe" : cfg.Gamemd;
        ApplyGameWindowMode(cfg, ClientSettings.Load(Path.Combine(Root, "RA2MD.INI")));

        var def = ReadClientDefinition();
        var launcherExe = Exists(def.LauncherExe) ? def.LauncherExe : cfg.Syringe;

        var (sOk, _) = CheckExe(launcherExe);
        if (!sOk)
        {
            // Without Syringe we cannot inject the spawner/LuaAPI hooks reliably.
            Launch(gameExe, new List<string> { "-SPAWN", "-CD" });
            return DateTime.UtcNow;
        }

        var args = BuildSpawnSyringeArgs(gameExe, def);
        Launch(launcherExe, args);
        return DateTime.UtcNow;
    }

    /// <summary>
    /// The CnCNet client's own launch definition (Resources\ClientDefinitions.ini).
    /// GameExecutableNames is the launcher executable (Syringe.exe) and
    /// ExtraCommandLineParams is everything after it, including the quoted
    /// "--args=..." group that carries the game arguments.
    /// </summary>
    public static ClientLaunchDefinition ReadClientDefinition()
    {
        var def = new ClientLaunchDefinition();
        var ini = IniFile.Load(Path.Combine(Root, "Resources", "ClientDefinitions.ini"));

        var names = ini.Get("Settings", "GameExecutableNames");
        if (!string.IsNullOrWhiteSpace(names))
        {
            var first = names.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                             .FirstOrDefault();
            if (!string.IsNullOrWhiteSpace(first)) def.LauncherExe = first;
        }

        var extra = ini.Get("Settings", "ExtraCommandLineParams");
        if (!string.IsNullOrWhiteSpace(extra))
        {
            def.ExtraParams = SplitCommandLine(extra);
            def.Found = def.ExtraParams.Count > 0;
        }

        return def;
    }

    /// <summary>
    /// Splits a command line into arguments. Quoted groups stay together, so
    /// "--args=-SPAWN -LOG -CD" comes out as one argument. Syringe only forwards
    /// the whole "--args=..." value when it is a single argument - otherwise it
    /// cuts the value at the first space and the game misses most flags.
    /// </summary>
    public static List<string> SplitCommandLine(string line)
    {
        var result = new List<string>();
        if (string.IsNullOrWhiteSpace(line)) return result;

        var cur = new StringBuilder();
        var quoted = false;
        foreach (var ch in line)
        {
            if (ch == '"') { quoted = !quoted; continue; }
            if (!quoted && char.IsWhiteSpace(ch))
            {
                if (cur.Length > 0) { result.Add(cur.ToString()); cur.Clear(); }
                continue;
            }
            cur.Append(ch);
        }
        if (cur.Length > 0) result.Add(cur.ToString());
        return result;
    }

    /// <summary>
    /// Builds the argv for the mission launch, following the CnCNet client:
    /// the injected DLLs, the game executable and one "--args=..." group.
    /// </summary>
    private static List<string> BuildSpawnSyringeArgs(string gameExe, ClientLaunchDefinition def)
    {
        var dlls = new List<string>();
        string? argsValue = null;

        foreach (var p in def.ExtraParams)
        {
            if (p.StartsWith("-i=", StringComparison.OrdinalIgnoreCase))
            {
                var dll = p[3..];
                if (!Exists(dll)) continue; // a DLL this installation does not have
                if (!dlls.Contains(p, StringComparer.OrdinalIgnoreCase)) dlls.Add(p);
            }
            else if (p.StartsWith("--args=", StringComparison.OrdinalIgnoreCase))
            {
                argsValue = p["--args=".Length..];
            }
        }

        // The mission spawner is what turns spawn.ini into a running mission.
        if (Exists("CnCNet-Spawner.dll") &&
            !dlls.Any(d => d.EndsWith("CnCNet-Spawner.dll", StringComparison.OrdinalIgnoreCase)))
            dlls.Add("-i=CnCNet-Spawner.dll");

        var gameArgs = argsValue != null ? SplitCommandLine(argsValue) : new List<string>();
        if (!gameArgs.Any(a => a.Equals("-SPAWN", StringComparison.OrdinalIgnoreCase)))
            gameArgs.Insert(0, "-SPAWN");
        if (!gameArgs.Any(a => a.Equals("-LOG", StringComparison.OrdinalIgnoreCase)))
            gameArgs.Add("-LOG");

        // One single "--args=..." argument: Syringe keeps it whole and passes it
        // to the game process.
        var args = new List<string>(dlls) { gameExe };
        args.Add("--args=" + string.Join(' ', gameArgs));
        return args;
    }

    /// <summary>
    /// Tail of Syringe's log. Shown in the launcher when a mission launch fails,
    /// otherwise a crashed game is indistinguishable from "nothing happened".
    /// </summary>
    public static string ReadSyringeLogTail(int lines = 10)
    {
        var path = Path.Combine(Root, "syringe.log");
        try
        {
            if (!File.Exists(path)) return "";
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            var all = new List<string>();
            while (!sr.EndOfStream)
            {
                var line = sr.ReadLine();
                if (line != null) all.Add(line);
            }
            return string.Join(Environment.NewLine, all.TakeLast(lines));
        }
        catch { return ""; }
    }

    private enum GameWindowMode { Fullscreen, Windowed, Borderless }

    private static GameWindowMode DetectGameWindowMode(ClientSettings s)
    {
        if (s.BorderlessClient) return GameWindowMode.Fullscreen;
        if (s.WindowedMode && s.BorderlessFrame) return GameWindowMode.Borderless;
        if (s.WindowedMode) return GameWindowMode.Windowed;
        return GameWindowMode.Fullscreen;
    }

    /// <summary>
    /// The selected renderer owns windowed/fullscreen, so the CnCNet client ships
    /// it as a DLL plus config and the game reads no window keys of its own. The
    /// client only does that when its own options are saved, which a direct
    /// launcher launch never triggers: that is why "Fullscreen client" still
    /// started a window. Deploy the selected renderer the same way and write the
    /// game section's window keys before launching.
    /// </summary>
    public static void ApplyGameWindowMode(LauncherConfig cfg, ClientSettings settings)
    {
        try
        {
            var renderers = IniFile.Load(Path.Combine(Root, "Resources", "Renderers.ini"));
            var section = settings.Renderer;
            var dll = renderers.Get(section, "DLLName");
            if (string.IsNullOrWhiteSpace(dll)) return;

            var source = Path.Combine(Root, "Resources", dll);
            var target = Path.Combine(Root, "ddraw.dll");
            if (!File.Exists(source)) return;

            if (!SameBytes(source, target))
            {
                if (File.Exists(target))
                {
                    File.SetAttributes(target, FileAttributes.Normal);
                    File.Delete(target);
                }
                File.Copy(source, target);
            }

            var configName = renderers.Get(section, "ConfigFileName");
            if (string.IsNullOrWhiteSpace(configName)) return;
            var config = Path.Combine(Root, configName);
            var template = renderers.Get(section, "ResConfigFileName");
            if (!File.Exists(config) && !string.IsNullOrEmpty(template))
            {
                var from = Path.Combine(Root, "Resources", template);
                if (File.Exists(from)) File.Copy(from, config);
            }
            if (!File.Exists(config)) return;

            var windowedKey = renderers.Get(section, "WindowedModeKey");
            if (string.IsNullOrWhiteSpace(windowedKey)) return;

            var borderKey = renderers.Get(section, "BorderlessWindowedModeKey");
            var borderReversed = IsTrue(renderers.Get(section, "IsBorderlessWindowedModeKeyReversed"));
            var mode = DetectGameWindowMode(settings);
            var gameSection = Path.GetFileNameWithoutExtension(cfg.Gamemd);

            var ini = IniFile.Load(config);
            var hasFullscreenKey = ini.Get("ddraw", "fullscreen") != null || ini.Get(gameSection, "fullscreen") != null;

            void ApplySection(string name)
            {
                // Native fullscreen is windowed=false + fullscreen=false: the game changes
                // the display mode itself (YR menus are hardcoded to 800x600 and the
                // renderer cannot scale them, so a desktop-sized window leaves them in a
                // corner). Borderless is the windowed-fullscreen pair instead.
                ini.Set(name, windowedKey, mode == GameWindowMode.Fullscreen ? "false" : "true");
                if (hasFullscreenKey)
                    ini.Set(name, "fullscreen", mode == GameWindowMode.Borderless ? "true" : "false");
                if (!string.IsNullOrWhiteSpace(borderKey))
                {
                    var borderless = mode == GameWindowMode.Borderless;
                    ini.Set(name, borderKey, borderless == borderReversed ? "false" : "true");
                }
            }

            ApplySection(gameSection);

            // The mission runs in gamemd-spawn.exe, and the renderer picks its
            // settings from the section named after the executable. Without this
            // the spawn process would fall back to the wrapper defaults and open
            // a window even when fullscreen was requested.
            var spawnSection = Path.GetFileNameWithoutExtension("gamemd-spawn.exe");
            if (!string.IsNullOrWhiteSpace(spawnSection) &&
                !spawnSection.Equals(gameSection, StringComparison.OrdinalIgnoreCase))
                ApplySection(spawnSection);

            ini.Save(config);
        }
        catch
        {
            // A locked or missing renderer must never block the launch itself.
        }
    }

    private static bool IsTrue(string? value) =>
        value != null && (value.Equals("true", StringComparison.OrdinalIgnoreCase) || value == "1" || value.Equals("yes", StringComparison.OrdinalIgnoreCase));

    private static bool SameBytes(string a, string b)
    {
        try
        {
            var left = new FileInfo(a);
            var right = new FileInfo(b);
            if (!right.Exists || left.Length != right.Length) return false;
            return File.ReadAllBytes(a).AsSpan().SequenceEqual(File.ReadAllBytes(b));
        }
        catch { return false; }
    }

    /// <summary>
    /// True when LuaAPI is part of the launch plan. Syringe ignores the DLL (it has
    /// no handshake export), so the launcher loads it into gamemd.exe itself.
    /// </summary>
    public static bool WantsLuaApi(LauncherConfig cfg) =>
        Exists("LuaAPI.dll") &&
        cfg.SyringeArgs.Any(a => a.Trim().Equals("-i=LuaAPI.dll", StringComparison.OrdinalIgnoreCase));

    public static string GameProcessName(LauncherConfig cfg) =>
        Path.GetFileNameWithoutExtension(Exists(cfg.Gamemd) ? cfg.Gamemd : "gamemd.exe");

    public static List<KeyValuePair<string, string>> ScanRenderers()
    {
        var ini = IniFile.Load(Path.Combine(Root, "Resources", "Renderers.ini"));
        var list = new List<KeyValuePair<string, string>>();
        foreach (var (_, id) in ini.Section("Renderers"))
        {
            var ui = ini.Get(id, "UIName");
            if (!string.IsNullOrWhiteSpace(ui)) list.Add(new KeyValuePair<string, string>(id, ui));
        }
        return list;
    }

    /// <summary>
    /// Languages offered by the launcher: only the two the UI is translated
    /// into. The client's own Translations folder still contains others, but the
    /// launcher never exposes them (see the launcher language setting).
    /// </summary>
    public static List<KeyValuePair<string, string>> ScanLanguages() => L10n.Languages();

    public static string BuildStats(LauncherConfig cfg, List<ModInfo> mods, HashSet<string> active, List<MapEntry> maps)
    {
        var sb = new StringBuilder();
        var luaLog = Path.Combine(Root, "LuaAPI.log");

        string YesNo(bool value) => L10n.T(value ? "есть" : "нет");
        string Label(string key) => L10n.T(key).PadRight(10);

        sb.AppendLine(L10n.T("УСТАНОВКА"));
        sb.AppendLine("  " + Label("путь") + Root);
        sb.AppendLine("  gamemd:    " + YesNo(Exists(cfg.Gamemd)));
        sb.AppendLine("  Syringe:   " + YesNo(Exists(cfg.Syringe)));
        sb.AppendLine("  Ares:      " + YesNo(Exists("Ares.dll")));
        sb.AppendLine("  Phobos:    " + YesNo(Exists("Phobos.dll")));
        sb.AppendLine("  LuaAPI:    " + YesNo(Exists("LuaAPI.dll")));
        sb.AppendLine();
        sb.AppendLine(L10n.T("МОДЫ"));
        sb.AppendLine("  " + Label("найдено") + mods.Count);
        sb.AppendLine("  " + Label("активно") + active.Count);
        sb.AppendLine("  " + Label("файлов") + $"lua {mods.Sum(m => m.LuaFiles.Count)}, json {mods.Sum(m => m.JsonFiles.Count)}");
        sb.AppendLine("  " + Label("список") + (mods.Count == 0
            ? L10n.T("Модов нет.")
            : string.Join(", ", mods.Select(m => m.Name + (active.Contains(m.Id) ? "*" : "")))));
        sb.AppendLine();
        sb.AppendLine(L10n.T("КАРТЫ"));
        sb.AppendLine("  " + Label("найдено") + maps.Count);
        sb.AppendLine();
        sb.AppendLine("CNCNET");
        sb.AppendLine("  online:    N/A");
        sb.AppendLine("  " + Label("статус") + L10n.T("разработка мультиплеера ещё не начата"));
        sb.AppendLine();
        sb.AppendLine("LUAAPI.LOG");
        if (File.Exists(luaLog))
        {
            var fi = new FileInfo(luaLog);
            sb.AppendLine("  " + Label("изменён") + fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("  " + Label("размер") + FormatSize(fi.Length));
        }
        else sb.AppendLine("  " + L10n.T("нет файла"));
        return sb.ToString().TrimEnd();
    }

    /// <summary>Preview image shipped next to a map file (custom map packs).</summary>
    public static string? FindMapPreview(MapEntry map)
    {
        var png = Path.ChangeExtension(map.FilePath, ".png");
        if (File.Exists(png)) return png;
        var upper = Path.ChangeExtension(map.FilePath, ".PNG");
        return File.Exists(upper) ? upper : null;
    }

    public static string FormatSize(long bytes)
    {
        if (bytes < 1024) return bytes + " " + L10n.T("Б");
        if (bytes < 1024 * 1024) return (bytes / 1024.0).ToString("0.0") + " " + L10n.T("КБ");
        return (bytes / (1024.0 * 1024.0)).ToString("0.0") + " " + L10n.T("МБ");
    }
}
