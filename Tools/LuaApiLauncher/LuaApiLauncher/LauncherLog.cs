using System.Diagnostics;
using System.IO;
using System.Text;

namespace LuaApiLauncher;

internal static class LauncherLog
{
    private static readonly object Sync = new();
    private static string? _path;
    private static bool _initialized;

    public static string Path => _path ??= System.IO.Path.Combine(LauncherCore.Root, "launcher.log");

    public static void Init()
    {
        if (_initialized) return;
        _initialized = true;
        try
        {
            var dir = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            WriteRaw($"=== Yuri's Echo Launcher log started {DateTime.Now:yyyy-MM-dd HH:mm:ss} ===");
            AppDomain.CurrentDomain.ProcessExit += (_, _) => WriteRaw("=== log end (process exit) ===");
        }
        catch
        {
            // Logging must never crash the launcher.
        }
    }

    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);

    public static void Error(string message, Exception? ex = null)
    {
        if (ex == null) { Write("ERROR", message); return; }
        Write("ERROR", message + Environment.NewLine + ex);
    }

    public static void Write(string level, string message)
    {
        try
        {
            Init();
            WriteRaw($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [{level}] {message}");
        }
        catch { }
    }

    private static void WriteRaw(string line)
    {
        try
        {
            lock (Sync)
            {
                File.AppendAllText(Path, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch { }
    }

    public static bool TryOpen()
    {
        try
        {
            Init();
            Process.Start(new ProcessStartInfo(Path) { UseShellExecute = true });
            return true;
        }
        catch (Exception ex)
        {
            Error("Failed to open log file", ex);
            return false;
        }
    }

    /// <summary>Maps common exceptions to a user-friendly localized message.</summary>
    public static string FriendlyMessage(Exception ex, string? contextRu = null)
    {
        var prefix = string.IsNullOrWhiteSpace(contextRu) ? "" : contextRu.TrimEnd('.', ' ') + ". ";
        return ex switch
        {
            FileNotFoundException or DirectoryNotFoundException => prefix + L10n.T("Не найден необходимый файл или папка."),
            IOException io when IsSharingViolation(io) => prefix + L10n.T("Файл занят другим процессом. Закройте программы, которые могут его использовать, и попробуйте снова."),
            UnauthorizedAccessException => prefix + L10n.T("Нет доступа к файлу. Проверьте права и не заблокирован ли файл другим приложением."),
            IOException => prefix + L10n.T("Ошибка чтения или записи файла. Подробности записаны в журнал лаунчера."),
            System.Text.Json.JsonException => prefix + L10n.T("Файл настроек повреждён или имеет неверный формат. Подробности записаны в журнал лаунчера."),
            FormatException => prefix + L10n.T("Неверный формат данных в файле настроек."),
            _ => prefix + L10n.T("Произошла ошибка. Подробности записаны в журнал лаунчера."),
        };
    }

    private static bool IsSharingViolation(IOException ex)
    {
        // ERROR_SHARING_VIOLATION = 32, ERROR_LOCK_VIOLATION = 33
        var code = ex.HResult & 0xFFFF;
        return code == 32 || code == 33;
    }
}
