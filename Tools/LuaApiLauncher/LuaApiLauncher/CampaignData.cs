using System.IO;
using System.Text;

namespace LuaApiLauncher;

public sealed class CampaignMission
{
    public string Id { get; set; } = "";
    public string Scenario { get; set; } = "";
    public string LaunchScenario { get; set; } = "";
    public string Description { get; set; } = "";
    public string LongDescription { get; set; } = "";
    public string SideName { get; set; } = "";
    public bool BuildOffAlly { get; set; }
    public int CD { get; set; } = -1;

    public string DisplayName => string.IsNullOrWhiteSpace(Description) ? Id : Description;
    public bool IsHeader => false;
}

public sealed class CampaignHeader
{
    public string Title { get; set; } = "";
    public bool IsHeader => true;
    public override string ToString() => Title;
}

public sealed class CampaignSide
{
    public string Title { get; set; } = "";
    public List<object> Items { get; } = new();
    public override string ToString() => Title;
}

public static class CampaignData
{
    public static string BattleIniPath => Path.Combine(LauncherCore.Root, "INI", "Battle.ini");
    public static string SpawnIniPath => Path.Combine(LauncherCore.Root, "spawn.ini");

    public static List<CampaignSide> LoadSides()
    {
        var ini = IniFile.Load(BattleIniPath);
        var list = ini.Section("Battles").ToList();
        if (list.Count == 0) return new();

        var training = new CampaignSide { Title = L10n.T("Учебный лагерь") };
        var allies = new CampaignSide { Title = L10n.T("Альянс") };
        var soviets = new CampaignSide { Title = L10n.T("Советский Союз") };
        var sides = new List<CampaignSide> { training, allies, soviets };

        string currentGame = "";      // e.g. "Red Alert 2", "Yuri's Revenge"
        string currentSideKey = "";   // Allies/Soviet/BootCamp
        string lastHeaderInSide = "";

        foreach (var (key, value) in list)
        {
            var id = string.IsNullOrWhiteSpace(value) ? key : value;
            var section = ini.Section(id).ToList();
            if (section.Count == 0) continue;

            var dict = ToDict(section);
            var scenarioRaw = Get(dict, "Scenario");
            var desc = Get(dict, "Description");
            var sideName = Get(dict, "SideName");

            // Section headers: description like "-- ... --" and no scenario.
            if (string.IsNullOrWhiteSpace(scenarioRaw) && desc.StartsWith("--", StringComparison.Ordinal))
            {
                ApplyHeader(desc.Trim('-', ' ', '\t'), ref currentGame, ref currentSideKey);
                lastHeaderInSide = "";
                continue;
            }

            if (id.StartsWith("VOID", StringComparison.OrdinalIgnoreCase)) continue;
            if (string.IsNullOrWhiteSpace(scenarioRaw)) continue;

            var launch = ResolveLaunchScenario(scenarioRaw);
            if (string.IsNullOrWhiteSpace(launch)) continue; // movie-only intros, etc.

            var mission = new CampaignMission
            {
                Id = id,
                Scenario = scenarioRaw.Trim(),
                LaunchScenario = launch,
                Description = desc,
                LongDescription = Get(dict, "LongDescription").Replace("@", Environment.NewLine),
                SideName = sideName,
                BuildOffAlly = IsTrue(Get(dict, "BuildOffAlly")),
                CD = int.TryParse(Get(dict, "CD"), out var cd) ? cd : -1,
            };

            var side = ResolveSide(currentSideKey, sideName, id);
            if (side == null) continue;

            // Insert a campaign/game subheader (e.g. "Red Alert 2", "Yuri's Revenge") when it changes within the side.
            var gameHeader = ResolveGameHeader(currentGame, id);
            if (!string.IsNullOrWhiteSpace(gameHeader) && !string.Equals(lastHeaderInSide, gameHeader, StringComparison.Ordinal))
            {
                // Avoid duplicate adjacent headers.
                if (side.Items.LastOrDefault() is not CampaignHeader h || !string.Equals(h.Title, gameHeader, StringComparison.Ordinal))
                    side.Items.Add(new CampaignHeader { Title = gameHeader });
                lastHeaderInSide = gameHeader;
            }

            side.Items.Add(mission);
        }

        // Drop sides with no missions (keep order Training/Allies/Soviets if present; user asked for these).
        sides.RemoveAll(s => !s.Items.OfType<CampaignMission>().Any());
        return sides;

        CampaignSide? ResolveSide(string sideKey, string sideName, string missionId)
        {
            var key = !string.IsNullOrWhiteSpace(sideName) ? sideName : sideKey;
            if (key.Equals("BootCamp", StringComparison.OrdinalIgnoreCase) ||
                key.Equals("Training", StringComparison.OrdinalIgnoreCase) ||
                missionId.Contains("TUT", StringComparison.OrdinalIgnoreCase))
                return training;
            if (key.Equals("Allied", StringComparison.OrdinalIgnoreCase) ||
                missionId.Contains("_ALL", StringComparison.OrdinalIgnoreCase))
                return allies;
            if (key.Equals("Soviet", StringComparison.OrdinalIgnoreCase) ||
                missionId.Contains("_SOV", StringComparison.OrdinalIgnoreCase))
                return soviets;
            if (key.Equals("Intro", StringComparison.OrdinalIgnoreCase)) return null;
            return null;
        }
    }

