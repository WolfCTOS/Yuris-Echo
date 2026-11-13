using System.Diagnostics;
using System.IO;
using System.Text;

namespace LuaApiLauncher;

internal static class LauncherLog
{
    private static readonly object Sync = new();
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static string? _path;
    private static bool _initialized;

    /// <summary>How many rotated log files are kept next to the current one.</summary>
    public const int MaxRotatedFiles = 3;

    /// <summary>Size at which the current log file is rotated.</summary>
    public const long MaxBytes = 512 * 1024;

    public static string Path => _path ??= System.IO.Path.Combine(LauncherCore.Root, "launcher.log");

    /// <summary>Set the environment variable YURISECHO_DEBUG=1 to get the verbose lines.</summary>
    public static bool Verbose =>
        Environment.GetEnvironmentVariable("YURISECHO_DEBUG") == "1";

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

    public static void Debug(string message) { if (Verbose) Write("DEBUG", message); }
    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);

    public static void Error(string message, Exception? ex = null)
    {
        if (ex == null) { Write("ERROR", message); return; }
        Write("ERROR", message + Environment.NewLine + ex);
    }

    /// <summary>
    /// One step of the launch pipeline. The elapsed time is measured from the
    /// moment the launcher process started, so a slow step is visible in the
    /// log without needing a stopwatch of its own.
    /// </summary>
    public static void Step(string stage, string message) =>
        Write("STEP", $"{stage}: {message} (+{Clock.ElapsedMilliseconds} ms)");

    /// <summary>Marks the beginning of a phase in the log.</summary>
    public static void Section(string title) => Write("INFO", $"--- {title} ---");

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
                RotateIfNeeded(line.Length);
                File.AppendAllText(Path, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch { }
    }

    /// <summary>
    /// Keeps the log from growing without bound: once it passes the size cap
    /// the current file becomes launcher.1.log and the older ones shift down.
    /// </summary>
    private static void RotateIfNeeded(int incomingLength)
    {
        try
        {
            var fi = new FileInfo(Path);
            if (!fi.Exists || fi.Length + incomingLength <= MaxBytes) return;

            var oldest = RotatedPath(MaxRotatedFiles);
            if (File.Exists(oldest)) File.Delete(oldest);

            for (var i = MaxRotatedFiles - 1; i >= 1; i--)
            {
                var from = RotatedPath(i);
                if (!File.Exists(from)) continue;
                var to = RotatedPath(i + 1);
                if (File.Exists(to)) File.Delete(to);
                File.Move(from, to);
            }

            File.Move(Path, RotatedPath(1));
        }
        catch { }
    }

    private static string RotatedPath(int index) =>
        System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path) ?? LauncherCore.Root, $"launcher.{index}.log");

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

    /// <summary>
    /// Counts the error and warning lines of the current log, so the
    /// statistics screen can show at a glance whether the last session had
    /// problems.
    /// </summary>
    public static (int errors, int warnings, long bytes, DateTime modified) Summary()
    {
        try
        {
            var fi = new FileInfo(Path);
            if (!fi.Exists) return (0, 0, 0, DateTime.MinValue);

            var errors = 0;
            var warnings = 0;
            foreach (var line in File.ReadLines(Path))
            {
                if (line.Contains("[ERROR]")) errors++;
                else if (line.Contains("[WARN]")) warnings++;
            }
            return (errors, warnings, fi.Length, fi.LastWriteTime);
        }
        catch { return (0, 0, 0, DateTime.MinValue); }
    }

    /// <summary>Maps common exceptions to a user-friendly localized message.</summary>
    public static string FriendlyMessage(Exception ex, string? contextRu = null)
    {
        var prefix = string.IsNullOrWhiteSpace(contextRu) ? "" : contextRu.TrimEnd('.', ' ') + ". ";
        return ex switch
        {
            // A message that was written for the player is shown as it is.
            UserFacingException => prefix + ex.Message,
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
