using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;

namespace LuaApiLauncher;

/// <summary>
/// Skirmish map catalog built from INI\MPMaps.ini plus maps found on disk.
/// Cached to JSON (keyed by MPMaps.ini timestamp/size). Also provides maxPlayers
/// for the skirmish UI so parsing is not duplicated.
/// </summary>
public sealed class MapCatalog
{
    public const string AllMapsMode = "__all__";
    public const string OtherMapsMode = "__other__";

    public List<string> Modes { get; set; } = new();
    public Dictionary<string, List<MapEntry>> MapsByMode { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public List<MapEntry> AllMaps { get; set; } = new();

    private static readonly JsonSerializerOptions JRead = new() { PropertyNameCaseInsensitive = true };
    private static readonly JsonSerializerOptions JWrite = new() { WriteIndented = false, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private sealed class CacheFile
    {
        public long MpMapsTicks { get; set; }
        public long MpMapsSize { get; set; }
        public List<string> Modes { get; set; } = new();
        public List<MapEntry> Maps { get; set; } = new();
    }

    private static readonly object _loadGate = new();
    private static MapCatalog? _loaded;
    private static long _loadedTicks;
    private static long _loadedSize;

    public static MapCatalog Load()
    {
        var mpMapsPath = Path.Combine(LauncherCore.Root, "INI", "MPMaps.ini");
        var cachePath = Path.Combine(LauncherCore.Root, "map_catalog_cache.json");

        var fi = File.Exists(mpMapsPath) ? new FileInfo(mpMapsPath) : null;
        var ticks = fi?.LastWriteTimeUtc.Ticks ?? 0;
        var size = fi?.Length ?? 0;

        lock (_loadGate)
        {
            if (_loaded != null && _loadedTicks == ticks && _loadedSize == size)
                return _loaded;

            try
            {
                if (File.Exists(cachePath))
                {
                    var cache = JsonSerializer.Deserialize<CacheFile>(File.ReadAllText(cachePath), JRead);
                    if (cache != null && cache.MpMapsTicks == ticks && cache.MpMapsSize == size && cache.Maps.Count > 0)
                    {
                        _loaded = Build(cache.Modes, cache.Maps);
                        _loadedTicks = ticks;
                        _loadedSize = size;
                        return _loaded;
                    }
                }
            }
            catch { }

            var (modes, maps) = Parse(mpMapsPath);
            try
            {
                var cache = new CacheFile { MpMapsTicks = ticks, MpMapsSize = size, Modes = modes, Maps = maps };
                File.WriteAllText(cachePath, JsonSerializer.Serialize(cache, JWrite), new UTF8Encoding(false));
            }
            catch { }

            _loaded = Build(modes, maps);
            _loadedTicks = ticks;
            _loadedSize = size;
            return _loaded;
        }
    }

    private static MapCatalog Build(List<string> modes, List<MapEntry> maps)
    {
        var cat = new MapCatalog { Modes = modes, AllMaps = maps.ToList() };
        cat.MapsByMode[AllMapsMode] = maps.OrderBy(m => m, MapComparer.Instance).ToList();
        cat.MapsByMode[OtherMapsMode] = maps.Where(IsOther).OrderBy(m => m, MapComparer.Instance).ToList();
        foreach (var mode in modes)
        {
            var list = maps.Where(m => m.GameModes.Any(g => g.Equals(mode, StringComparison.OrdinalIgnoreCase)))
                           .OrderBy(m => m, MapComparer.Instance).ToList();
            cat.MapsByMode[mode] = list;
        }
        return cat;
    }

    private static bool IsOther(MapEntry m) =>
        !m.InMpMaps || m.GameModes.Count == 0 || !m.HasMpSection;

    public IReadOnlyList<MapEntry> MapsForMode(string? mode)
    {
        if (string.IsNullOrWhiteSpace(mode)) mode = AllMapsMode;
        if (MapsByMode.TryGetValue(mode, out var list)) return list;
        return MapsByMode.TryGetValue(AllMapsMode, out var all) ? all : Array.Empty<MapEntry>();
    }

    public bool ModeContains(string? mode, string? mapPath)
    {
        if (string.IsNullOrWhiteSpace(mapPath)) return false;
        return MapsForMode(mode).Any(m => string.Equals(m.FilePath, mapPath, StringComparison.OrdinalIgnoreCase));
    }

    public string ResolveMode(string? requestedMode, string? selectedMapPath)
    {
        var mode = string.IsNullOrWhiteSpace(requestedMode) ? "Battle" : requestedMode;
        if (mode == AllMapsMode || mode == OtherMapsMode || Modes.Contains(mode, StringComparer.OrdinalIgnoreCase))
        {
            if (!string.IsNullOrWhiteSpace(selectedMapPath) && !ModeContains(mode, selectedMapPath))
                return AllMapsMode;
            return mode;
        }
        // unknown mode
        return AllMapsMode;
    }

    public static int CompareMaps(MapEntry a, MapEntry b)
    {
        var cmp = a.MaxPlayers.CompareTo(b.MaxPlayers);
        if (cmp != 0) return cmp;
        return string.Compare(NameWithoutPrefix(a.DisplayName), NameWithoutPrefix(b.DisplayName), StringComparison.OrdinalIgnoreCase);
    }

    public static string NameWithoutPrefix(string? name)
    {
        var s = (name ?? "").TrimStart();
        if (s.StartsWith('['))
        {
            var end = s.IndexOf(']');
            if (end > 0) s = s[(end + 1)..].TrimStart();
        }
        return s;
    }

    private sealed class MapComparer : IComparer<MapEntry>
    {
        public static readonly MapComparer Instance = new();
        public int Compare(MapEntry? x, MapEntry? y)
        {
            if (ReferenceEquals(x, y)) return 0;
            if (x is null) return -1;
            if (y is null) return 1;
            return MapCatalog.CompareMaps(x, y);
        }
    }

    // ---------------------------------------------------------------- parsing

    private sealed class MpMapInfo
    {
        public string Key = "";
        public bool HasSection;
        public string Description = "";
        public string Author = "";
        public List<string> GameModes = new();
        public int? MaxPlayers;
        public bool EnforceMaxPlayers;
    }

    private static (List<string> Modes, List<MapEntry> Maps) Parse(string mpMapsPath)
    {
        var modes = new List<string>();
        var multi = new List<string>(); // keys in [MultiMaps] order
        var infos = new Dictionary<string, MpMapInfo>(StringComparer.OrdinalIgnoreCase);

        if (File.Exists(mpMapsPath))
        {
            string section = "";
            MpMapInfo? cur = null;
            foreach (var raw in File.ReadLines(mpMapsPath))
            {
                var line = raw.TrimEnd();
                var t = line.Trim();
                if (t.Length == 0) continue;

                if (t.StartsWith('['))
                {
                    var end = t.IndexOf(']');
                    section = end > 1 ? t.Substring(1, end - 1) : "";
                    if (section.StartsWith("Maps\\", StringComparison.OrdinalIgnoreCase) ||
                        section.StartsWith("Maps/", StringComparison.OrdinalIgnoreCase))
                    {
                        cur = GetInfo(infos, section);
                        cur.HasSection = true;
                    }
                    else cur = null;

                    // [GameModes] section name itself handled; per-mode sections ignored for map list
                    continue;
                }

                if (t.StartsWith(';') || t.StartsWith('#')) continue;
                var eq = t.IndexOf('=');
                if (eq <= 0) continue;
                var key = t[..eq].Trim();
                var val = t[(eq + 1)..].Trim();

                if (section.Equals("GameModes", StringComparison.OrdinalIgnoreCase))
                {
                    // preserve order by numeric key
                    modes.Add(val);
                }
                else if (section.Equals("MultiMaps", StringComparison.OrdinalIgnoreCase))
                {
                    multi.Add(key);
                    GetInfo(infos, key); // ensure entry exists
                }
                else if (cur != null)
                {
                    if (key.Equals("Description", StringComparison.OrdinalIgnoreCase)) cur.Description = val;
                    else if (key.Equals("Author", StringComparison.OrdinalIgnoreCase)) cur.Author = val;
                    else if (key.Equals("GameModes", StringComparison.OrdinalIgnoreCase))
                        cur.GameModes = val.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
                    else if (key.Equals("MaxPlayers", StringComparison.OrdinalIgnoreCase) && int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out var mx))
                        cur.MaxPlayers = mx;
                    else if (key.Equals("EnforceMaxPlayers", StringComparison.OrdinalIgnoreCase))
                        cur.EnforceMaxPlayers = val.Equals("True", StringComparison.OrdinalIgnoreCase) || val.Equals("yes", StringComparison.OrdinalIgnoreCase);
                }
            }
        }

        // Deduplicate modes while preserving order
        var seenMode = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        modes = modes.Where(m => m.Length > 0 && seenMode.Add(m)).ToList();

        var maps = new List<MapEntry>();
        var byPath = new Dictionary<string, MapEntry>(StringComparer.OrdinalIgnoreCase);

        foreach (var key in multi)
        {
            var info = infos.TryGetValue(key, out var mi) ? mi : new MpMapInfo { Key = key };
            var entry = BuildEntryFromMp(key, info);
            if (entry != null)
            {
                maps.Add(entry);
                byPath[entry.FilePath] = entry;
            }
        }

        // Maps found on disk but absent from [MultiMaps] -> "Other"/"All" with filename + waypoint prefix.
        foreach (var disk in ScanDiskMaps())
        {
            if (byPath.ContainsKey(disk.FilePath)) continue;
            maps.Add(disk);
            byPath[disk.FilePath] = disk;
        }

        return (modes, maps);
    }

    private static MpMapInfo GetInfo(Dictionary<string, MpMapInfo> infos, string key)
    {
        var norm = key.Replace('/', '\\');
        if (!infos.TryGetValue(norm, out var info))
        {
            info = new MpMapInfo { Key = norm };
            infos[norm] = info;
        }
        return info;
    }

    private static MapEntry? BuildEntryFromMp(string key, MpMapInfo info)
    {
        var relNoExt = key.Replace('/', '\\');
        // try common extensions
        string? filePath = null;
        string? ext = null;
        foreach (var e in new[] { ".map", ".yrm", ".mmx", ".yro" })
        {
            var p = Path.Combine(LauncherCore.Root, relNoExt + e);
            if (File.Exists(p)) { filePath = Path.GetFullPath(p); ext = e; break; }
        }
        if (filePath == null)
        {
            // still include? keep path best-effort
            filePath = Path.GetFullPath(Path.Combine(LauncherCore.Root, relNoExt + ".map"));
            ext = ".map";
        }

        var rel = Path.GetRelativePath(LauncherCore.Root, filePath).Replace('\\', '/');
        var preview = FindPreview(filePath);
        var waypointMax = ParseWaypointMaxPlayers(filePath);

        int maxPlayers;
        bool maxKnown;
        bool enforced = info.EnforceMaxPlayers && info.MaxPlayers.HasValue && info.MaxPlayers.Value > 0;
        if (enforced)
        {
            maxPlayers = Math.Clamp(info.MaxPlayers!.Value, 1, LauncherCore.MaxSkirmishSlots);
            maxKnown = true;
        }
        else if (waypointMax.HasValue)
        {
            maxPlayers = Math.Clamp(waypointMax.Value, 1, LauncherCore.MaxSkirmishSlots);
            maxKnown = true;
        }
        else
        {
            maxPlayers = LauncherCore.MaxSkirmishSlots;
            maxKnown = false;
        }

        var displayName = !string.IsNullOrWhiteSpace(info.Description)
            ? info.Description
            : BuildDisplayName(Path.GetFileNameWithoutExtension(filePath), maxPlayers, maxKnown);

        var gameModes = info.GameModes ?? new List<string>();
        // A map in [MultiMaps] with empty/missing GameModes or no section goes to "Other"/"All".
        var inMp = true;
        var hasSection = info.HasSection;
        var effectiveModes = (hasSection && gameModes.Count > 0) ? gameModes : new List<string>();

        return new MapEntry
        {
            Name = Path.GetFileNameWithoutExtension(filePath),
            FilePath = filePath,
            Relative = rel,
            Extension = ext ?? Path.GetExtension(filePath),
            DisplayName = displayName,
            Author = info.Author ?? "",
            GameModes = effectiveModes,
            MinPlayers = 1,
            MaxPlayers = maxPlayers,
            MaxPlayersKnown = maxKnown,
            EnforceMaxPlayers = enforced,
            PreviewPath = preview ?? "",
            InMpMaps = inMp,
            HasMpSection = hasSection
        };
    }

    private static List<MapEntry> ScanDiskMaps()
    {
        var list = new List<MapEntry>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Add(string path)
        {
            var full = Path.GetFullPath(path);
            if (!seen.Add(full)) return;
            var ext = Path.GetExtension(path).ToLowerInvariant();
            var rel = Path.GetRelativePath(LauncherCore.Root, full).Replace('\\', '/');
            var waypointMax = ParseWaypointMaxPlayers(full);
            var maxKnown = waypointMax.HasValue;
            var maxPlayers = waypointMax.HasValue ? Math.Clamp(waypointMax.Value, 1, LauncherCore.MaxSkirmishSlots) : LauncherCore.MaxSkirmishSlots;
            var baseName = Path.GetFileNameWithoutExtension(full);
            list.Add(new MapEntry
            {
                Name = baseName,
                FilePath = full,
                Relative = rel,
                Extension = ext,
                DisplayName = BuildDisplayName(baseName, maxPlayers, maxKnown),
                Author = "",
                GameModes = new List<string>(),
                MinPlayers = 1,
                MaxPlayers = maxPlayers,
                MaxPlayersKnown = maxKnown,
                EnforceMaxPlayers = false,
                PreviewPath = FindPreview(full) ?? "",
                InMpMaps = false,
                HasMpSection = false
            });
        }

        try
        {
            if (Directory.Exists(LauncherCore.Root))
                foreach (var f in Directory.GetFiles(LauncherCore.Root, "*.*", SearchOption.TopDirectoryOnly))
                {
                    var ext = Path.GetExtension(f).ToLowerInvariant();
                    if (ext is ".mmx" or ".yro") Add(f);
                }
        }
        catch { }

        var mapsDir = Path.Combine(LauncherCore.Root, "Maps");
        try
        {
            if (Directory.Exists(mapsDir))
                foreach (var f in Directory.EnumerateFiles(mapsDir, "*.*", SearchOption.AllDirectories))
                {
                    var ext = Path.GetExtension(f).ToLowerInvariant();
                    if (ext is ".mmx" or ".yro" or ".map" or ".yrm") Add(f);
                }
        }
        catch { }

        return list;
    }

    private static string BuildDisplayName(string fileName, int maxPlayers, bool known)
    {
        var n = known ? maxPlayers : 0;
        return n > 0 ? $"[{n}] {fileName}" : fileName;
    }

    private static string? FindPreview(string mapPath)
    {
        try
        {
            var dir = Path.GetDirectoryName(mapPath);
            var baseName = Path.GetFileNameWithoutExtension(mapPath);
            if (dir == null) return null;
            var png = Path.Combine(dir, baseName + ".png");
            return File.Exists(png) ? png : null;
        }
        catch { return null; }
    }

    /// <summary>Fallback: counts start waypoints 0-7 in [Waypoints] of the .map file.</summary>
    public static int? ParseWaypointMaxPlayers(string? mapPath)
    {
        if (string.IsNullOrWhiteSpace(mapPath) || !File.Exists(mapPath)) return null;
        try
        {
            var inWaypoints = false;
            var starts = new HashSet<int>();
            foreach (var raw in File.ReadLines(mapPath))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith(';')) continue;
                if (line.StartsWith('['))
                {
                    var end = line.IndexOf(']');
                    var section = end > 1 ? line.Substring(1, end - 1) : "";
                    inWaypoints = section.Equals("Waypoints", StringComparison.OrdinalIgnoreCase);
                    continue;
                }
                if (!inWaypoints) continue;
                var eq = line.IndexOf('=');
                if (eq <= 0) continue;
                if (int.TryParse(line.AsSpan(0, eq).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var wp)
                    && wp >= 0 && wp <= 7)
                    starts.Add(wp);
            }
            return starts.Count > 0 ? starts.Count : null;
        }
        catch { return null; }
    }
}