    private static void ApplyHeader(string title, ref string currentGame, ref string currentSideKey)
    {
        var t = title.ToLowerInvariant();
        if (t.Contains("yuri") && t.Contains("campaign"))
        {
            currentGame = "Yuri's Revenge";
            currentSideKey = "";
            return;
        }
        if (t.Contains("red alert 2") && t.Contains("campaign"))
        {
            currentGame = "Red Alert 2";
            currentSideKey = "";
            return;
        }
        if (t.Contains("boot camp") || t.Contains("training"))
        {
            currentSideKey = "BootCamp";
            return;
        }
        if (t.Contains("allied"))
        {
            currentSideKey = "Allied";
            return;
        }
        if (t.Contains("soviet"))
        {
            currentSideKey = "Soviet";
            return;
        }
        // Other headers (e.g. expansions/mod-specific) - keep current game context.
    }

    private static string ResolveGameHeader(string currentGame, string missionId)
    {
        if (!string.IsNullOrWhiteSpace(currentGame)) return currentGame;
        if (missionId.StartsWith("YR_", StringComparison.OrdinalIgnoreCase)) return "Yuri's Revenge";
        if (missionId.StartsWith("RA2_", StringComparison.OrdinalIgnoreCase)) return "Red Alert 2";
        return "";
    }

