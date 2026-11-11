using System.IO;
using System.Text;

namespace LuaApiLauncher;

public sealed record ComponentInfo(string File, string Label, long Size, bool Installed)
{
    public string Display => Installed
        ? $"{File}   ·   {L10n.T(Label)}   ·   {LauncherExtras.FormatSize(Size)}   ·   {L10n.T("установлено")}"
        : $"{File}   ·   {L10n.T(Label)}   ·   {L10n.T("НЕ УСТАНОВЛЕНО")}";
}

/// <summary>Storage, update channel and component helpers. Reads client files; writes only updateconfig.ini.</summary>
public static class LauncherExtras
{
    public static readonly string[] Channels = ["Live", "Pre-release", "Dev", "Legacy (Unsupported)"];

    private static readonly (string Name, string File)[] ChannelFiles =
    [
        ("Live", "UpdaterConfig_Live.ini"),
        ("Pre-release", "UpdaterConfig_PreRelease.ini"),
        ("Dev", "UpdaterConfig_Dev.ini"),
        ("Legacy (Unsupported)", "UpdaterConfig_Legacy.ini"),
    ];

    public static string UpdateConfigPath => Path.Combine(LauncherCore.Root, "updateconfig.ini");
    public static string ChannelDir => Path.Combine(LauncherCore.Root, "Resources", "Config");

    public const string SupportUrl = "https://discord.com/channels/188156159620939776/1060560955186085888";

    private static string? FirstUrl(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            foreach (var line in File.ReadLines(path))
            {
                var t = line.Trim();
                if (t.Length == 0 || t.StartsWith(';') || t.StartsWith('[')) continue;
                var url = t.Split(',')[0].Trim();
                if (url.StartsWith("http", StringComparison.OrdinalIgnoreCase))
                    return url.TrimEnd('/').ToLowerInvariant();
            }
        }
        catch { }
        return null;
    }

    public static string DetectChannel()
    {
        var current = FirstUrl(UpdateConfigPath);
        if (current == null) return Channels[0];
        foreach (var (name, file) in ChannelFiles)
            if (FirstUrl(Path.Combine(ChannelDir, file)) == current) return name;
        return L10n.T("Пользовательский канал");
    }

    /// <summary>Copies Resources\Config\UpdaterConfig_&lt;channel&gt;.ini over updateconfig.ini, as the client does.</summary>
    public static void ApplyChannel(string channel)
    {
        foreach (var (name, file) in ChannelFiles)
        {
            if (name != channel) continue;
            var src = Path.Combine(ChannelDir, file);
            if (!File.Exists(src)) throw new FileNotFoundException(L10n.T("Нет файла канала: ") + src);
            if (File.Exists(UpdateConfigPath))
                File.Copy(UpdateConfigPath, UpdateConfigPath + ".bak", overwrite: true);
            File.Copy(src, UpdateConfigPath, overwrite: true);
            return;
        }
        throw new ArgumentException(L10n.T("Неизвестный канал: ") + channel);
    }

    public static string FormatSize(long bytes) => LauncherCore.FormatSize(bytes);

    public static long DirSize(string path)
    {
        try
        {
            if (!Directory.Exists(path)) return 0;
            long total = 0;
            foreach (var f in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                try { total += new FileInfo(f).Length; } catch { }
            }
            return total;
        }
        catch { return 0; }
    }

    public static string StorageReport()
    {
        var rows = new (string Label, string Path)[]
        {
            ("Карты", Path.Combine(LauncherCore.Root, "Maps")),
            ("Моды LuaAPI", LauncherCore.ModsDir),
            ("Ресурсы клиента", Path.Combine(LauncherCore.Root, "Resources")),
            ("Сохранения", Path.Combine(LauncherCore.Root, "Saved Games")),
            ("Реплеи", Path.Combine(LauncherCore.Root, "Replays")),
            ("Вся папка игры", LauncherCore.Root),
        };

        var sb = new StringBuilder();
        foreach (var (label, path) in rows)
        {
            var size = DirSize(path);
            sb.AppendLine(L10n.T(label).PadRight(20) + (size > 0 ? FormatSize(size) : L10n.T("нет данных")));
        }
        return sb.ToString().TrimEnd();
    }

    public static string DiskReport()
    {
        var root = Path.GetPathRoot(LauncherCore.Root);
        if (string.IsNullOrEmpty(root)) return L10n.T("Диск не определён.");
        try
        {
            var d = new DriveInfo(root);
            return L10n.F("Свободно: {0}\nВсего: {1}\nДиск {2}",
                FormatSize(d.AvailableFreeSpace), FormatSize(d.TotalSize), d.Name.TrimEnd('\\'));
        }
        catch (Exception ex) { return L10n.T("Диск недоступен: ") + ex.Message; }
    }

    private static readonly (string File, string Label)[] KnownComponents =
    [
        ("movies01.mix", "видео кампании RA2"),
        ("movies02.mix", "видео кампании RA2"),
        ("movmd03.mix", "видео кампании YR"),
        ("fsmusic.mix", "музыка Firestorm"),
        ("tsmusic.mix", "музыка Tiberian Sun"),
        ("cncnet.mix", "контент CnCNet"),
    ];

    public static List<ComponentInfo> ScanComponents()
    {
        var list = new List<ComponentInfo>();
        foreach (var (file, label) in KnownComponents)
        {
            var path = Path.Combine(LauncherCore.Root, file);
            var exists = File.Exists(path);
            long size = 0;
            if (exists) { try { size = new FileInfo(path).Length; } catch { } }
            list.Add(new ComponentInfo(file, label, size, exists));
        }
        return list;
    }
}
