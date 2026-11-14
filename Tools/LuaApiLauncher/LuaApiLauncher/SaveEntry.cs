using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace LuaApiLauncher;

/// <summary>One row of the saved-games / replays list.</summary>
public sealed class SaveEntry
{
    private static readonly Regex PrintableRun = new(@"[\x20-\x7E]{3,}", RegexOptions.Compiled);
    private static readonly Regex Bracketed = new(@"\[([^\[\]]{2,60})\]", RegexOptions.Compiled);

    public string FileName { get; init; } = "";

    /// <summary>Name the game itself shows for this save ("Skirmish Game - Autosave (slot 5)").</summary>
    public string GameName { get; init; } = "";

    public string Name => !string.IsNullOrEmpty(GameName) ? GameName : Path.GetFileNameWithoutExtension(FileName);
    public DateTime Modified { get; init; }
    public string DateText => Modified == DateTime.MinValue ? "" : Modified.ToString("dd.MM.yyyy HH:mm:ss");
    public string SizeText { get; init; } = "";

    /// <summary>
    /// Reads the display name the game stores in the save header (a UTF-16
    /// string near the start of the file). Returns "" when there is none.
    /// </summary>
    public static string ReadGameName(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            var head = new byte[16 * 1024];
            var read = fs.Read(head, 0, head.Length);
            var text = Encoding.Unicode.GetString(head, 0, read);

            string skirmish = "";
            foreach (Match m in PrintableRun.Matches(text))
            {
                var s = m.Value;
                // Campaign saves carry "[Mission Name]", skirmish saves "Skirmish Game ...".
                var bracket = Bracketed.Match(s);
                if (bracket.Success && bracket.Groups[1].Value.Any(char.IsLetter)) return bracket.Value;
                if (skirmish.Length == 0 && s.StartsWith("Skirmish Game", StringComparison.Ordinal)) skirmish = s;
            }
            return skirmish;
        }
        catch
        {
            // Unreadable save: the file name stays as the display name.
            return "";
        }
    }
}