    /// <summary>
    /// Battle.ini scenarios may include prefixes like RA2->, YR->, or PlayMovies->...
    /// The CnCNet spawner expects a map filename in Scenario. Extract the last .map token.
    /// Returns empty for movie-only entries.
    /// </summary>
    private static string ResolveLaunchScenario(string raw)
    {
        raw = raw.Trim();
        if (raw.Length == 0) return "";

        var parts = raw.Split("->", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        for (var i = parts.Length - 1; i >= 0; i--)
        {
            foreach (var token in parts[i].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                if (token.EndsWith(".map", StringComparison.OrdinalIgnoreCase) ||
                    token.EndsWith(".yrm", StringComparison.OrdinalIgnoreCase) ||
                    token.EndsWith(".mpr", StringComparison.OrdinalIgnoreCase))
                    return token;
            }
        }

        if (parts.Length > 0)
        {
            var last = parts[^1].Trim();
            if (last.EndsWith(".map", StringComparison.OrdinalIgnoreCase)) return last;
        }

        return "";
    }

    /// <summary>
    /// Single-player campaign spawn.ini, the same file the CnCNet client writes
    /// before it starts a mission. CnCNet-Spawner.dll reads it from the game
    /// root: [Settings] carries the scenario and the game options, and
    /// [SpawnLocations] the per-player start positions.
    /// </summary>
    public static void WriteSpawnIni(CampaignMission mission, int difficulty, int gameSpeed, SkirmishOptions? options = null)
    {
        var diff = Math.Clamp(difficulty, 0, 2);
        var speed = Math.Clamp(gameSpeed, 0, 6);
        var ra2Mode = mission.Id.StartsWith("RA2_", StringComparison.OrdinalIgnoreCase)
                      || mission.Scenario.Contains("RA2->", StringComparison.OrdinalIgnoreCase);
        var sideIndex = mission.SideName.Equals("Soviet", StringComparison.OrdinalIgnoreCase) ? 1 : 0;

        // The scenario keeps the "RA2->" prefix: the spawner strips it itself and
        // uses its presence to switch the game into RA2 mode.
        var scenario = string.IsNullOrWhiteSpace(mission.Scenario) ? mission.LaunchScenario : mission.Scenario.Trim();

        var sb = new StringBuilder();
        sb.AppendLine("; Generated by the Yuri's Echo launcher for campaign mission launch");
        sb.AppendLine("[Settings]");
        sb.AppendLine("Scenario=" + scenario);
        sb.AppendLine("UIMapName=" + SanitizeUiName(mission.DisplayName));
        sb.AppendLine("IsSinglePlayer=Yes");
        sb.AppendLine("CampaignID=-1");
        sb.AppendLine("Side=" + sideIndex);
        sb.AppendLine("Difficulty=" + diff);
        sb.AppendLine("DifficultyModeHuman=" + diff);
        sb.AppendLine("DifficultyModeComputer=" + (2 - diff));
        sb.AppendLine("CampDifficulty=" + diff);
        sb.AppendLine("GameSpeed=" + speed);
        sb.AppendLine("Ra2Mode=" + (ra2Mode ? "Yes" : "No"));
        sb.AppendLine("Firestorm=No");
        sb.AppendLine("BuildOffAlly=" + (mission.BuildOffAlly ? "Yes" : "No"));
        sb.AppendLine("SidebarHack=Yes");
        sb.AppendLine("LoadSaveGame=No");
        sb.AppendLine("Seed=" + (Environment.TickCount & 0x7FFFFFFF));

        // The options the CnCNet client always writes (Resources\GameOptions.ini).
        foreach (var (key, value) in ReadForcedSpawnIniOptions())
            sb.AppendLine(key + "=" + value);

        // The skirmish options of the launcher - the spawner applies them.
        if (options != null)
        {
            sb.AppendLine("Credits=" + options.Credits);
            sb.AppendLine("UnitCount=" + options.UnitCount);
            sb.AppendLine("ShortGame=" + YesNo(options.ShortGame));
            sb.AppendLine("BridgeDestroy=" + YesNo(options.BridgeDestroy));
            sb.AppendLine("BuildOffAlly=" + YesNo(options.BuildOffAlly));
            sb.AppendLine("MultiEngineer=" + YesNo(options.MultiEngineer));
            sb.AppendLine("MCVRedeploy=" + YesNo(options.MCVRedeploy));
            sb.AppendLine("AlliesAllowed=" + YesNo(options.AlliesAllowed));
            sb.AppendLine("Crates=" + YesNo(options.Crates));
            sb.AppendLine("Superweapons=" + YesNo(options.SuperWeapons != 3));
        }

        // Auto save every 4 minutes, like the client's mission selector does.
        sb.AppendLine("AutoSaveInterval=7200");
        sb.AppendLine("AutoSaveCount=1");

        sb.AppendLine();
        sb.AppendLine("[SpawnLocations]");
        sb.AppendLine();

        File.WriteAllText(SpawnIniPath, sb.ToString(), new UTF8Encoding(false));
    }

    private static string YesNo(bool value) => value ? "Yes" : "No";

    /// <summary>
    /// Resources\GameOptions.ini [ForcedSpawnIniOptions] - the options the
    /// CnCNet client writes into every spawn.ini.
    /// </summary>
    private static IEnumerable<(string Key, string Value)> ReadForcedSpawnIniOptions()
    {
        var ini = IniFile.Load(Path.Combine(LauncherCore.Root, "Resources", "GameOptions.ini"));
        foreach (var (key, value) in ini.Section("ForcedSpawnIniOptions"))
        {
            if (string.IsNullOrWhiteSpace(key)) continue;
            yield return (key, value);
        }
    }

    private static string SanitizeUiName(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "Mission";
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (ch is '\r' or '\n' or '=' or ';') sb.Append(' ');
            else sb.Append(ch);
        }
        return sb.ToString().Trim();
    }

    private static Dictionary<string, string> ToDict(IEnumerable<(string Key, string Value)> items)
    {
        var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (k, v) in items) dict[k] = v;
        return dict;
    }

    private static string Get(Dictionary<string, string> dict, string key) =>
        dict.TryGetValue(key, out var v) ? v : "";

    private static bool IsTrue(string? v) =>
        v != null && (v.Equals("yes", StringComparison.OrdinalIgnoreCase) || v.Equals("true", StringComparison.OrdinalIgnoreCase) || v == "1");
}
