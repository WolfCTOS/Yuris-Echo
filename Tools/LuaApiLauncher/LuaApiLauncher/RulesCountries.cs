using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace LuaApiLauncher;

/// <summary>One country the rules register, as the skirmish setup offers it.</summary>
public sealed class CountryOption
{
    /// <summary>Index in the rules' [Countries] table. The spawner identifies a house by it.</summary>
    public int Index { get; init; }
    /// <summary>House section in the rules, e.g. "Alliance".</summary>
    public string House { get; init; } = "";
    /// <summary>Name the rules give the country (Name= of the house section).</summary>
    public string Name { get; init; } = "";
    /// <summary>Side the house belongs to: GDI, Nod or ThirdSide.</summary>
    public string Side { get; init; } = "";
    /// <summary>The rules mark the house as playable (Multiplay=yes).</summary>
    public bool Multiplay { get; init; }

    /// <summary>Label for the setup table: the rules' name, the house name as fallback.</summary>
    public string Label => Name.Length > 0 ? Name : House;
}

/// <summary>A faction of the mod: the houses that play together.</summary>
public sealed class FactionOption
{
    /// <summary>Name the rules give the faction (the key of its [Factions] entry).</summary>
    public string Name { get; init; } = "";
    /// <summary>Houses of the faction in rules order. The first one is the country the player gets.</summary>
    public List<int> Countries { get; init; } = new();
    /// <summary>Index of the first house: the country index the spawner expects.</summary>
    public int PrimaryIndex => Countries.Count > 0 ? Countries[0] : -1;
}

/// <summary>
/// The country table of rulesmd.ini.
///
/// The spawner identifies a house by its index in the rules' [Countries] table:
/// [Settings] Side and [HouseCountries] MultiN carry that index, and the engine
/// resolves it against the loaded rules. The skirmish setup therefore has to
/// offer exactly the countries the rules register - a hardcoded client list
/// would offer countries the rules do not know and would hide the ones they do.
/// </summary>
public static class RulesCountries
{
    /// <summary>Houses that are not countries: side containers, neutrals, observer.</summary>
    private static readonly HashSet<string> NotCountries = new(StringComparer.OrdinalIgnoreCase)
    {
        "GDI", "Nod", "Neutral", "Special", "Observer"
    };

    /// <summary>What the rules say about one house.</summary>
    private sealed class HouseInfo
    {
        public string Name { get; set; } = "";
        public string Side { get; set; } = "";
        public bool Multiplay { get; set; }
    }

    private sealed record Cache(string Path, long Ticks, long Size, List<CountryOption> Countries, List<FactionOption> Factions);

    private static readonly object _gate = new();
    private static Cache? _cache;

    public static string RulesPath => Path.Combine(LauncherCore.Root, "rulesmd.ini");

    /// <summary>Every country of the rules table, in index order.</summary>
    public static List<CountryOption> Load(string? path = null) => Get(path).Countries;

    /// <summary>
    /// The countries the rules mark as playable. If a rules file marks none of
    /// them playable, every country is offered instead - an empty setup table
    /// would be worse than a wrong one.
    /// </summary>
    public static List<CountryOption> Playable(string? path = null)
    {
        var all = Get(path).Countries;
        var playable = all.FindAll(c => c.Multiplay);
        return playable.Count > 0 ? playable : all;
    }

    /// <summary>
    /// The factions of the rules: the [Factions] section, whose entries name a
    /// faction and list its houses. A faction is what the setup table offers;
    /// its first house is the country the player gets.
    /// </summary>
    public static List<FactionOption> Factions(string? path = null) => Get(path).Factions;

