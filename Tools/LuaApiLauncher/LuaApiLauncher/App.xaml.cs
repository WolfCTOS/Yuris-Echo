using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace LuaApiLauncher;

public partial class App : Application
{
    private static Mutex? _singleInstanceMutex;

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    private const int SW_RESTORE = 9;
    private const int SW_SHOW = 5;

    protected override void OnStartup(StartupEventArgs e)
    {
        LauncherLog.Init();
        HookGlobalExceptions();

        // Single instance: prevent concurrent config writes and double launches.
        var mutexName = @"Local\YurisEcho_Launcher_SingleInstance";
        _singleInstanceMutex = new Mutex(true, mutexName, out var createdNew);
        if (!createdNew)
        {
            LauncherLog.Info("Second instance detected; activating existing window and exiting.");
            TryActivateExistingWindow();
            Shutdown();
            return;
        }

        try
        {
            var audit = e.Args.Any(a => string.Equals(a, "--l10n-audit", StringComparison.OrdinalIgnoreCase))
                || string.Equals(System.Environment.GetEnvironmentVariable("L10N_AUDIT"), "1", StringComparison.Ordinal);
            if (audit) L10n.EnableAudit();

            // The language must be known before MainWindow is constructed so the
            // first rendered frame is already in the saved language.
            var cfg = LauncherCore.LoadConfig();
            L10n.SetLanguage(cfg.Language);
            UiSfx.Enabled = cfg.UiSoundsEnabled;
            UiSfx.Install();

            base.OnStartup(e);

            var window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Fatal error during startup", ex);
            ShowFatal(ex, L10n.T("Не удалось запустить лаунчер."));
            Shutdown(-1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { _singleInstanceMutex?.ReleaseMutex(); } catch { }
        _singleInstanceMutex?.Dispose();
        _singleInstanceMutex = null;
        base.OnExit(e);
    }

    private void HookGlobalExceptions()
    {
        DispatcherUnhandledException += (_, args) =>
        {
            LauncherLog.Error("Unhandled UI exception", args.Exception);
            args.Handled = true;
            ShowFatal(args.Exception, L10n.T("Произошла непредвиденная ошибка."));
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            LauncherLog.Error("Unhandled domain exception", args.ExceptionObject as Exception);
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            LauncherLog.Error("Unobserved task exception", args.Exception);
            args.SetObserved();
        };
    }

    private void ShowFatal(Exception ex, string userMessage)
    {
        try
        {
            var body = LauncherLog.FriendlyMessage(ex, userMessage) + "\n\n" + L10n.T("Журнал: ") + LauncherLog.Path;
            var result = MessageBox.Show(body + "\n\n" + L10n.T("Открыть журнал сейчас?"),
                "Yuri's Echo", MessageBoxButton.YesNo, MessageBoxImage.Error);
            if (result == MessageBoxResult.Yes) LauncherLog.TryOpen();
        }
        catch
        {
            try { MessageBox.Show(ex.ToString(), "Yuri's Echo - fatal error", MessageBoxButton.OK, MessageBoxImage.Error); } catch { }
        }
    }

    private static void TryActivateExistingWindow()
    {
        try
        {
            var currentPid = (uint)Environment.ProcessId;
            EnumWindows((hWnd, _) =>
            {
                GetWindowThreadProcessId(hWnd, out var pid);
                if (pid == currentPid) return true;
                var sb = new StringBuilder(512);
                GetWindowText(hWnd, sb, sb.Capacity);
                var title = sb.ToString();
                if (!title.StartsWith("Yuri's Echo", StringComparison.OrdinalIgnoreCase) &&
                    !title.StartsWith("YURI'S ECHO", StringComparison.OrdinalIgnoreCase))
                    return true;
                if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE); else ShowWindow(hWnd, SW_SHOW);
                SetForegroundWindow(hWnd);
                return false;
            }, IntPtr.Zero);
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Failed to activate existing launcher window", ex);
        }
    }
}
