using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace LuaApiLauncher;

/// <summary>
/// Collects everything that is needed to diagnose a failed launch into one
/// text block: the launcher's own log, the tail of the LuaAPI log and the
/// state the launcher was in when it started the game.
///
/// The bundle is written to a file next to the game and copied to the
/// clipboard, so it can be attached to a bug report without guessing which
/// files are relevant.
/// </summary>
internal static class LauncherDiagnostics
{
    /// <summary>How many lines of each log are included.</summary>
    public const int TailLines = 400;

    public static string Build(LauncherConfig cfg, IEnumerable<ModInfo>? mods = null, IEnumerable<string>? activeIds = null)
    {
        var sb = new StringBuilder();
        sb.AppendLine("=== Yuri's Echo diagnostics ===");
        sb.AppendLine($"generated : {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        sb.AppendLine($"root      : {LauncherCore.Root}");
        sb.AppendLine($"exe       : {Environment.ProcessPath}");
        sb.AppendLine($"os        : {Environment.OSVersion} / {(Environment.Is64BitProcess ? "x64" : "x86")} process");
        sb.AppendLine();

        AppendConfig(sb, cfg);

        if (mods != null)
        {
            sb.AppendLine("--- mods ---");
            var activeSet = new HashSet<string>(activeIds ?? Enumerable.Empty<string>(), StringComparer.Ordinal);
            foreach (var m in mods)
                sb.AppendLine($"  [{(activeSet.Contains(m.Id) ? "x" : " ")}] {m.Id}  (v{m.Version})");
            sb.AppendLine();
        }

        AppendLog(sb, "launcher.log", LauncherLog.Path, TailLines);
        AppendLog(sb, "LuaAPI.log", Path.Combine(LauncherCore.Root, "LuaAPI.log"), TailLines);

        return sb.ToString();
    }

    private static void AppendConfig(StringBuilder sb, LauncherConfig cfg)
    {
        sb.AppendLine("--- config ---");
        sb.AppendLine($"  syringe    : {cfg.Syringe} {(File.Exists(Path.Combine(LauncherCore.Root, cfg.Syringe)) ? "(found)" : "(MISSING)")}");
        sb.AppendLine($"  gamemd     : {cfg.Gamemd} {(File.Exists(Path.Combine(LauncherCore.Root, cfg.Gamemd)) ? "(found)" : "(MISSING)")}");
        sb.AppendLine($"  language   : {cfg.Language}");
        sb.AppendLine($"  map        : {Relative(cfg.Skirmish.SelectedMap)}");
        sb.AppendLine($"  mode       : {cfg.Skirmish.SelectedMode}");
        sb.AppendLine($"  game speed : {cfg.Skirmish.Options.GameSpeed}");
        sb.AppendLine($"  players    : {cfg.Skirmish.Players.Count}");
        foreach (var p in cfg.Skirmish.Players)
            sb.AppendLine($"    - {(p.IsHuman ? "human" : "ai")} '{p.Name}' country={p.Country} color={p.Color} team={p.Team} start={p.Start} ai={p.AiLevel}");
        sb.AppendLine();
    }

    /// <summary>Paths inside the game folder are shown relative to it, so the bundle stays readable.</summary>
    private static string Relative(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "(none)";
        try
        {
            var root = LauncherCore.Root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            return path.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? path.Substring(root.Length) : path;
        }
        catch { return path; }
    }

    private static void AppendLog(StringBuilder sb, string title, string path, int tailLines)
    {
        sb.AppendLine($"--- {title} ---");
        if (!File.Exists(path))
        {
            sb.AppendLine("  (no file)");
            sb.AppendLine();
            return;
        }

        try
        {
            var fi = new FileInfo(path);
            sb.AppendLine($"  file: {path}");
            sb.AppendLine($"  size: {fi.Length} bytes, modified {fi.LastWriteTime:yyyy-MM-dd HH:mm:ss}");

            // The tail only: the head of a long log is rarely the interesting part.
            var lines = new Queue<string>();
            foreach (var line in File.ReadLines(path))
            {
                if (lines.Count == tailLines) lines.Dequeue();
                lines.Enqueue(line);
            }
            foreach (var line in lines) sb.AppendLine("  " + line);
        }
        catch (Exception ex)
        {
            sb.AppendLine($"  (unreadable: {ex.Message})");
        }
        sb.AppendLine();
    }

    /// <summary>
    /// Writes the bundle next to the game and returns the file path.
    /// </summary>
    public static string WriteToFile(string content)
    {
        var path = Path.Combine(LauncherCore.Root, "launcher-diagnostics.txt");
        try
        {
            File.WriteAllText(path, content, new UTF8Encoding(false));
            return path;
        }
        catch
        {
            return "";
        }
    }
}