    /// <summary>Returns the parsed rules, cached by file mtime/size.</summary>
    private static Cache Get(string? path)
    {
        var p = path ?? RulesPath;
        long ticks = 0, size = 0;
        try
        {
            if (File.Exists(p))
            {
                var fi = new FileInfo(p);
                ticks = fi.LastWriteTimeUtc.Ticks;
                size = fi.Length;
            }
        }
        catch { }

        lock (_gate)
        {
            if (_cache != null && string.Equals(_cache.Path, p, StringComparison.OrdinalIgnoreCase)
                && _cache.Ticks == ticks && _cache.Size == size)
                return _cache;

            _cache = Parse(p, ticks, size);
            return _cache;
        }
    }

    /// <summary>Parses countries and factions in a single read of the rules file.</summary>
    private static Cache Parse(string path, long ticks, long size)
    {
        var countries = new List<CountryOption>();
        var factions = new List<FactionOption>();

        string[] lines;
        try
        {
            lines = File.Exists(path) ? File.ReadAllLines(path) : Array.Empty<string>();
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Failed to read the rules country table: " + path, ex);
            return new Cache(path, ticks, size, countries, factions);
        }

        // First pass: the [Countries] table maps the house index to the house.
        var houses = new Dictionary<int, string>();
        var section = "";
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith(';')) continue;
            if (line.StartsWith('[')) { section = SectionName(line); continue; }
            if (!section.Equals("Countries", StringComparison.OrdinalIgnoreCase)) continue;
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;
            if (!int.TryParse(line[..eq].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var index)) continue;
            var house = line[(eq + 1)..].Split(';')[0].Trim();
            if (house.Length == 0 || NotCountries.Contains(house)) continue;
            houses[index] = house;
        }

        // Second pass: house sections (name/flags) and the [Factions] section.
        var wanted = new HashSet<string>(houses.Values, StringComparer.OrdinalIgnoreCase);
        var info = new Dictionary<string, HouseInfo>(StringComparer.OrdinalIgnoreCase);
        var factionRows = new List<(string Name, string Value)>();
        section = "";
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith(';')) continue;
            if (line.StartsWith('[')) { section = SectionName(line); continue; }

            var eq = line.IndexOf('=');
            if (eq <= 0) continue;

            if (section.Equals("Factions", StringComparison.OrdinalIgnoreCase))
            {
                var name = line[..eq].Trim();
                if (name.Length > 0) factionRows.Add((name, line[(eq + 1)..]));
                continue;
            }

            if (!wanted.Contains(section)) continue;
            var key = line[..eq].Trim();
            var value = line[(eq + 1)..].Split(';')[0].Trim();
            var current = info.TryGetValue(section, out var c) ? c : new HouseInfo();
            if (key.Equals("Name", StringComparison.OrdinalIgnoreCase)) current.Name = value;
            else if (key.Equals("Side", StringComparison.OrdinalIgnoreCase)) current.Side = value;
            else if (key.Equals("Multiplay", StringComparison.OrdinalIgnoreCase))
                current.Multiplay = value.Equals("yes", StringComparison.OrdinalIgnoreCase);
            info[section] = current;
        }

        foreach (var (index, house) in houses)
        {
            var entry = info.TryGetValue(house, out var c) ? c : new HouseInfo();
            countries.Add(new CountryOption
            {
                Index = index,
                House = house,
                Name = entry.Name.Length > 0 ? entry.Name : house,
                Side = entry.Side,
                Multiplay = entry.Multiplay
            });
        }
        countries.Sort((a, b) => a.Index.CompareTo(b.Index));

        var byHouse = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var c in countries) byHouse[c.House] = c.Index;

        foreach (var (name, value) in factionRows)
        {
            var list = new List<int>();
            foreach (var house in value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                if (byHouse.TryGetValue(house, out var index)) list.Add(index);
            if (list.Count == 0) continue;
            factions.Add(new FactionOption { Name = name, Countries = list });
        }

        return new Cache(path, ticks, size, countries, factions);
    }

    /// <summary>Section name of a header line: "[Alliance] ; comment" -> "Alliance".</summary>
    private static string SectionName(string line)
    {
        var end = line.IndexOf(']');
        return end > 0 ? line[1..end].Trim() : "";
    }
}
