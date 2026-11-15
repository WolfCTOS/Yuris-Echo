using System.IO;

namespace LuaApiLauncher;

/// <summary>
/// The superweapon modes of the skirmish screen. They are the same four the
/// CnCNet lobby offers: All / Strategic / Tactical / None.
///
/// The game itself only knows one switch: GameModeOptionsClass::SWAllowed,
/// which the spawner reads from spawn.ini [Settings] Superweapons. A
/// superweapon is unavailable when its type carries DisableableFromShell and
/// that switch is off - the game checks the flag of the type
/// (SuperWeaponTypeClass::DisableableFromShell) when it hands the superweapon
/// out and when the AI picks what to build (gamemd.exe).
///
/// Which types the switch affects is decided by that flag, and the scenario
/// may override it: the map file is parsed as rules "map code" when the game
/// loads it (RulesClass::Read_File -> Read_SpecialWeapons), so the launcher
/// writes the flag into the map copy it hands to the spawner.
/// </summary>
public static class SuperWeaponModes
{
    /// <summary>Every superweapon works.</summary>
    public const int All = 0;

    /// <summary>Only the offensive superweapons (nuke, lightning storm, psychic dominator).</summary>
    public const int Strategic = 1;

    /// <summary>Only the defensive superweapons (chrono sphere, iron curtain, force shield, genetic converter).</summary>
    public const int Tactical = 2;

    /// <summary>No superweapons at all.</summary>
    public const int None = 3;

    /// <summary>The drop down labels, in the order of the mode values.</summary>
    public static string[] Labels => new[]
    {
        L10n.T("Все"),
        L10n.T("Стратегические"),
        L10n.T("Тактические"),
        L10n.T("Нет")
    };

    public static int Clamp(int mode) => mode is >= All and <= None ? mode : All;

    /// <summary>
    /// The game's own superweapon switch (GameModeOptionsClass::SWAllowed) for
    /// this mode. It is only on for "All": with the switch off the game turns
    /// off every superweapon whose type is disableable from the shell, so the
    /// flag written into the map decides what still works.
    /// </summary>
    public static bool GlobalSwitchOn(int mode) => Clamp(mode) == All;

    /// <summary>
    /// True when the game has to switch this superweapon type off while the
    /// superweapon switch is off. In "All" mode nothing is switched off, in the
    /// two middle modes only the other category is, and in "None" mode every
    /// type is - including the ones the rules leave switched on (para drop,
    /// spy plane, psychic reveal).
    /// </summary>
    public static bool DisableableFromShell(int mode, string typeName)
    {
        switch (Clamp(mode))
        {
            case All: return false;
            case Strategic: return !IsOffensive(typeName);
            case Tactical: return !IsDefensive(typeName);
            default: return true;
        }
    }

    /// <summary>The offensive superweapons - the client's Offensive.ini.</summary>
    public static bool IsOffensive(string typeName) =>
        typeName.Equals("NukeSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("MultiSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("LightningStormSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("PsychicDominatorSpecial", StringComparison.OrdinalIgnoreCase);

    /// <summary>The defensive superweapons - the client's Defensive.ini.</summary>
    public static bool IsDefensive(string typeName) =>
        typeName.Equals("ChronoSphereSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("ChronoWarpSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("IronCurtainSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("ForceShieldSpecial", StringComparison.OrdinalIgnoreCase)
        || typeName.Equals("GeneticConverterSpecial", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The superweapon types of the rules. The list comes from rulesmd.ini
    /// [SuperWeaponTypes]; the standard types are the fallback when the rules
    /// file cannot be read.
    /// </summary>
    public static IReadOnlyList<string> Types()
    {
        var types = new List<string>();
        try
        {
            var ini = IniFile.Load(Path.Combine(LauncherCore.Root, "rulesmd.ini"));
            foreach (var (_, value) in ini.Section("SuperWeaponTypes"))
            {
                var name = value.Trim();
                if (name.Length == 0) continue;
                if (!types.Contains(name, StringComparer.OrdinalIgnoreCase)) types.Add(name);
            }
        }
        catch (Exception ex)
        {
            LauncherLog.Warn("superweapon types: rules read failed (" + ex.Message + ")");
        }

        if (types.Count == 0)
        {
            types.AddRange(new[]
            {
                "NukeSpecial", "MultiSpecial", "IronCurtainSpecial", "LightningStormSpecial",
                "ChronoSphereSpecial", "ChronoWarpSpecial", "ParaDropSpecial", "AmericanParaDropSpecial",
                "PsychicDominatorSpecial", "SpyPlaneSpecial", "GeneticConverterSpecial", "ForceShieldSpecial",
                "PsychicRevealSpecial"
            });
        }
        return types;
    }

    /// <summary>A short description of the mode for the log and the tool tip.</summary>
    public static string Describe(int mode)
    {
        switch (Clamp(mode))
        {
            case Strategic: return "Strategic (nuke, lightning storm, psychic dominator)";
            case Tactical: return "Tactical (chrono sphere, iron curtain, force shield, genetic converter)";
            case None: return "None (no superweapons)";
            default: return "All (every superweapon)";
        }
    }
}
