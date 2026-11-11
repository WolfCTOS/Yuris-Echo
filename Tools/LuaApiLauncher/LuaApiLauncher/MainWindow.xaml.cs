using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LuaApiLauncher;

public partial class MainWindow : Window
{
    private LauncherConfig _cfg = new();
    private List<ModInfo> _mods = new();
    private List<MapEntry> _maps = new();
    private List<CampaignSide> _campaignSides = new();
    private HashSet<string> _active = new(StringComparer.Ordinal);

    /// <summary>Exposed to the separate mod manager window.</summary>
    internal List<ModInfo> Mods => _mods;
    /// <summary>Exposed to the separate mod manager window.</summary>
    internal HashSet<string> ActiveMods => _active;

    /// <summary>Refreshes UI after the active mod set changed elsewhere (e.g. mod manager).</summary>
    internal void UpdateModsUi()
    {
        UpdateMainStatus();
        if (SkirmishModsPanel != null) BuildModsPanel();
        UpdateModsCounter();
    }

    /// <summary>Saves the active mod set and refreshes the Mods tab UI.</summary>
    internal void SaveAndRefreshMods()
    {
        PersistActive();
        UpdateModsUi();
    }

    internal string ModsDir() => LauncherCore.ModsDir;
    private string _mapFilter = "";
    private bool _syncing;

    public MainWindow()
    {
        InitializeComponent();
        Width = Theme.WindowWidth; Height = Theme.WindowHeight;
        Loaded += (_, _) => Init();
    }

    private bool _fullscreenClient;

    private string GetBuildMarker()
    {
        try
        {
            var dllPath = Path.Combine(AppContext.BaseDirectory, "YurisEcho.dll");
            if (!File.Exists(dllPath))
                dllPath = System.Reflection.Assembly.GetExecutingAssembly().Location;
            if (string.IsNullOrWhiteSpace(dllPath) || !File.Exists(dllPath))
                dllPath = Environment.ProcessPath ?? "";

            var t = !string.IsNullOrWhiteSpace(dllPath) && File.Exists(dllPath)
                ? File.GetLastWriteTime(dllPath)
                : DateTime.Now;
            var hash = "????????";
            if (!string.IsNullOrWhiteSpace(dllPath) && File.Exists(dllPath))
            {
                using var sha = System.Security.Cryptography.SHA256.Create();
                using var fs = File.OpenRead(dllPath);
                hash = Convert.ToHexString(sha.ComputeHash(fs)).Substring(0, 8).ToLowerInvariant();
            }
            return "build " + t.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " | dll " + hash;
        }
        catch { return "build unknown"; }
    }

    private void Init()
    {
        var marker = GetBuildMarker();
        Title = $"Yuri's Echo  [{marker}]";
        LauncherLog.Info("Launcher window initializing. " + marker);
        try
        {
            SetupBackground();
            ReloadState();
            L10n.Apply(this);
            ApplyClientWindowMode();
            if (SkirmishBuildMarker != null) SkirmishBuildMarker.Text = marker;
            if (MainBuildMarker != null) MainBuildMarker.Text = marker;
            ShowMain();
            WarnIfNotInGameRoot();
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Init failed", ex);
            ShowError(L10n.T("Не удалось инициализировать лаунчер."), ex);
        }
    }

    /// <summary>
    /// "Fullscreen client" makes the launcher itself borderless and screen-sized;
    /// unchecked keeps the normal window fitted to the available work area.
    /// </summary>
    private void ApplyClientWindowMode()
    {
        var s = LauncherCore.LoadClientSettingsSafe(ClientIni);
        WindowState = WindowState.Normal;
        Topmost = false;
        _fullscreenClient = s.BorderlessClient;
        if (_fullscreenClient)
        {
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = SystemParameters.VirtualScreenLeft;
            Top = SystemParameters.VirtualScreenTop;
            Width = SystemParameters.PrimaryScreenWidth;
            Height = SystemParameters.PrimaryScreenHeight;
            if (RootViewbox != null) RootViewbox.Stretch = Stretch.Uniform;
            if (RootViewbox != null) RootViewbox.StretchDirection = StretchDirection.Both;
            if (RootLayout != null) { RootLayout.Width = Theme.WindowWidth; RootLayout.Height = Theme.WindowHeight; }
            TitleRow.Height = new GridLength(0);
            TitleBar.Visibility = Visibility.Collapsed;
        }
        else
        {
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            TitleRow.Height = new GridLength(Theme.TitleBarHeight);
            TitleBar.Visibility = Visibility.Visible;
            FitToWorkArea();
        }
    }

    /// <summary>Fits the fixed 1280x720 design into the current work area (P0: no clipping on small/high-DPI screens).</summary>
    private void FitToWorkArea()
    {
        var wa = SystemParameters.WorkArea;
        var designW = Theme.WindowWidth;
        var designH = Theme.WindowHeight;
        var scale = Math.Min(wa.Width / designW, wa.Height / designH);
        if (scale <= 0 || double.IsNaN(scale) || double.IsInfinity(scale)) scale = 1.0;
        // Allow upscale on large displays so the client can fill space when requested, but always fit work area.
        var targetW = Math.Min(wa.Width, designW * scale);
        var targetH = Math.Min(wa.Height, designH * scale);
        // If work area is larger than design, keep 1:1 and center; if smaller, scale down to fit.
        if (wa.Width >= designW && wa.Height >= designH)
        {
            targetW = designW;
            targetH = designH;
        }
        else
        {
            var s = Math.Min(wa.Width / designW, wa.Height / designH);
            targetW = Math.Floor(designW * s);
            targetH = Math.Floor(designH * s);
        }
        if (RootLayout != null) { RootLayout.Width = designW; RootLayout.Height = designH; }
        if (RootViewbox != null) { RootViewbox.Stretch = Stretch.Uniform; RootViewbox.StretchDirection = StretchDirection.Both; }
        Width = Math.Max(640, targetW);
        Height = Math.Max(360, targetH);
        Left = wa.Left + (wa.Width - Width) / 2;
        Top = wa.Top + (wa.Height - Height) / 2;
        WindowStartupLocation = WindowStartupLocation.Manual;
    }

    private void WarnIfNotInGameRoot()
    {
        try
        {
            var (ok, missing) = LauncherCore.CheckGameRoot();
            if (!ok)
            {
                ShowNotice(L10n.T("Установка"), L10n.F("Лаунчер, похоже, запущен не из папки игры. Не найдены: {0}. Поместите лаунчер в корень игры.", missing), showOpenLog: false);
            }
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Game root check failed", ex);
        }
    }

    private void ReloadState()
    {
        _mods = LauncherCore.ScanMods();
        _cfg = LauncherCore.LoadConfig(_mods);
        _active = LauncherCore.ReadActiveIds(_mods);
    }

    // ---------------------------------------------------------------- background

    private void SetupBackground()
    {
        string[] names = ["background.png", "background.jpg", "background.jpeg", "bg.png", "bg.jpg"];
        foreach (var n in names)
        {
            var p = Path.Combine(LauncherCore.Root, n);
            if (!File.Exists(p)) continue;
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit(); bmp.UriSource = new Uri(p, UriKind.Absolute); bmp.CacheOption = BitmapCacheOption.OnLoad; bmp.EndInit(); bmp.Freeze();
                BgImage.Source = bmp; BgImage.Visibility = Visibility.Visible;
                BgGradient.Visibility = Visibility.Collapsed;
            }
            catch { }
            break;
        }

        if (BgImage.Visibility != Visibility.Visible)
        {
            BgGradient.Fill = new LinearGradientBrush(Theme.BgGradientTop, Theme.WindowBg, 90);
            var noise = new ImageBrush(MakeNoise(256, 256))
            {
                TileMode = TileMode.Tile,
                Viewport = new Rect(0, 0, 256, 256),
                ViewportUnits = BrushMappingMode.Absolute,
                Stretch = Stretch.None
            };
            noise.Freeze();
            BgNoise.Fill = noise;
        }

        BgOverlay.Fill = new SolidColorBrush(Theme.Overlay45);
        BgVignette.Fill = new RadialGradientBrush(
            Color.FromArgb(0, 0, 0, 0),
            Color.FromArgb(153, 11, 15, 20))
        { GradientOrigin = new Point(0.5, 0.5), Center = new Point(0.5, 0.5), RadiusX = 0.75, RadiusY = 0.75 };
    }

    private static ImageSource MakeNoise(int w, int h)
    {
        var rnd = new Random(1337);
        var pixels = new byte[w * h * 4];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            byte v = (byte)rnd.Next(0, 256);
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 255;
        }
        var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, pixels, w * 4);
        bmp.Freeze();
        return bmp;
    }

    // ---------------------------------------------------------------- title bar

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.LeftButton == MouseButtonState.Pressed) DragMove(); }
    private void MinBtn_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void CloseBtn_Click(object sender, RoutedEventArgs e) => Close();

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        if (NoticeOverlay.Visibility == Visibility.Visible) { NoticeOverlay.Visibility = Visibility.Collapsed; return; }
        if (OptionsView.Visibility == Visibility.Visible) { TryLeaveOptions(); return; }
        if (SkirmishView.Visibility == Visibility.Visible || StatsView.Visibility == Visibility.Visible || CompanyView.Visibility == Visibility.Visible)
            ShowMain();
    }

    private bool HasUnsavedOptions() =>
        !string.Equals(CaptureOptionsSnapshot(), _savedOptionsSnapshot, StringComparison.Ordinal);

    private void TryLeaveOptions()
    {
        if (HasUnsavedOptions())
        {
            var res = System.Windows.MessageBox.Show(this, L10n.T("Отменить изменения?"), L10n.T("Настройки"), System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question);
            if (res != System.Windows.MessageBoxResult.Yes) return;
        }
        ShowMain();
    }

    // ---------------------------------------------------------------- navigation

    private void ShowOnly(UIElement view)
    {
        MainView.Visibility = Visibility.Collapsed;
        SkirmishView.Visibility = Visibility.Collapsed;
        OptionsView.Visibility = Visibility.Collapsed;
        StatsView.Visibility = Visibility.Collapsed;
        CompanyView.Visibility = Visibility.Collapsed;
        view.Visibility = Visibility.Visible;

        // Keep the main menu background image clear; dim it on other screens for readability.
        var isMain = ReferenceEquals(view, MainView);
        if (BgOverlay != null) BgOverlay.Opacity = isMain ? 0 : 1;
        if (BgVignette != null) BgVignette.Opacity = isMain ? 0 : 1;
    }

    private void ShowMain()
    {
        ShowOnly(MainView);
        ReloadState();
        UpdateMainStatus();
        UpdateLayout();
        L10n.Apply(this);
    }

    private void ShowSkirmish()
    {
        ShowOnly(SkirmishView);
        LauncherCore.EnsureSkirmishDefaults(_cfg.Skirmish);

        _mapCatalog = MapCatalog.Load();
        _currentMapMode = _mapCatalog.ResolveMode(_cfg.Skirmish.SelectedMode, _cfg.Skirmish.SelectedMap);
        _cfg.Skirmish.SelectedMode = _currentMapMode;

        _syncing = true;
        BuildMapModeCombo();
        RefreshMaps();
        BuildPlayerTable();
        BuildSettingsPanel();
        BuildPresetCombo();
        ChkShowDevMods.IsChecked = _cfg.Skirmish.ShowDevMods;
        BuildModsPanel();
        SkirmishTabs.SelectedIndex = Math.Clamp(_cfg.Skirmish.ActiveTab, 0, 1);
        _syncing = false;

        if (!_mapCatalog.ModeContains(_currentMapMode, _cfg.Skirmish.SelectedMap))
        {
            // Saved map not in saved mode -> switch to All maps.
            _currentMapMode = MapCatalog.AllMapsMode;
            _cfg.Skirmish.SelectedMode = _currentMapMode;
            var all = CmbMapMode?.Items.OfType<MapModeItem>().FirstOrDefault(i => i.Key == MapCatalog.AllMapsMode);
            _syncing = true;
            if (all != null && CmbMapMode != null) CmbMapMode.SelectedItem = all;
            _syncing = false;
            RefreshMaps();
        }

        SaveSkirmishState();
        UpdateSkirmishStatus();
        UpdateLayout();
        L10n.Apply(this);
        UpdateModsCounter();
        UpdateStartButtonState();
    }

    private void SkirmishTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || SkirmishTabs == null) return;
        _cfg.Skirmish.ActiveTab = Math.Max(0, SkirmishTabs.SelectedIndex);
        SaveSkirmishState();
    }

    private void ShowOptions()
    {
        ShowOnly(OptionsView);
        ReloadState();
        BuildOptions();

        _suppressDirty = true;
        var settings = LauncherCore.LoadClientSettingsSafe(ClientIni);
        CmbGameRes.Text = settings.GameResX + "x" + settings.GameResY;
        CmbClientRes.Text = settings.ResolutionX + "x" + settings.ResolutionY;
        CmbDetail.SelectedIndex = Math.Clamp(settings.DetailLevel, 0, 2);
        CmbDifficulty.SelectedIndex = Math.Clamp(settings.Difficulty, 0, 2);
        CmbGameSpeed.SelectedItem = settings.GameSpeed;
        if (CmbGameSpeed.SelectedItem == null) CmbGameSpeed.SelectedIndex = 0;
        SelectKey(CmbRenderer, settings.Renderer);
        SelectKey(CmbLanguage, L10n.Normalize(_cfg.Language));
        ChkBorderless.IsChecked = settings.BorderlessClient;
        ChkInteger.IsChecked = settings.IntegerScaling;
        ChkBackBuffer.IsChecked = settings.BackBuffer;
        ChkTooltips.IsChecked = settings.ToolTips;
        ChkQuickExit.IsChecked = settings.QuickExit;
        ChkChat.IsChecked = settings.AllowChat;
        ChkSkipScore.IsChecked = settings.SkipScoreScreen;
        ChkReplays.IsChecked = settings.RecordReplays;
        ChkPrioritySel.IsChecked = settings.PrioritySelectionFiltering;
        ChkPowerDelta.IsChecked = settings.ShowPowerDelta;
        ChkHarvCounter.IsChecked = settings.ShowHarvesterCounter;
        ChkPlacement.IsChecked = settings.ShowPlacementPreview;
        SetVolume(SlClientVol, TxtClientVol, settings.ClientVolume);
        SetVolume(SlSoundVol, TxtSoundVol, settings.SoundVolume);
        SetVolume(SlVoiceVol, TxtVoiceVol, settings.VoiceVolume);
        SetVolume(SlScoreVol, TxtScoreVol, settings.ScoreVolume);
        ChkTaunts.IsChecked = settings.AllowTaunts;
        if (ChkUiSounds != null) ChkUiSounds.IsChecked = _cfg.UiSoundsEnabled;

        ApplyWindowModeToUi(DetectWindowMode(settings));

        CfgSyr.Text = _cfg.Syringe;
        CfgSyrArgs.Text = string.Join(' ', _cfg.SyringeArgs);
        CfgGame.Text = _cfg.Gamemd;
        BuildExtras();
        SwitchTab(0);
        UpdateLayout();
        L10n.Apply(this);
        AttachDirtyHandlersOnce();
        _suppressDirty = false;
        _savedOptionsSnapshot = CaptureOptionsSnapshot();
        if (TxtUnsaved != null) TxtUnsaved.Visibility = Visibility.Collapsed;
    }

    private bool _dirtyHandlersAttached;
    private void AttachDirtyHandlersOnce()
    {
        if (_dirtyHandlersAttached) return;
        _dirtyHandlersAttached = true;
        AttachDirtyHandlers();
    }

    private enum WindowMode { Fullscreen, Windowed, Borderless }

    private static WindowMode DetectWindowMode(ClientSettings s)
    {
        if (s.BorderlessClient) return WindowMode.Fullscreen;
        if (s.WindowedMode && s.BorderlessFrame) return WindowMode.Borderless;
        if (s.WindowedMode) return WindowMode.Windowed;
        return WindowMode.Fullscreen;
    }

    private void ApplyWindowModeToUi(WindowMode mode)
    {
        ChkWindowed.IsChecked = mode != WindowMode.Fullscreen;
        ChkBorderlessFrame.IsChecked = mode == WindowMode.Borderless;
        ChkBorderless.IsChecked = mode == WindowMode.Fullscreen;
        if (ChkBorderlessFrame != null) ChkBorderlessFrame.IsEnabled = mode != WindowMode.Fullscreen;

        if (BtnModeFullscreen != null) BtnModeFullscreen.IsChecked = mode == WindowMode.Fullscreen;
        if (BtnModeWindowed != null) BtnModeWindowed.IsChecked = mode == WindowMode.Windowed;
        if (BtnModeBorderless != null) BtnModeBorderless.IsChecked = mode == WindowMode.Borderless;
    }

    private void DisplayModeSegment_Checked(object sender, RoutedEventArgs e)
    {
        if (_suppressDirty) return;
        var mode = sender == BtnModeBorderless ? WindowMode.Borderless
            : sender == BtnModeWindowed ? WindowMode.Windowed
            : WindowMode.Fullscreen;
        _suppressDirty = true;
        ApplyWindowModeToUi(mode);
        _suppressDirty = false;

        // The CnCNet client only enters true fullscreen when the client
        // resolution equals the desktop resolution (see GameClass.SetGraphicsMode).
        if (mode == WindowMode.Fullscreen)
        {
            var desktop = DisplayInfo.DesktopResolution();
            if (desktop.Width >= 640) CmbClientRes.Text = desktop.ToString();
        }
        UpdateDirtyIndicator();
    }

    /// <summary>Kept for compatibility with any old XAML; segment buttons are the UI now.</summary>
    private void WindowMode_Click(object sender, RoutedEventArgs e) { }

    private string CaptureOptionsSnapshot()
    {
        try
        {
            var lang = CmbLanguage?.SelectedItem is System.Collections.Generic.KeyValuePair<string, string> kv ? L10n.Normalize(kv.Key) : L10n.English;
            var mode = DetectWindowMode(new ClientSettings
            {
                BorderlessClient = ChkBorderless?.IsChecked == true,
                WindowedMode = ChkWindowed?.IsChecked == true,
                BorderlessFrame = ChkBorderlessFrame?.IsChecked == true
            });
            return string.Join("|",
                CmbGameRes?.Text ?? "", CmbClientRes?.Text ?? "", CmbDetail?.SelectedIndex ?? -1,
                CmbDifficulty?.SelectedIndex ?? -1, CmbGameSpeed?.SelectedItem?.ToString() ?? "",
                (CmbRenderer?.SelectedItem is System.Collections.Generic.KeyValuePair<string, string> r ? r.Key : ""),
                lang,
                mode.ToString(),
                ChkInteger?.IsChecked == true, ChkBackBuffer?.IsChecked == true,
                TxtScoreVol?.Text ?? "", TxtSoundVol?.Text ?? "", TxtVoiceVol?.Text ?? "", TxtClientVol?.Text ?? "",
                ChkTaunts?.IsChecked == true,
                ChkUiSounds?.IsChecked == true,
                ChkQuickExit?.IsChecked == true, ChkTooltips?.IsChecked == true, ChkChat?.IsChecked == true,
                ChkSkipScore?.IsChecked == true, ChkReplays?.IsChecked == true, ChkPrioritySel?.IsChecked == true,
                ChkPowerDelta?.IsChecked == true, ChkHarvCounter?.IsChecked == true, ChkPlacement?.IsChecked == true,
                CfgSyr?.Text ?? "", CfgSyrArgs?.Text ?? "", CfgGame?.Text ?? "",
                CmbUpdateChannel?.SelectedItem?.ToString() ?? "");
        }
        catch { return _savedOptionsSnapshot; }
    }

    private void UpdateDirtyIndicator()
    {
        if (_suppressDirty) return;
        var dirty = !string.Equals(CaptureOptionsSnapshot(), _savedOptionsSnapshot, StringComparison.Ordinal);
        if (TxtUnsaved != null) TxtUnsaved.Visibility = dirty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AttachDirtyHandlers()
    {
        void T(System.Windows.Controls.Primitives.TextBoxBase b) { b.TextChanged += (_, __) => UpdateDirtyIndicator(); }
        void C(System.Windows.Controls.Primitives.ToggleButton b) { b.Checked += (_, __) => UpdateDirtyIndicator(); b.Unchecked += (_, __) => UpdateDirtyIndicator(); }
        void Sel(System.Windows.Controls.Primitives.Selector s) { s.SelectionChanged += (_, __) => UpdateDirtyIndicator(); }
        void Combo(System.Windows.Controls.ComboBox cb) { cb.SelectionChanged += (_, __) => UpdateDirtyIndicator(); if (cb.IsEditable) cb.AddHandler(System.Windows.Controls.Primitives.TextBoxBase.TextChangedEvent, new System.Windows.Controls.TextChangedEventHandler((_, __) => UpdateDirtyIndicator())); }

        if (CmbGameRes != null) Combo(CmbGameRes);
        if (CmbClientRes != null) Combo(CmbClientRes);
        if (CmbDetail != null) Sel(CmbDetail);
        if (CmbDifficulty != null) Sel(CmbDifficulty);
        if (CmbGameSpeed != null) Sel(CmbGameSpeed);
        if (CmbRenderer != null) Sel(CmbRenderer);
        if (CmbLanguage != null) Sel(CmbLanguage);
        if (CmbUpdateChannel != null) Sel(CmbUpdateChannel);
        foreach (var cb in new[]{ChkBackBuffer,ChkInteger,ChkTaunts,ChkQuickExit,ChkTooltips,ChkChat,ChkSkipScore,ChkReplays,ChkPrioritySel,ChkPowerDelta,ChkHarvCounter,ChkPlacement})
            if (cb != null) C(cb);
        foreach (var tb in new[]{CfgSyr,CfgSyrArgs,CfgGame})
            if (tb != null) T(tb);
        // volume sliders/boxes already change; hook boxes too
        foreach (var tb in new[]{TxtScoreVol,TxtSoundVol,TxtVoiceVol,TxtClientVol})
            if (tb != null) T(tb);
    }

    private void BtnCfgReset_Click(object sender, RoutedEventArgs e)
    {
        var body = L10n.T("Сбросить настройки этого экрана к значениям по умолчанию?");
        var result = System.Windows.MessageBox.Show(this, body, L10n.T("Сбросить по умолчанию"), System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question);
        if (result != System.Windows.MessageBoxResult.Yes) return;
        _suppressDirty = true;
        try
        {
            // Defaults aligned with typical client defaults; only UI fields.
            CmbDetail.SelectedIndex = 2;
            CmbDifficulty.SelectedIndex = 1;
            CmbGameSpeed.SelectedIndex = 5; // 6
            if (CmbRenderer.Items.Count > 0) CmbRenderer.SelectedIndex = 0;
            var langIdx = 0;
            for (int i=0;i<CmbLanguage.Items.Count;i++) if (CmbLanguage.Items[i] is System.Collections.Generic.KeyValuePair<string,string> kv && L10n.Normalize(kv.Key)==L10n.English) { langIdx=i; break; }
            if (CmbLanguage.Items.Count>0) CmbLanguage.SelectedIndex = langIdx;
            ApplyWindowModeToUi(WindowMode.Fullscreen);
            var desktop = DisplayInfo.DesktopResolution();
            if (desktop.Width >= 640) { CmbGameRes.Text = desktop.ToString(); CmbClientRes.Text = desktop.ToString(); }
            ChkInteger.IsChecked = false;
            ChkBackBuffer.IsChecked = false;
            SetVolume(SlScoreVol, TxtScoreVol, 0.5);
            SetVolume(SlSoundVol, TxtSoundVol, 0.5);
            SetVolume(SlVoiceVol, TxtVoiceVol, 0.5);
            SetVolume(SlClientVol, TxtClientVol, 0.5);
            ChkTaunts.IsChecked = false;
            if (ChkUiSounds != null) ChkUiSounds.IsChecked = true;
            ChkQuickExit.IsChecked = false;
            ChkTooltips.IsChecked = true;
            ChkChat.IsChecked = true;
            ChkSkipScore.IsChecked = false;
            ChkReplays.IsChecked = false;
            ChkPrioritySel.IsChecked = false;
            ChkPowerDelta.IsChecked = true;
            ChkHarvCounter.IsChecked = true;
            ChkPlacement.IsChecked = true;
        }
        finally { _suppressDirty = false; }
        UpdateDirtyIndicator();
    }

    private void SwitchTab(int index)
    {
        if (TabVideoSound != null) TabVideoSound.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (TabGame != null) TabGame.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        if (TabStorage != null) TabStorage.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        if (TabUpdates != null) TabUpdates.Visibility = index == 3 ? Visibility.Visible : Visibility.Collapsed;
        if (TabComponents != null) TabComponents.Visibility = index == 4 ? Visibility.Visible : Visibility.Collapsed;

        Button[] tabs = [TabVideoSoundBtn, TabGameBtn, TabStorageBtn, TabUpdatesBtn, TabComponentsBtn];
        for (var i = 0; i < tabs.Length; i++)
        {
            tabs[i].Foreground = i == index ? Theme.AccentB : Theme.TextSecondaryB;
            tabs[i].BorderBrush = i == index ? Theme.AccentB : Theme.StrokeB;
            tabs[i].Background = i == index
                ? new SolidColorBrush(Color.FromArgb(0x22, 0xFF, 0xFF, 0xFF))
                : Theme.ButtonFillB;
        }
    }

    private void TabVideoSound_Click(object sender, RoutedEventArgs e) => SwitchTab(0);
    private void TabGame_Click(object sender, RoutedEventArgs e) => SwitchTab(1);
    private void TabStorage_Click(object sender, RoutedEventArgs e) => SwitchTab(2);
    private void TabUpdates_Click(object sender, RoutedEventArgs e) => SwitchTab(3);
    private void TabComponents_Click(object sender, RoutedEventArgs e) => SwitchTab(4);

    private void BtnOpenRoot_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(LauncherCore.Root)
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex) { ShowError(L10n.T("Не удалось открыть папку."), ex); }
    }

    private void BtnSupport_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(LauncherExtras.SupportUrl)
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex) { ShowError(L10n.T("Не удалось открыть ссылку."), ex); }
    }

    private string _channelNow = "Live";

    /// <summary>Storage sizes, update channel and component list are re-read every time options open.</summary>
    private void BuildExtras()
    {
        if (CmbUpdateChannel.Items.Count == 0)
            CmbUpdateChannel.ItemsSource = LauncherExtras.Channels;

        _channelNow = LauncherExtras.DetectChannel();
        CmbUpdateChannel.SelectedItem = _channelNow;
        TxtChannelNow.Text = CmbUpdateChannel.SelectedItem == null
            ? L10n.T("updateconfig.ini указывает на канал, которого нет в Resources/Config.")
            : L10n.F("Сейчас: {0}. Смена канала перезаписывает updateconfig.ini (как в клиенте) и требует перезапуска.", _channelNow);

        ComponentsList.ItemsSource = LauncherExtras.ScanComponents();
        ComponentsList.DisplayMemberPath = "Display";

        // Storage scan can be slow (walks the whole game folder); compute after UI opens.
        TxtStorage.Text = "...";
        TxtStorageDisk.Text = "...";
        Dispatcher.BeginInvoke(new Action(() =>
        {
            try
            {
                var storage = LauncherExtras.StorageReport();
                var disk = LauncherExtras.DiskReport();
                TxtStorage.Text = storage;
                TxtStorageDisk.Text = disk;
            }
            catch { }
        }), System.Windows.Threading.DispatcherPriority.Background);
    }

    private static string ClientIni => Path.Combine(LauncherCore.Root, "RA2MD.INI");

    private void BuildOptions()
    {
        // The mode list comes from the active display, never from a fixed table.
        var resolutions = DisplayInfo.SupportedResolutions().Select(r => r.ToString()).ToList();
        CmbGameRes.ItemsSource = resolutions;
        CmbClientRes.ItemsSource = resolutions;

        CmbDetail.ItemsSource = new[] { L10n.T("Низкая"), L10n.T("Средняя"), L10n.T("Высокая") };
        CmbDifficulty.ItemsSource = new[] { L10n.T("Легко"), L10n.T("Нормально"), L10n.T("Сложно") };
        CmbGameSpeed.ItemsSource = new[] { 1, 2, 3, 4, 5, 6 };
        CmbRenderer.ItemsSource = LauncherCore.ScanRenderers();
        CmbLanguage.ItemsSource = LauncherCore.ScanLanguages();
    }

    private static void SelectKey(ComboBox cb, string key)
    {
        foreach (var item in cb.Items)
            if (item is KeyValuePair<string, string> kv && kv.Key == key) { cb.SelectedItem = item; return; }
        if (cb.Items.Count > 0) cb.SelectedIndex = 0;
    }

    private void ShowStats()
    {
        ShowOnly(StatsView);
        ReloadState();
        _maps = LauncherCore.ScanMaps();
        BuildStatsCards();
        UpdateLayout();
        L10n.Apply(this);
    }

    private void AddStatCard(string title, IEnumerable<(string label, string value)> rows)
    {
        if (StatsCards == null) return;
        var border = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xCC, 0x11, 0x15, 0x1D)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x34, 0x3A, 0x47)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14),
            Margin = new Thickness(0, 0, 12, 12),
            MinWidth = 300,
            MaxWidth = 520
        };
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, FontSize = 11, Foreground = new SolidColorBrush(Color.FromRgb(0xB8, 0xBD, 0xC8)), Margin = new Thickness(0,0,0,10) });
        foreach (var (label, value) in rows)
        {
            var row = new Grid { Margin = new Thickness(0,0,0,6) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var l = new TextBlock { Text = label, Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0xA0, 0xAC)), FontSize = 12, TextWrapping = TextWrapping.Wrap };
            var v = new TextBlock { Text = value, Foreground = new SolidColorBrush(Color.FromRgb(0xE6, 0xE8, 0xEC)), FontSize = 12, TextWrapping = TextWrapping.Wrap };
            Grid.SetColumn(v, 1);
            row.Children.Add(l); row.Children.Add(v);
            stack.Children.Add(row);
        }
        border.Child = stack;
        StatsCards.Children.Add(border);
    }

    private void BuildStatsCards()
    {
        if (StatsCards == null) return;
        StatsCards.Children.Clear();
        string YesNo(bool value) => L10n.T(value ? "есть" : "нет");
        var luaLog = System.IO.Path.Combine(LauncherCore.Root, "LuaAPI.log");

        AddStatCard(L10n.T("УСТАНОВКА"), new (string,string)[] {
            (L10n.T("путь"), LauncherCore.Root),
            ("gamemd", YesNo(LauncherCore.Exists(_cfg.Gamemd))),
            ("Syringe", YesNo(LauncherCore.Exists(_cfg.Syringe))),
            ("Ares", YesNo(LauncherCore.Exists("Ares.dll"))),
            ("Phobos", YesNo(LauncherCore.Exists("Phobos.dll"))),
            ("LuaAPI", YesNo(LauncherCore.Exists("LuaAPI.dll"))),
        });

        var modList = _mods.Count == 0 ? L10n.T("Модов нет.") : string.Join(", ", _mods.Select(m => m.Name + (_active.Contains(m.Id) ? "*" : "")));
        AddStatCard(L10n.T("МОДЫ"), new (string,string)[] {
            (L10n.T("найдено"), _mods.Count.ToString()),
            (L10n.T("активно"), _active.Count.ToString()),
            (L10n.T("файлов"), $"lua {_mods.Sum(m => m.LuaFiles.Count)}, json {_mods.Sum(m => m.JsonFiles.Count)}"),
            (L10n.T("список"), modList),
        });

        AddStatCard(L10n.T("КАРТЫ"), new (string,string)[] {
            (L10n.T("найдено"), _maps.Count.ToString()),
        });

        AddStatCard("CNCNET", new (string,string)[] {
            ("online", "N/A"),
            (L10n.T("статус"), L10n.T("разработка мультиплеера ещё не начата")),
        });

        var luaRows = new System.Collections.Generic.List<(string,string)>();
        if (System.IO.File.Exists(luaLog))
        {
            var fi = new System.IO.FileInfo(luaLog);
            luaRows.Add((L10n.T("изменён"), fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")));
            luaRows.Add((L10n.T("размер"), LauncherCore.FormatSize(fi.Length)));
        }
        else luaRows.Add((L10n.T("статус"), L10n.T("нет файла")));
        AddStatCard("LUAAPI.LOG", luaRows);
    }

    private void UpdateMainStatus()
    {
        var (gOk, gMiss) = LauncherCore.CheckExe(_cfg.Gamemd);
        var (sOk, sMiss) = LauncherCore.CheckExe(_cfg.Syringe);

        BtnSkirmish.IsActionEnabled = gOk; BtnSkirmish.DisabledReason = gMiss ?? "";
        BtnCampaign.IsActionEnabled = gOk; BtnCampaign.DisabledReason = gMiss ?? "";

        var editor = LauncherCore.FindMapEditor();
        BtnMapEditor.IsActionEnabled = editor != null;
        BtnMapEditor.DisabledReason = L10n.T("Редактор карт не найден");

        BtnCampaign.ToolTip = L10n.T("Выберите миссию кампании; сложность берётся из опций.");
        BtnCncNet.ToolTip = L10n.T("Открывает клиент CnCNet (онлайн и LAN).");

        var ready = L10n.T("ГОТОВ");
        var missing = L10n.T("НЕТ");
        OnlineStatus.Text = "N/A";

        StatusLine.Text = L10n.F("Будет загружено модов: {0}", ActiveModCount());
    }

    // ---------------------------------------------------------------- main menu actions

    private void BtnSkirmish_Click(object sender, EventArgs e) => ShowSkirmish();
    private void BtnOptions_Click(object sender, EventArgs e) => ShowOptions();
    private void BtnStats_Click(object sender, EventArgs e) => ShowStats();
    private void BtnExit_Click(object sender, EventArgs e) => Close();

    private void BtnCncNet_Click(object sender, EventArgs e) => LaunchCncNetClient();

    private void LaunchCncNetClient()
    {
        var (ok, _) = LauncherCore.CheckExe(_cfg.CncNet);
        if (!ok)
        {
            ShowNotice(L10n.T("CNCNET"), L10n.F("Клиент CnCNet не найден: {0}", _cfg.CncNet));
            return;
        }
        try { LauncherCore.Launch(_cfg.CncNet); }
        catch (Exception ex) { ShowError(L10n.T("Не удалось запустить клиент CnCNet."), ex); }
    }

    private void BtnCampaign_Click(object sender, EventArgs e) => ShowCompanySelect();

    private void ShowCompanySelect()
    {
        ShowOnly(CompanyView);
        ReloadState();
        _campaignSides = CampaignData.LoadSides();
        BuildCampaignSideTabs();

        if (_campaignSides.Count > 0)
        {
            CompanyStatus.Text = L10n.T("Выберите миссию из списка.");

            // Prefer Allies by default (like before), else the first available side.
            var allies = _campaignSides.FirstOrDefault(s =>
                s.Items.OfType<CampaignMission>().Any(m => m.SideName.Equals("Allied", StringComparison.OrdinalIgnoreCase)));
            SelectCampaignSide(allies ?? _campaignSides[0]);
        }
        else
        {
            MissionList.ItemsSource = null;
            ShowMissionDetails(null);
            CompanyStatus.Text = L10n.T("Список кампаний пуст: не найден INI\\Battle.ini или в нём нет миссий.");
        }

        UpdateLayout();
        L10n.Apply(this);
    }

    /// <summary>
    /// Small side tabs (Boot Camp / Allied / Soviet). They replace the old
    /// dropdown so each campaign side keeps its own mission list.
    /// </summary>
    private void BuildCampaignSideTabs()
    {
        CampaignSideTabs.Children.Clear();
        foreach (var side in _campaignSides)
        {
            var tab = new RadioButton
            {
                Content = side.Title,
                Tag = side,
                GroupName = "CampaignSide",
                Style = (Style)FindResource("SideTab"),
            };
            tab.Checked += CampaignSideTab_Checked;
            CampaignSideTabs.Children.Add(tab);
        }
    }

    private void SelectCampaignSide(CampaignSide side)
    {
        foreach (var child in CampaignSideTabs.Children)
        {
            if (child is RadioButton { Tag: CampaignSide tagged } tab && ReferenceEquals(tagged, side))
            {
                tab.IsChecked = true;
                return;
            }
        }

        // No matching tab (should not happen): show the side directly.
        MissionList.ItemsSource = side.Items;
        SelectFirstMission();
    }

    private void CampaignSideTab_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton { Tag: CampaignSide side }) return;
        MissionList.ItemsSource = side.Items;
        SelectFirstMission();
    }

    private void SelectFirstMission()
    {
        if (MissionList.ItemsSource is not IEnumerable<object> items) return;
        var i = 0;
        foreach (var item in items)
        {
            if (item is CampaignMission) { MissionList.SelectedIndex = i; return; }
            i++;
        }
        MissionList.SelectedIndex = -1;
        ShowMissionDetails(null);
    }

    private void MissionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (MissionList.SelectedItem is CampaignHeader)
        {
            // Headers are not selectable targets; move to the next mission.
            Dispatcher.BeginInvoke(new Action(SelectNextMissionFromHeader));
            return;
        }

        if (MissionList.SelectedItem is not CampaignMission mission)
        {
            ShowMissionDetails(null);
            return;
        }

        ShowMissionDetails(mission);

        var side = string.IsNullOrWhiteSpace(mission.SideName) ? "" : mission.SideName;
        CompanyStatus.Text = $"{mission.DisplayName}" +
            (string.IsNullOrWhiteSpace(side) ? "" : $"  ·  {side}") +
            $"  ·  {mission.LaunchScenario}";
    }

    /// <summary>
    /// Battle.ini LongDescription starts with the mission title and a
    /// "Location:" line; show those as a header instead of loose paragraphs.
    /// </summary>
    private void ShowMissionDetails(CampaignMission? mission)
    {
        if (mission == null)
        {
            MissionTitle.Text = "";
            MissionMeta.Text = "";
            MissionDesc.Text = "";
            MissionTitle.Visibility = Visibility.Collapsed;
            MissionMeta.Visibility = Visibility.Collapsed;
            MissionDivider.Visibility = Visibility.Collapsed;
            MissionDetailsBorder.Visibility = Visibility.Collapsed;
            return;
        }

        var title = mission.DisplayName;
        var meta = "";
        var body = mission.LongDescription ?? "";

        if (!string.IsNullOrWhiteSpace(body))
        {
            var lines = body.Replace("\r\n", "\n").Split('\n').Select(l => l.Trim()).ToList();

            while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);

            // The first line is the in-game mission title. It is sometimes longer
            // than the list entry (e.g. "Allied Mission 1 - Operation: Time Lapse").
            if (lines.Count > 0 && LooksLikeMissionTitle(lines[0]))
            {
                title = lines[0];
                lines.RemoveAt(0);
            }
            else if (lines.Count > 0 && string.Equals(lines[0], title.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                lines.RemoveAt(0);
            }

            while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);
            if (lines.Count > 0 && lines[0].StartsWith("Location:", StringComparison.OrdinalIgnoreCase))
            {
                meta = lines[0];
                lines.RemoveAt(0);
            }

            while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);
            body = string.Join(Environment.NewLine, lines).TrimEnd();
        }

        MissionTitle.Text = title;
        MissionMeta.Text = meta;
        MissionDesc.Text = body;

        MissionTitle.Visibility = Visibility.Visible;
        MissionMeta.Visibility = meta.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        MissionDivider.Visibility = Visibility.Visible;
        MissionDetailsBorder.Visibility = Visibility.Visible;
    }

    private static bool LooksLikeMissionTitle(string line) =>
        line.StartsWith("Allied Mission", StringComparison.OrdinalIgnoreCase) ||
        line.StartsWith("Soviet Mission", StringComparison.OrdinalIgnoreCase) ||
        line.StartsWith("Boot Camp", StringComparison.OrdinalIgnoreCase);

    private void SelectNextMissionFromHeader()
    {
        if (MissionList.ItemsSource is not System.Collections.IList items || items.Count == 0) return;
        var start = Math.Max(0, MissionList.SelectedIndex);
        for (var i = start; i < items.Count; i++)
            if (items[i] is CampaignMission) { MissionList.SelectedIndex = i; return; }
        for (var i = start - 1; i >= 0; i--)
            if (items[i] is CampaignMission) { MissionList.SelectedIndex = i; return; }
    }

    private void BtnCompanyBack_Click(object sender, RoutedEventArgs e) => ShowMain();

    private void BtnStartCampaign_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (MissionList.SelectedItem is not CampaignMission mission)
            {
                CompanyStatus.Text = L10n.T("Выберите миссию.");
                return;
            }

            if (LauncherCore.IsGameProcessRunning(_cfg))
            {
                ShowNotice(L10n.T("Запуск"), L10n.T("Игра уже запущена. Закройте текущий процесс игры перед новым запуском."));
                return;
            }

            if (!LauncherCore.Exists("CnCNet-Spawner.dll") || (!LauncherCore.Exists("gamemd-spawn.exe") && !LauncherCore.Exists(_cfg.Gamemd)))
            {
                ShowNotice(L10n.T("ОШИБКА ЗАПУСКА"), L10n.T("Для запуска миссии через Syringe не найден gamemd-spawn.exe или CnCNet-Spawner.dll."));
                return;
            }

            var settings = LauncherCore.LoadClientSettingsSafe(ClientIni);
            var difficulty = Math.Clamp(settings.Difficulty, 0, 2);
            var gameSpeed = Math.Clamp(settings.GameSpeed, 0, 6);

            // Keep campaign difficulty in game settings (used by normal campaign flow too).
            var iniPath = Path.Combine(LauncherCore.Root, "RA2MD.INI");
            var ini = IniFile.Load(iniPath);
            ini.Set("Options", "CampDifficulty", difficulty.ToString());
            ini.Set("Options", "Difficulty", difficulty.ToString());
            ini.Set("Options", "GameSpeed", gameSpeed.ToString());
            ini.Save(iniPath);

            CampaignData.WriteSpawnIni(mission, difficulty, gameSpeed, _cfg.Skirmish.Options);

            CompanyStatus.Text = L10n.F("Запуск миссии: {0} ({1}).", mission.DisplayName, mission.LaunchScenario);

            LauncherCore.SaveActiveIds(_mods, _active, _cfg);
            var started = LauncherCore.LaunchCampaignMission(_cfg);

            // With spawn, the actual game process is gamemd-spawn.exe or gamemd.exe.
            var gameProcess = Path.GetFileNameWithoutExtension(
                LauncherCore.Exists("gamemd-spawn.exe") ? "gamemd-spawn.exe" : LauncherCore.GameProcessName(_cfg));

            _ = WatchMissionLaunchAsync(started, gameProcess, mission.DisplayName);

            if (LauncherCore.WantsLuaApi(_cfg))
            {
                var dll = Path.Combine(LauncherCore.Root, "LuaAPI.dll");
                _ = LuaApiInjector.InjectWhenGameStartsAsync(started, dll, gameProcess)
                    .ContinueWith(t =>
                    {
                        var error = t.IsCompletedSuccessfully ? t.Result : t.Exception?.GetBaseException().Message;
                        if (string.IsNullOrEmpty(error)) return;
                        Dispatcher.Invoke(() => CompanyStatus.Text = error);
                    }, TaskScheduler.Default);
            }
        }
        catch (Exception ex)
        {
            ShowError(L10n.T("Произошла ошибка."), ex);
        }
    }

    /// <summary>
    /// Watches the game process the mission launch created. A game that never
    /// shows up, or one that dies while loading the mission, is reported with the
    /// reason from Syringe's log - otherwise a failed launch looks exactly like
    /// "nothing happened".
    /// </summary>
    private async Task WatchMissionLaunchAsync(DateTime startedUtc, string processName, string missionLabel)
    {
        var deadline = Environment.TickCount64 + 30000;
        var sawGame = false;

        while (Environment.TickCount64 < deadline)
        {
            if (IsGameRunning(processName, startedUtc))
            {
                sawGame = true;
                // Give the game a moment to load the mission, then check it survived.
                await Task.Delay(4000).ConfigureAwait(false);
                if (IsGameRunning(processName, startedUtc))
                {
                    TryOnUi(() => CompanyStatus.Text = L10n.F("Миссия запущена: {0}.", missionLabel));
                    return;
                }
                break;
            }
            await Task.Delay(500).ConfigureAwait(false);
        }

        var message = sawGame
            ? L10n.T("Игра упала при загрузке миссии.")
            : L10n.T("Игра не запустилась.");

        var log = LauncherCore.ReadSyringeLogTail(8);
        if (!string.IsNullOrWhiteSpace(log)) message += Environment.NewLine + Environment.NewLine + log;

        LauncherLog.Error("Mission launch/watch failed: " + message);
        TryOnUi(() => ShowNotice(L10n.T("Ошибка запуска"), message, showOpenLog: true));
    }

    private static bool IsGameRunning(string processName, DateTime sinceUtc)
    {
        System.Diagnostics.Process[] all;
        try { all = System.Diagnostics.Process.GetProcessesByName(processName); }
        catch { return false; }

        foreach (var p in all)
        {
            try
            {
                if (p.StartTime.ToUniversalTime() >= sinceUtc.AddSeconds(-3)) return true;
            }
            catch { }
            finally { p.Dispose(); }
        }
        return false;
    }

    private void TryOnUi(Action action)
    {
        try
        {
            if (Dispatcher.CheckAccess()) action();
            else Dispatcher.Invoke(action);
        }
        catch { }
    }

    private void BtnMapEditor_Click(object sender, EventArgs e)
    {
        var editor = LauncherCore.FindMapEditor();
        if (editor == null)
        {
            ShowNotice(L10n.T("РЕДАКТОР КАРТ"), L10n.T("Редактор карт не найден в Tools\\Map Editor."));
            return;
        }
        try
        {
            var dir = Path.GetDirectoryName(editor) ?? LauncherCore.Root;
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(editor)
            {
                WorkingDirectory = dir,
                UseShellExecute = true
            });
        }
        catch (Exception ex) { ShowError(L10n.T("Не удалось запустить редактор карт."), ex); }
    }

    private void BtnModsManager_Click(object sender, EventArgs e)
    {
        var mgr = new ModManagerWindow(this);
        mgr.ShowDialog();
        // The manager persists changes on the fly; reload and refresh all UI.
        _mods = LauncherCore.ScanMods();
        _active = LauncherCore.ReadActiveIds(_mods);
        UpdateModsUi();
    }

    // ---------------------------------------------------------------- skirmish

    // ---------------------------------------------------------------- skirmish: mods tab

    private string _modFilter = "";
    private ModInfo? _selectedMod;

    private MapCatalog _mapCatalog = new();
    private string _currentMapMode = "Battle";
    private int _currentMapMaxPlayers = LauncherCore.MaxSkirmishSlots;
    private bool _currentMapMaxPlayersKnown = true;

    private const string MySetPreset = "Мой набор";
    private static readonly SolidColorBrush ModsRowSelectedB = Theme.B(Theme.ModsRowSelected);
    private static readonly SolidColorBrush ModsRowHoverB = Theme.B(Theme.ModsRowHover);
    private static readonly SolidColorBrush ModsWarnB = Theme.B(Color.FromRgb(0xE6, 0xB8, 0x5C));

    private static bool Mentions(string text, string token)
    {
        if (string.IsNullOrWhiteSpace(text) || string.IsNullOrWhiteSpace(token)) return false;
        var idx = text.IndexOf(token, StringComparison.OrdinalIgnoreCase);
        while (idx >= 0)
        {
            var before = idx == 0 ? ' ' : text[idx - 1];
            var after = idx + token.Length >= text.Length ? ' ' : text[idx + token.Length];
            if (!char.IsLetterOrDigit(before) && !char.IsLetterOrDigit(after)) return true;
            idx = text.IndexOf(token, idx + 1, StringComparison.OrdinalIgnoreCase);
        }
        return false;
    }

    /// <summary>Short category from mod.json ("tag"), with a content-based fallback.</summary>
    private static string ModTag(ModInfo m)
    {
        var raw = (m.Tag ?? "").Trim();
        if (raw.Length > 0)
        {
            if (raw.Equals("AI", StringComparison.OrdinalIgnoreCase) || raw == "ИИ") return L10n.T("ИИ");
            if (raw.Equals("Balance", StringComparison.OrdinalIgnoreCase) || raw == "Баланс") return L10n.T("Баланс");
            if (raw.Equals("Content", StringComparison.OrdinalIgnoreCase) || raw == "Контент") return L10n.T("Контент");
            if (raw.Equals("LuaAPI", StringComparison.OrdinalIgnoreCase)) return L10n.T("LuaAPI");
            return L10n.T(raw);
        }

        var name = m.DisplayName + " " + m.Id;
        if (Mentions(m.Id, "probe")) return L10n.T("LuaAPI");
        if (Mentions(name, "AI") || Mentions(name, "ИИ")) return L10n.T("ИИ");

        foreach (var word in new[] { "Damage", "ROF", "HP", "Price", "Armor", "nerf", "balance", "баланс", "цена", "урон", "броня" })
            if (Mentions(m.Rules, word) || Mentions(name, word)) return L10n.T("Баланс");

        if (!m.IsLuaApi && m.LuaFiles.Count == 0) return L10n.T("Контент");
        if (m.IsLuaApi && string.IsNullOrWhiteSpace(m.DisplayDescription)) return L10n.T("LuaAPI");
        return L10n.T("Контент");
    }

    private static Color ModTagColor(string tag)
    {
        if (tag == L10n.T("Баланс")) return Color.FromRgb(0xE6, 0xB8, 0x5C);
        if (tag == L10n.T("ИИ")) return Color.FromRgb(0x5C, 0xB8, 0xE6);
        if (tag == L10n.T("Контент")) return Color.FromRgb(0x7E, 0xD0, 0x7E);
        if (tag == L10n.T("LuaAPI")) return Color.FromRgb(0xB5, 0x8C, 0xE6);
        return Theme.TextSecondary;
    }

    private static bool ModMatchesFilter(ModInfo m, string filter)
    {
        if (filter.Length == 0) return true;
        return (m.Name ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || (m.NameEn ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || (m.Id ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || (m.Description ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || (m.DescriptionEn ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || (m.Author ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || (m.Version ?? "").Contains(filter, StringComparison.OrdinalIgnoreCase)
            || ModTag(m).Contains(filter, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Rebuilds the mod list: checkbox, name + tag, and a conflict marker.</summary>
    private void BuildModsPanel()
    {
        if (SkirmishModsPanel == null) return;
        SkirmishModsPanel.Children.Clear();

        var cfg = _cfg.Skirmish;
        var visible = _mods
            .Where(m => cfg.ShowDevMods || !m.IsDev)
            .Where(m => ModMatchesFilter(m, _modFilter))
            .ToList();

        // Keep the selection across reloads, but always point at the current scan.
        _selectedMod = _selectedMod == null
            ? visible.FirstOrDefault()
            : visible.FirstOrDefault(m => m.Id == _selectedMod.Id) ?? visible.FirstOrDefault();

        var enabled = _mods.Where(m => _active.Contains(m.Id)).ToList();
        var conflicts = LauncherCore.FindModConflicts(enabled);

        foreach (var m in visible)
        {
            var others = conflicts
                .Where(c => c.A.Id == m.Id || c.B.Id == m.Id)
                .Select(c => c.A.Id == m.Id ? c.B : c.A)
                .GroupBy(x => x.Id)
                .Select(g => g.First())
                .ToList();

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var cb = new CheckBox
            {
                IsChecked = _active.Contains(m.Id),
                Tag = m,
                Cursor = Cursors.Hand,
                Width = Theme.ModsCheckSize,
                Height = Theme.ModsCheckSize,
                Margin = new Thickness(0, 0, 8, 0),
                VerticalAlignment = VerticalAlignment.Center
            };
            cb.Click += (_, _) =>
            {
                if (_syncing) return;
                if (cb.IsChecked == true) _active.Add(m.Id); else _active.Remove(m.Id);
                PersistActive();
                BuildModsPanel();
            };
            Grid.SetColumn(cb, 0);
            grid.Children.Add(cb);

            var title = new Grid { VerticalAlignment = VerticalAlignment.Center };
            title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var name = new TextBlock
            {
                Text = m.DisplayName,
                FontSize = 13,
                Foreground = Theme.TextPrimaryB,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center
            };
            if (!string.Equals(m.Id, m.DisplayName, StringComparison.Ordinal) || !string.Equals(m.Id, m.Name, StringComparison.Ordinal)) name.ToolTip = m.Id;
            Grid.SetColumn(name, 0);
            title.Children.Add(name);

            var tagText = ModTag(m);
            var tagColor = ModTagColor(tagText);
            var tag = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x22, tagColor.R, tagColor.G, tagColor.B)),
                CornerRadius = new CornerRadius(2),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(8, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            tag.Child = new TextBlock
            {
                Text = tagText,
                FontSize = 9,
                Foreground = new SolidColorBrush(tagColor)
            };
            Grid.SetColumn(tag, 1);
            title.Children.Add(tag);
            Grid.SetColumn(title, 1);
            grid.Children.Add(title);

            if (others.Count > 0)
            {
                var names = string.Join(", ", others.Select(o => "«" + o.Name + "»"));
                var warn = new TextBlock
                {
                    Text = "⚠",
                    FontFamily = new FontFamily("Segoe UI Symbol"),
                    FontSize = 14,
                    Foreground = ModsWarnB,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(8, 0, 0, 0),
                    ToolTip = L10n.F("Конфликт с включённым модом: {0}", names)
                };
                Grid.SetColumn(warn, 2);
                grid.Children.Add(warn);
            }

            var selected = _selectedMod?.Id == m.Id;
            var row = new Border
            {
                Tag = m,
                Height = Theme.ModsRowHeight,
                Padding = new Thickness(8, 0, 8, 0),
                Margin = new Thickness(0, 1, 0, 1),
                Background = selected ? ModsRowSelectedB : Brushes.Transparent,
                Cursor = Cursors.Hand,
                Child = grid
            };
            row.MouseEnter += (_, _) =>
            {
                if (_selectedMod?.Id != m.Id) row.Background = ModsRowHoverB;
            };
            row.MouseLeave += (_, _) =>
            {
                row.Background = _selectedMod?.Id == m.Id ? ModsRowSelectedB : Brushes.Transparent;
            };
            row.MouseLeftButtonUp += (_, e) =>
            {
                SelectMod(m);
                e.Handled = true;
            };
            SkirmishModsPanel.Children.Add(row);
        }

        if (visible.Count == 0)
            SkirmishModsPanel.Children.Add(new TextBlock
            {
                Text = L10n.T("Моды не найдены."),
                FontSize = 12,
                Foreground = Theme.TextSecondaryB,
                Margin = new Thickness(8, 10, 8, 10)
            });

        UpdateModsCounter();
        UpdateModDetails();
        SyncPresetSelection();
    }

    private int ActiveModCount() => _mods.Count(m => _active.Contains(m.Id));

    private void UpdateModsCounter()
    {
        if (TabMods == null) return;
        TabMods.Header = L10n.F("МОДЫ {0}/{1}", ActiveModCount(), _mods.Count);
        TabMods.ToolTip = L10n.T("LMM не нужен: лаунчер сам применяет active_mods.txt и запускает игру с LuaAPI.");
        UpdateSkirmishStatus();
    }

    private void UpdateSkirmishStatus()
    {
        if (SkirmishStatus == null) return;
        if (!_currentMapMaxPlayersKnown && SkirmishView?.Visibility == Visibility.Visible)
            SkirmishStatus.Text = L10n.T("Позиции карты не определены");
        else
            SkirmishStatus.Text = L10n.F("Будет загружено модов: {0}", ActiveModCount());
    }

    private void SelectMod(ModInfo m)
    {
        if (_selectedMod?.Id == m.Id) return;
        _selectedMod = m;
        BuildModsPanel();
    }

    private void UpdateModDetails()
    {
        if (ModDetailsName == null) return;
        var m = _selectedMod;
        if (m == null)
        {
            ModDetailsName.Text = L10n.T("Выберите мод");
            ModDetailsMeta.Text = "";
            ModDetailsDesc.Text = "";
            ModDetailsWarn.Text = "";
            ModDetailsWarn.Visibility = Visibility.Collapsed;
            return;
        }

        ModDetailsName.Text = m.DisplayName;

        var author = string.IsNullOrWhiteSpace(m.Author) ? L10n.T("не указан") : m.Author;
        var version = string.IsNullOrWhiteSpace(m.Version) ? "—" : m.Version;
        ModDetailsMeta.Text = L10n.T("АВТОР: ") + author
            + "   ·   " + L10n.T("ВЕРСИЯ: ") + version
            + "   ·   " + ModTag(m);

        ModDetailsDesc.Text = string.IsNullOrWhiteSpace(m.DisplayDescription) ? L10n.T("(нет описания)") : m.DisplayDescription;

        var conflicts = new List<string>();
        var activeOthers = LauncherCore.FindModConflicts(_mods.Where(x => _active.Contains(x.Id)))
            .Where(c => c.A.Id == m.Id || c.B.Id == m.Id)
            .Select(c => c.A.Id == m.Id ? c.B : c.A)
            .GroupBy(x => x.Id)
            .Select(g => g.First())
            .ToList();
        if (activeOthers.Count > 0)
            conflicts.Add(L10n.F("Включён конфликт с: {0}", string.Join(", ", activeOthers.Select(x => x.DisplayName))));
        foreach (var c in m.Conflicts)
        {
            if (string.IsNullOrWhiteSpace(c)) continue;
            // A declared conflict that is just the id/name of an enabled mod is
            // already covered by the live line above.
            if (activeOthers.Any(x =>
                    c.Trim().Equals(x.Id, StringComparison.OrdinalIgnoreCase) ||
                    c.Trim().Equals(x.Name, StringComparison.OrdinalIgnoreCase)))
                continue;
            if (!conflicts.Contains(c, StringComparer.OrdinalIgnoreCase)) conflicts.Add(c);
        }

        if (conflicts.Count == 0)
        {
            ModDetailsWarn.Text = "";
            ModDetailsWarn.Visibility = Visibility.Collapsed;
        }
        else
        {
            ModDetailsWarn.Text = L10n.T("КОНФЛИКТЫ: ") + string.Join("; ", conflicts);
            ModDetailsWarn.Visibility = Visibility.Visible;
        }
    }

    private void ModSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _modFilter = ModSearchBox.Text.Trim();
        if (ModSearchHint != null)
            ModSearchHint.Visibility = _modFilter.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
        BuildModsPanel();
    }

    private void ChkShowDevMods_Changed(object sender, RoutedEventArgs e)
    {
        if (_syncing) return;
        _cfg.Skirmish.ShowDevMods = ChkShowDevMods.IsChecked == true;
        SaveSkirmishState();
        if (!_cfg.Skirmish.ShowDevMods && _selectedMod?.IsDev == true) _selectedMod = null;
        BuildModsPanel();
    }

    /// <summary>Preset list: vanilla, the saved custom set, and everything.</summary>
    private void BuildPresetCombo()
    {
        if (ModPresetCombo == null) return;
        var wasSyncing = _syncing;
        _syncing = true;
        ModPresetCombo.Items.Clear();
        ModPresetCombo.Items.Add(L10n.T("Ванильный"));
        ModPresetCombo.Items.Add(L10n.T(MySetPreset));
        ModPresetCombo.Items.Add(L10n.T("Все"));
        ModPresetCombo.SelectedIndex = PresetIndexForActive();
        BtnSavePreset.ToolTip = L10n.T("Сохранить текущий выбор как набор «Мой набор»");
        _syncing = wasSyncing;
    }

    private int PresetIndexForActive()
    {
        if (_active.Count == 0) return 0;
        var all = _mods
            .Where(m => _cfg.Skirmish.ShowDevMods || !m.IsDev)
            .Select(m => m.Id)
            .ToHashSet(StringComparer.Ordinal);
        return all.Count > 0 && _active.SetEquals(all) ? 2 : 1;
    }

    private void SyncPresetSelection()
    {
        if (ModPresetCombo == null) return;
        var index = PresetIndexForActive();
        if (ModPresetCombo.SelectedIndex == index) return;
        var wasSyncing = _syncing;
        _syncing = true;
        ModPresetCombo.SelectedIndex = index;
        _syncing = wasSyncing;
    }

    private void ModPresetCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || ModPresetCombo.SelectedIndex < 0) return;
        var cfg = _cfg.Skirmish;

        IEnumerable<string> ids = ModPresetCombo.SelectedIndex switch
        {
            0 => Array.Empty<string>(),
            2 => _mods.Where(m => cfg.ShowDevMods || !m.IsDev).Select(m => m.Id),
            _ => cfg.Presets.TryGetValue(MySetPreset, out var preset)
                ? preset
                : LauncherCore.DefaultActiveIds(_mods)
        };

        _syncing = true;
        _active.Clear();
        foreach (var id in ids) _active.Add(id);
        _syncing = false;

        PersistActive();
        BuildModsPanel();
    }

    private void BtnSavePreset_Click(object sender, RoutedEventArgs e)
    {
        _cfg.Skirmish.Presets[MySetPreset] = _active.OrderBy(x => x, StringComparer.Ordinal).ToList();
        SaveSkirmishState();

        _syncing = true;
        ModPresetCombo.SelectedIndex = 1;
        _syncing = false;

        // Short confirmation; the button returns to its normal label by itself.
        BtnSavePreset.Content = L10n.T("СОХРАНЕНО");
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.4) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            BtnSavePreset.Content = L10n.T("СОХРАНИТЬ");
        };
        timer.Start();
    }

    // ---------------------------------------------------------------- skirmish: settings

    private static Grid SettingRow(string label, UIElement control)
    {
        var g = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 11,
            Foreground = Theme.TextSecondaryB,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        return g;
    }

    private static FrameworkElement SettingCell(string label, ComboBox control)
    {
        var s = new StackPanel { Margin = new Thickness(0, 0, 0, 4) };
        s.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 10,
            Foreground = Theme.TextSecondaryB,
            Margin = new Thickness(0, 0, 0, 2),
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        control.HorizontalAlignment = HorizontalAlignment.Stretch;
        control.Width = double.NaN;
        s.Children.Add(control);
        return s;
    }

    private static CheckBox SettingCheck(string text, bool value, Action<bool> onChange, string? tip = null)
    {
        var cb = new CheckBox
        {
            Content = text,
            IsChecked = value,
            Foreground = Theme.TextPrimaryB,
            FontSize = 12,
            Margin = new Thickness(0, 0, 0, 2),
            Cursor = Cursors.Hand
        };
        if (!string.IsNullOrWhiteSpace(tip)) cb.ToolTip = tip;
        cb.Click += (_, _) => onChange(cb.IsChecked == true);
        return cb;
    }

    private static ComboBox SettingCombo(IEnumerable<string> items, int selected, Action<int> onChange, double width = 140)
    {
        var cb = new ComboBox { Height = 24, FontSize = 11, MinWidth = 0, Margin = new Thickness(0, 0, 0, 0) };
        if (!double.IsNaN(width)) cb.Width = width;
        foreach (var i in items) cb.Items.Add(i);
        cb.SelectedIndex = Math.Clamp(selected, 0, Math.Max(0, cb.Items.Count - 1));
        cb.SelectionChanged += (_, _) => onChange(Math.Max(0, cb.SelectedIndex));
        return cb;
    }

    /// <summary>Builds the "Настройки" tab from the saved skirmish options.</summary>
    private void BuildSettingsPanel()
    {
        if (SettingsPanel == null) return;
        SettingsPanel.Children.Clear();

        var o = _cfg.Skirmish.Options;

        SettingsPanel.Children.Add(new TextBlock
        {
            Text = L10n.T("ИГРОВЫЕ ОПЦИИ"),
            FontSize = 11,
            Foreground = Theme.TextSecondaryB,
            Margin = new Thickness(0, 0, 0, 4)
        });

        // Four option rows: label left, combo right, aligned on one vertical line (compact, player-table style).
        var optionsGrid = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        optionsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        optionsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });

        void AddOptionRow(int row, string label, ComboBox combo)
        {
            optionsGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var lbl = new TextBlock
            {
                Text = label,
                FontSize = 11,
                Foreground = Theme.TextSecondaryB,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 3, 8, 3),
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            Grid.SetRow(lbl, row); Grid.SetColumn(lbl, 0);
            combo.Height = 24; combo.FontSize = 11; combo.Width = 120; combo.MinWidth = 0;
            combo.HorizontalAlignment = HorizontalAlignment.Right;
            combo.Margin = new Thickness(0, 3, 0, 3);
            Grid.SetRow(combo, row); Grid.SetColumn(combo, 1);
            optionsGrid.Children.Add(lbl);
            optionsGrid.Children.Add(combo);
        }

        var credits = new[] { "100000", "30000", "20000", "15000", "12500", "10000", "7500", "5000", "2500" };
        AddOptionRow(0, "Starting credits",
            SettingCombo(credits, credits.ToList().IndexOf(o.Credits.ToString()), idx =>
            {
                if (idx >= 0 && idx < credits.Length) o.Credits = int.Parse(credits[idx]);
                SaveSkirmishState();
            }, 120));

        var speeds = new[] { "1", "2", "3", "4", "5", "6" };
        AddOptionRow(1, "Game speed",
            SettingCombo(speeds, speeds.ToList().IndexOf(o.GameSpeed.ToString()), idx =>
            {
                if (idx >= 0 && idx < speeds.Length) o.GameSpeed = int.Parse(speeds[idx]);
                SaveSkirmishState();
            }, 120));

        var units = new[] { "10", "9", "8", "7", "6", "5", "4", "3", "2", "1", "0" };
        AddOptionRow(2, "Starting units",
            SettingCombo(units, units.ToList().IndexOf(o.UnitCount.ToString()), idx =>
            {
                if (idx >= 0 && idx < units.Length) o.UnitCount = int.Parse(units[idx]);
                SaveSkirmishState();
            }, 120));

        var superWeapons = new[] { "All", "Strategic", "Tactical", "None" };
        AddOptionRow(3, "Super weapons",
            SettingCombo(superWeapons, o.SuperWeapons, idx =>
            {
                o.SuperWeapons = idx;
                SaveSkirmishState();
            }, 120));

        SettingsPanel.Children.Add(optionsGrid);

        SettingsPanel.Children.Add(new TextBlock
        {
            Text = L10n.T("ПРАВИЛА"),
            FontSize = 11,
            Foreground = Theme.TextSecondaryB,
            Margin = new Thickness(0, 4, 0, 4)
        });

        SettingsPanel.Children.Add(SettingCheck(L10n.T("Короткая игра"), o.ShortGame, v => { o.ShortGame = v; SaveSkirmishState(); },
            L10n.T("Победа, когда все вражеские постройки уничтожены.")));
        SettingsPanel.Children.Add(SettingCheck(L10n.T("Автопочинка"), o.AutoRepair, v => { o.AutoRepair = v; SaveSkirmishState(); },
            L10n.T("Здания чинят себя сами.")));
        SettingsPanel.Children.Add(SettingCheck(L10n.T("Мульти-инженер"), o.MultiEngineer, v => { o.MultiEngineer = v; SaveSkirmishState(); },
            L10n.T("Для захвата сооружения нужны три инженера вместо одного.")));
        SettingsPanel.Children.Add(SettingCheck(L10n.T("Разрушаемые мосты"), o.BridgeDestroy, v => { o.BridgeDestroy = v; SaveSkirmishState(); },
            L10n.T("Низкие мосты можно разрушить выстрелом.")));


    }

    // ---------------------------------------------------------------- skirmish: players

    /// <summary>Table columns: slot, name, faction, colour, team, start, remove.</summary>
    private static readonly double[] PlayerColWidths = { 34, 0, 104, 84, 74, 76, 24 };

    private const int PlayerNameColumn = 1;
    private const int PlayerRemoveColumn = 6;

    private static Grid NewPlayerGrid()
    {
        var grid = new Grid();
        foreach (var width in PlayerColWidths)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = width > 0 ? new GridLength(width) : new GridLength(1, GridUnitType.Star)
            });
        }
        return grid;
    }

    private static TextBlock PlayerCell(string text, double size = 12, Brush? brush = null) =>
        new()
        {
            Text = text,
            FontSize = size,
            Foreground = brush ?? Theme.TextPrimaryB,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 4, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        };

    private static void SetCell(Grid row, UIElement element, int col)
    {
        Grid.SetColumn(element, col);
        row.Children.Add(element);
    }

    private static ComboBox PlayerCombo() => new()
    {
        Height = 24,
        FontSize = 11,
        Margin = new Thickness(0, 0, 4, 0),
        VerticalAlignment = VerticalAlignment.Center
    };

    // maxPlayers comes from MapCatalog/MapEntry (MPMaps.ini primary, waypoints fallback). No duplicate parsing.

    private string? GetStartBlockReason()
    {
        var cfg = _cfg.Skirmish;
        if (cfg.Players.Count > _currentMapMaxPlayers)
            return L10n.F("На этой карте максимум {0} игроков, сейчас {1}. Удалите лишние слоты.",
                _currentMapMaxPlayers, cfg.Players.Count);
        var used = new HashSet<int>();
        foreach (var p in cfg.Players)
        {
            var s = p.Start;
            if (s >= 1 && s <= _currentMapMaxPlayers && !used.Add(s))
                return L10n.T("Одна стартовая позиция выбрана у двух игроков.");
        }
        return null;
    }

    private void UpdateStartButtonState()
    {
        var reason = GetStartBlockReason();
        if (BtnStartSkirmish != null)
        {
            BtnStartSkirmish.IsEnabled = reason == null;
            BtnStartSkirmish.Opacity = reason == null ? 1 : 0.45;
        }
        if (SkirmishStartReason != null)
        {
            SkirmishStartReason.Text = reason ?? "";
            SkirmishStartReason.Visibility = reason == null ? Visibility.Collapsed : Visibility.Visible;
        }
        UpdateSkirmishStatus();
    }

    /// <summary>Rebuilds the player table from the saved skirmish state.</summary>
    private void BuildPlayerTable()
    {
        if (PlayerTablePanel == null) return;
        PlayerTablePanel.Children.Clear();

        var cfg = _cfg.Skirmish;
        LauncherCore.EnsureSkirmishDefaults(cfg);

        var factions = LauncherCore.SkirmishFactions();
        var colors = LauncherCore.SkirmishColors();
        var maxSlots = Math.Max(LauncherCore.MinSkirmishSlots, _currentMapMaxPlayers);

        if (PlayerSlotsCount != null)
            PlayerSlotsCount.Text = $"{cfg.Players.Count} / {_currentMapMaxPlayers}";

        // header
        var head = NewPlayerGrid();
        head.Margin = new Thickness(0, 0, 0, 6);
        SetCell(head, PlayerCell(L10n.T("СЛОТ"), 10, Theme.TextSecondaryB), 0);
        SetCell(head, PlayerCell(L10n.T("ИМЯ"), 10, Theme.TextSecondaryB), PlayerNameColumn);
        SetCell(head, PlayerCell(L10n.T("ФРАКЦИЯ"), 10, Theme.TextSecondaryB), 2);
        SetCell(head, PlayerCell(L10n.T("ЦВЕТ"), 10, Theme.TextSecondaryB), 3);
        SetCell(head, PlayerCell(L10n.T("КОМАНДА"), 10, Theme.TextSecondaryB), 4);
        SetCell(head, PlayerCell(L10n.T("СТАРТ"), 10, Theme.TextSecondaryB), 5);
        PlayerTablePanel.Children.Add(head);

        for (var i = 0; i < cfg.Players.Count; i++)
        {
            var index = i;
            var player = cfg.Players[i];
            var row = NewPlayerGrid();
            row.Margin = new Thickness(0, 2, 0, 2);

            SetCell(row, PlayerCell((index + 1).ToString(), 11, Theme.TextSecondaryB), 0);

            var name = new TextBox
            {
                Text = player.Name,
                Height = 24,
                FontSize = 12,
                Foreground = Theme.TextPrimaryB,
                Background = new SolidColorBrush(Color.FromArgb(0x14, 0x1E, 0x23, 0x2D)),
                BorderBrush = Theme.StrokeB,
                BorderThickness = new Thickness(1),
                CaretBrush = Theme.AccentB,
                Padding = new Thickness(6, 2, 6, 2),
                VerticalContentAlignment = VerticalAlignment.Center,
                Margin = new Thickness(2, 0, 6, 0)
            };
            name.TextChanged += (_, _) =>
            {
                if (_syncing) return;
                player.Name = name.Text;
                SaveSkirmishState();
            };
            SetCell(row, name, PlayerNameColumn);

            // Random is stored as -1 so the saved side indices stay game indices.
            var side = PlayerCombo();
            side.Items.Add(L10n.T("Случайно"));
            foreach (var faction in factions) side.Items.Add(faction);
            side.SelectedIndex = player.Side < 0 ? 0 : Math.Clamp(player.Side + 1, 1, side.Items.Count - 1);
            side.SelectionChanged += (_, _) =>
            {
                if (_syncing) return;
                player.Side = side.SelectedIndex <= 0 ? -1 : side.SelectedIndex - 1;
                SaveSkirmishState();
            };
            SetCell(row, side, 2);

            var color = PlayerCombo();
            foreach (var (colorName, _) in colors) color.Items.Add(colorName);
            color.SelectedIndex = Math.Clamp(player.Color, 0, colors.Count - 1);
            color.SelectionChanged += (_, _) =>
            {
                if (_syncing) return;
                player.Color = Math.Max(0, color.SelectedIndex);
                SaveSkirmishState();
            };
            SetCell(row, color, 3);

            var team = PlayerCombo();
            for (var t = 1; t <= 8; t++) team.Items.Add(t.ToString(CultureInfo.InvariantCulture));
            team.SelectedIndex = Math.Clamp(player.Team, 0, 7);
            team.SelectionChanged += (_, _) =>
            {
                if (_syncing) return;
                player.Team = Math.Max(0, team.SelectedIndex);
                SaveSkirmishState();
            };
            SetCell(row, team, 4);

            var start = PlayerCombo();
            start.Items.Add(L10n.T("Случайно"));
            for (var s = 1; s <= _currentMapMaxPlayers; s++) start.Items.Add(L10n.F("поз. {0}", s));
            start.SelectedIndex = Math.Clamp(player.Start, 0, _currentMapMaxPlayers);
            start.SelectionChanged += (_, _) =>
            {
                if (_syncing) return;
                player.Start = Math.Max(0, start.SelectedIndex);
                SaveSkirmishState();
                UpdateStartButtonState();
            };
            SetCell(row, start, 5);

            var canRemove = cfg.Players.Count > LauncherCore.MinSkirmishSlots;
            var remove = new Button
            {
                Content = "\u00D7",
                Height = 24,
                Padding = new Thickness(0),
                FontSize = 14,
                Foreground = Theme.TextSecondaryB,
                Style = (Style)FindResource("SmallButton"),
                ToolTip = canRemove ? L10n.T("Удалить слот") : L10n.T("Минимум 2 слота"),
                IsEnabled = canRemove,
                Opacity = canRemove ? 1 : 0.35,
                Margin = new Thickness(2, 0, 0, 0)
            };
            ToolTipService.SetShowOnDisabled(remove, true);
            remove.Click += (_, _) =>
            {
                if (cfg.Players.Count <= LauncherCore.MinSkirmishSlots) return;
                cfg.Players.RemoveAt(index);
                SaveSkirmishState();
                BuildPlayerTable();
            };
            SetCell(row, remove, PlayerRemoveColumn);

            PlayerTablePanel.Children.Add(row);
        }

        // AI slots can be added while the table has room on the selected map.
        var canAdd = cfg.Players.Count < maxSlots;
        var add = new Button
        {
            Content = L10n.T("+ ИИ-СЛОТ"),
            Height = 26,
            FontSize = 11,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(2, 8, 0, 0),
            Style = (Style)FindResource("SmallButton"),
            IsEnabled = canAdd,
            Opacity = canAdd ? 1 : 0.35,
            ToolTip = canAdd ? null : L10n.F("Карта рассчитана на {0} игроков", _currentMapMaxPlayers)
        };
        ToolTipService.SetShowOnDisabled(add, true);
        add.Click += (_, _) =>
        {
            if (cfg.Players.Count >= maxSlots) return;
            var np = LauncherCore.NewPlayer(false);
            np.Name = L10n.F("ИИ {0}", cfg.Players.Count);
            np.Color = cfg.Players.Count % colors.Count;
            cfg.Players.Add(np);
            SaveSkirmishState();
            BuildPlayerTable();
        };
        PlayerTablePanel.Children.Add(add);

        UpdateStartButtonState();
    }

    /// <summary>Saves the skirmish screen state (map, options, players, tab, mode).</summary>
    private void SaveSkirmishState()
    {
        try
        {
            _cfg.Skirmish.SelectedMode = _currentMapMode;
            LauncherCore.SaveConfig(_cfg);
        }
        catch { }
    }

    private sealed class MapModeItem
    {
        public string Key { get; init; } = "";
        public string Label { get; init; } = "";
        public override string ToString() => Label;
    }

    private void BuildMapModeCombo()
    {
        if (CmbMapMode == null) return;
        var items = new List<MapModeItem> { new() { Key = MapCatalog.AllMapsMode, Label = L10n.T("Все карты") } };
        foreach (var m in _mapCatalog.Modes) items.Add(new MapModeItem { Key = m, Label = m });
        items.Add(new MapModeItem { Key = MapCatalog.OtherMapsMode, Label = L10n.T("Прочие") });

        CmbMapMode.ItemsSource = items;
        var resolved = _mapCatalog.ResolveMode(_cfg.Skirmish.SelectedMode, _cfg.Skirmish.SelectedMap);
        _currentMapMode = resolved;
        _cfg.Skirmish.SelectedMode = resolved;
        CmbMapMode.SelectedItem = items.FirstOrDefault(i => i.Key == resolved) ?? items.FirstOrDefault(i => i.Key == "Battle") ?? items[0];
    }

    private void RefreshMaps()
    {
        if (MapList == null) return;
        var selectedPath = (MapList.SelectedItem as MapEntry)?.FilePath ?? _cfg.Skirmish.SelectedMap;
        var source = _mapCatalog.MapsForMode(_currentMapMode);
        var filtered = source.Where(MapMatchesFilter).ToList();

        MapList.ItemsSource = null;
        MapList.Items.Clear();
        foreach (var m in filtered) MapList.Items.Add(m);

        // Search in current mode only; offer "search in all" on empty filtered result.
        if (filtered.Count == 0 && _mapFilter.Length > 0)
        {
            MapSearchEmpty.Visibility = Visibility.Visible;
            MapSearchEmptyText.Text = L10n.F("Ничего не найдено в режиме {0}. Искать во всех?", CurrentModeLabel());
            MapSearchAllLink.Text = L10n.T("Искать во всех");
            MapSearchAllLink.Visibility = _currentMapMode == MapCatalog.AllMapsMode ? Visibility.Collapsed : Visibility.Visible;
        }
        else
        {
            MapSearchEmpty.Visibility = Visibility.Collapsed;
        }

        var restore = MapList.Items.OfType<MapEntry>()
            .FirstOrDefault(m => string.Equals(m.FilePath, selectedPath, StringComparison.OrdinalIgnoreCase));
        if (restore == null && MapList.Items.Count > 0) restore = (MapEntry)MapList.Items[0];

        if (restore != null)
        {
            MapList.SelectedItem = restore;
            ShowMapDetails(restore);
        }
        else
        {
            _currentMapMaxPlayers = LauncherCore.MaxSkirmishSlots;
            _currentMapMaxPlayersKnown = false;
            var msg = _mapFilter.Length > 0
                ? L10n.F("По фильтру «{0}» ничего не найдено.", _mapFilter)
                : L10n.T("Карты не найдены в корне игры и в Maps\\.");
            MapName.Text = msg;
            MapPath.Text = "";
            MapSize.Text = "";
            MapPreview.Source = null;
            MapPreview.Visibility = Visibility.Collapsed;
            MapPreviewEmpty.Text = L10n.T("Превью нет");
            MapPreviewEmpty.Visibility = Visibility.Visible;
            UpdateSettingsMapBrief();
            BuildPlayerTable();
        }
    }

    private string CurrentModeLabel() =>
        CmbMapMode?.SelectedItem is MapModeItem mi ? mi.Label : _currentMapMode;

    /// <summary>Search within the current mode by display name, file name or path.</summary>
    private bool MapMatchesFilter(MapEntry m)
    {
        if (_mapFilter.Length == 0) return true;
        return (m.DisplayName ?? "").Contains(_mapFilter, StringComparison.OrdinalIgnoreCase)
            || (m.Name ?? "").Contains(_mapFilter, StringComparison.OrdinalIgnoreCase)
            || (m.Relative ?? "").Contains(_mapFilter, StringComparison.OrdinalIgnoreCase);
    }

    private void MapSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _mapFilter = MapSearchBox.Text.Trim();
        MapSearchHint.Visibility = _mapFilter.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
        RefreshMaps();
    }

    private void MapSearchAllLink_Click(object sender, MouseButtonEventArgs e)
    {
        var all = CmbMapMode?.Items.OfType<MapModeItem>().FirstOrDefault(i => i.Key == MapCatalog.AllMapsMode);
        if (all != null && CmbMapMode != null) CmbMapMode.SelectedItem = all; // triggers mode change + refresh
    }

    private void CmbMapMode_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || CmbMapMode?.SelectedItem is not MapModeItem mi) return;
        _currentMapMode = mi.Key;
        _cfg.Skirmish.SelectedMode = mi.Key;
        // If saved/selected map is not in this mode, switching to "All maps" is handled by refresh+resolve on load;
        // on user switch keep selection if present in new mode, else refresh will pick first.
        SaveSkirmishState();
        RefreshMaps();
    }

    private void MapList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (MapList.SelectedItem is MapEntry m) ShowMapDetails(m);
    }

    private void UpdateSettingsMapBrief()
    {
        // Right-panel map info block removed (task 1); preview caption below map is the only source.
    }

    private void ShowMapDetails(MapEntry m)
    {
        _cfg.Skirmish.SelectedMap = m.FilePath;
        _cfg.Skirmish.SelectedMode = _currentMapMode;
        if (!_syncing) SaveSkirmishState();

        _currentMapMaxPlayers = m.MaxPlayersKnown ? Math.Clamp(m.MaxPlayers, 1, LauncherCore.MaxSkirmishSlots) : LauncherCore.MaxSkirmishSlots;
        _currentMapMaxPlayersKnown = m.MaxPlayersKnown;

        var size = "";
        try { size = LauncherCore.FormatSize(new FileInfo(m.FilePath).Length); } catch { }
        MapName.Text = string.IsNullOrWhiteSpace(m.DisplayName) ? m.Name : m.DisplayName;
        var metaParts = new List<string>();
        if (!string.IsNullOrWhiteSpace(m.Author)) metaParts.Add(m.Author);
        metaParts.Add(m.Relative ?? "");
        metaParts.Add(size);
        MapPath.Text = string.Join("  ·  ", metaParts.Where(s => !string.IsNullOrWhiteSpace(s)));
        MapSize.Text = "";

        UpdateSettingsMapBrief();
        BuildPlayerTable();

        var preview = !string.IsNullOrWhiteSpace(m.PreviewPath) && File.Exists(m.PreviewPath)
            ? m.PreviewPath
            : LauncherCore.FindMapPreview(m);
        if (preview == null)
        {
            MapPreview.Source = null;
            MapPreview.Visibility = Visibility.Collapsed;
            MapPreviewEmpty.Text = L10n.T("Превью нет: рядом с картой не найден .png");
            MapPreviewEmpty.Visibility = Visibility.Visible;
            return;
        }

        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit(); bmp.UriSource = new Uri(preview, UriKind.Absolute);
            bmp.CacheOption = BitmapCacheOption.OnLoad; bmp.EndInit(); bmp.Freeze();
            MapPreview.Source = bmp;
            MapPreview.Visibility = Visibility.Visible;
            MapPreviewEmpty.Visibility = Visibility.Collapsed;
        }
        catch
        {
            MapPreview.Source = null;
            MapPreview.Visibility = Visibility.Collapsed;
            MapPreviewEmpty.Text = L10n.T("Превью не читается");
            MapPreviewEmpty.Visibility = Visibility.Visible;
        }
    }

    private static string ModLabel(ModInfo m) => m.DisplayName + (m.IsLuaApi ? "  ·  LuaAPI" : "");

    private string? AiModConflictWarning() =>
        LauncherCore.HasAiModConflict(_active) ? L10n.T(L10n.AiModConflictMessage) : null;

    private void PersistActive()
    {
        try
        {
            LauncherCore.SaveActiveIds(_mods, _active, _cfg);
            UpdateModsCounter();
        }
        catch (Exception ex)
        {
            if (SkirmishStatus != null) SkirmishStatus.Text = L10n.T("ОШИБКА СОХРАНЕНИЯ: ") + ex.Message;
        }
    }

    private void BtnStartSkirmish_Click(object sender, RoutedEventArgs e)
    {
        UpdateStartButtonState();
        if (GetStartBlockReason() != null) return;
        if (LauncherCore.IsGameProcessRunning(_cfg))
        {
            ShowNotice(L10n.T("Запуск"), L10n.T("Игра уже запущена. Закройте текущий процесс игры перед новым запуском."));
            return;
        }
        LaunchGameSafe();
    }

    private void LaunchGameSafe()
    {
        try
        {
            LauncherCore.SaveActiveIds(_mods, _active, _cfg);
            LauncherCore.ApplySkirmishGameSpeed(_cfg.Skirmish.Options);
            var started = LauncherCore.LaunchGame(_cfg);
            var name = GameProcessName();
            SkirmishStatus.Text = L10n.F("Запуск: {0}. Карта и бой — в скирмиш-меню игры.", name);

            if (LauncherCore.WantsLuaApi(_cfg))
            {
                var dll = Path.Combine(LauncherCore.Root, "LuaAPI.dll");
                var process = LauncherCore.GameProcessName(_cfg);
                _ = LuaApiInjector.InjectWhenGameStartsAsync(started, dll, process)
                    .ContinueWith(t =>
                    {
                        var error = t.IsCompletedSuccessfully ? t.Result : t.Exception?.GetBaseException().Message;
                        if (string.IsNullOrEmpty(error)) return;
                        Dispatcher.Invoke(() => SkirmishStatus.Text = error);
                    }, TaskScheduler.Default);
            }
        }
        catch (Exception ex)
        {
            ShowError(L10n.T("Произошла ошибка."), ex);
        }
    }

    private string GameProcessName()
    {
        var (sOk, _) = LauncherCore.CheckExe(_cfg.Syringe);
        return Path.GetFileName(sOk ? _cfg.Syringe : _cfg.Gamemd);
    }

    private void BtnSkirmishBack_Click(object sender, RoutedEventArgs e) => ShowMain();

    // ---------------------------------------------------------------- options

    private void BtnCfgSave_Click(object sender, RoutedEventArgs e)
    {
        var supported = DisplayInfo.SupportedResolutions();
        var notes = new List<string>();

        _cfg.Syringe = CfgSyr.Text.Trim();
        _cfg.SyringeArgs = SplitArgs(CfgSyrArgs.Text);
        _cfg.Gamemd = CfgGame.Text.Trim();

        var settings = LauncherCore.LoadClientSettingsSafe(ClientIni);

        ResolveResolution(CmbGameRes, supported, notes, (w, h) => { settings.GameResX = w; settings.GameResY = h; },
            () => (settings.GameResX, settings.GameResY));
        ResolveResolution(CmbClientRes, supported, notes, (w, h) => { settings.ResolutionX = w; settings.ResolutionY = h; },
            () => (settings.ResolutionX, settings.ResolutionY));

        settings.DetailLevel = Math.Max(0, CmbDetail.SelectedIndex);
        settings.Difficulty = Math.Max(0, CmbDifficulty.SelectedIndex);
        if (CmbGameSpeed.SelectedItem is int speed) settings.GameSpeed = speed;
        if (CmbRenderer.SelectedItem is KeyValuePair<string, string> renderer) settings.Renderer = renderer.Key;

        var windowed = ChkWindowed.IsChecked == true;
        var borderlessFrame = ChkBorderlessFrame.IsChecked == true;
        var fullscreenClient = ChkBorderless.IsChecked == true;
        if (!windowed && !fullscreenClient) fullscreenClient = true;
        settings.BorderlessClient = fullscreenClient;
        settings.WindowedMode = windowed && !fullscreenClient;
        settings.BorderlessFrame = windowed && borderlessFrame && !fullscreenClient;
        settings.IntegerScaling = ChkInteger.IsChecked == true;

        settings.BackBuffer = ChkBackBuffer.IsChecked == true;
        settings.ToolTips = ChkTooltips.IsChecked == true;
        settings.QuickExit = ChkQuickExit.IsChecked == true;
        settings.AllowChat = ChkChat.IsChecked == true;
        settings.SkipScoreScreen = ChkSkipScore.IsChecked == true;
        settings.RecordReplays = ChkReplays.IsChecked == true;
        settings.PrioritySelectionFiltering = ChkPrioritySel.IsChecked == true;
        settings.ShowPowerDelta = ChkPowerDelta.IsChecked == true;
        settings.ShowHarvesterCounter = ChkHarvCounter.IsChecked == true;
        settings.ShowPlacementPreview = ChkPlacement.IsChecked == true;
        settings.ClientVolume = ParseVolume(TxtClientVol.Text, settings.ClientVolume);
        settings.SoundVolume = ParseVolume(TxtSoundVol.Text, settings.SoundVolume);
        settings.VoiceVolume = ParseVolume(TxtVoiceVol.Text, settings.VoiceVolume);
        settings.ScoreVolume = ParseVolume(TxtScoreVol.Text, settings.ScoreVolume);
        settings.AllowTaunts = ChkTaunts.IsChecked == true;
        _cfg.UiSoundsEnabled = ChkUiSounds?.IsChecked != false;
        UiSfx.Enabled = _cfg.UiSoundsEnabled;

        var language = CmbLanguage.SelectedItem is KeyValuePair<string, string> lang
            ? L10n.Normalize(lang.Key)
            : L10n.English;
        settings.Language = language;
        _cfg.Language = language;

        try
        {
            settings.Save(ClientIni);
            LauncherCore.SaveConfig(_cfg);
        }
        catch (Exception ex)
        {
            ShowError(L10n.T("Не удалось сохранить настройки."), ex);
            return;
        }
        ApplyClientWindowMode();

        var channel = CmbUpdateChannel.SelectedItem as string;

        var languageChanged = L10n.Current != language;
        L10n.SetLanguage(language);
        if (languageChanged) L10n.Apply(this);

        var channelNote = "";
        if (!string.IsNullOrEmpty(channel) && channel != _channelNow)
        {
            try
            {
                LauncherExtras.ApplyChannel(channel);
                _channelNow = channel;
                channelNote = "\n" + L10n.F("Канал обновлений: {0} (updateconfig.ini, нужен перезапуск клиента).", channel);
            }
            catch (Exception ex)
            {
                ShowNotice(L10n.T("ОБНОВЛЕНИЯ"), L10n.T("Настройки сохранены, но канал сменить не удалось:\n") + ex.Message);
                return;
            }
        }

        // Re-read RA2MD.INI so the fields show what was actually written
        // (for example a resolution clamped to the supported mode list).
        ShowOptions();
        _savedOptionsSnapshot = CaptureOptionsSnapshot();
        if (TxtUnsaved != null) TxtUnsaved.Visibility = Visibility.Collapsed;

        var body = L10n.T("Настройки игры: RA2MD.INI\nПараметры лаунчера: launcher_config.json") + channelNote;
        if (notes.Count > 0) body += "\n" + string.Join("\n", notes);
        ShowToast(body);
    }

    private static void ResolveResolution(ComboBox box, IReadOnlyList<DisplayInfo.Resolution> supported,
        List<string> notes, Action<int, int> apply, Func<(int Width, int Height)> current)
    {
        if (DisplayInfo.TryResolve(box.Text, supported, out var res, out var substituted))
        {
            apply(res.Width, res.Height);
            if (substituted)
                notes.Add(L10n.F("Выбранное разрешение не поддерживается монитором. Использовано {0}.", res));
            return;
        }

        if (supported.Count > 0)
        {
            var max = DisplayInfo.Max(supported);
            apply(max.Width, max.Height);
            notes.Add(L10n.F("Выбранное разрешение не поддерживается монитором. Использовано {0}.", max));
        }
        else
        {
            var (w, h) = current();
            apply(w, h);
        }
    }

    private string _savedOptionsSnapshot = "";
    private bool _suppressDirty;

    private bool _volSync;

    /// <summary>Sliders and boxes both use the client's 0-10 scale; RA2MD.INI keeps the 0-1 fraction.</summary>
    private void SetVolume(Slider slider, TextBox box, double value)
    {
        _volSync = true;
        var steps = (int)Math.Round(Math.Clamp(value, 0, 1) * 10);
        slider.Value = steps;
        box.Text = steps.ToString(CultureInfo.InvariantCulture);
        _volSync = false;
    }

    private void VolumeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_volSync) return;
        var slider = (Slider)sender;
        var box = slider == SlScoreVol ? TxtScoreVol
            : slider == SlSoundVol ? TxtSoundVol
            : slider == SlVoiceVol ? TxtVoiceVol
            : TxtClientVol;
        _volSync = true;
        box.Text = ((int)Math.Round(e.NewValue)).ToString(CultureInfo.InvariantCulture);
        _volSync = false;
        UpdateDirtyIndicator();
    }

    private void VolumeBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_volSync) return;
        var box = (TextBox)sender;
        if (!int.TryParse(box.Text, out var steps)) return;
        var slider = box == TxtScoreVol ? SlScoreVol
            : box == TxtSoundVol ? SlSoundVol
            : box == TxtVoiceVol ? SlVoiceVol
            : SlClientVol;
        _volSync = true;
        slider.Value = Math.Clamp(steps, 0, 10);
        _volSync = false;
    }

    private static double ParseVolume(string text, double fallback) =>
        int.TryParse(text, out var steps)
            ? Math.Clamp(steps, 0, 10) / 10.0
            : fallback;

    private void BtnCfgBack_Click(object sender, RoutedEventArgs e) => TryLeaveOptions();
    private void BtnStatsBack_Click(object sender, RoutedEventArgs e) => ShowMain();

    private static List<string> SplitArgs(string s) =>
        s.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    // ---------------------------------------------------------------- notice

    private System.Windows.Threading.DispatcherTimer? _toastTimer;

    private void ShowToast(string message, double seconds = 2.8)
    {
        try
        {
            if (ToastHost == null || ToastText == null) { ShowNotice(L10n.T("Уведомление"), message); return; }
            ToastText.Text = message;
            ToastHost.Visibility = Visibility.Visible;
            _toastTimer?.Stop();
            _toastTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
            _toastTimer.Tick += (_, _) => { _toastTimer?.Stop(); if (ToastHost != null) ToastHost.Visibility = Visibility.Collapsed; };
            _toastTimer.Start();
        }
        catch (Exception ex)
        {
            LauncherLog.Error("Toast failed", ex);
        }
    }


    private void ShowNotice(string title, string body, bool showOpenLog = false, Exception? ex = null)
    {
        if (ex != null) LauncherLog.Error(title + ": " + body, ex);
        UiSfx.PlayNotice();
        NoticeTitle.Text = title;
        NoticeBody.Text = body;
        if (BtnOpenLog != null) BtnOpenLog.Visibility = showOpenLog ? Visibility.Visible : Visibility.Collapsed;
        NoticeOverlay.Visibility = Visibility.Visible;
    }

    private void ShowError(string userMessage, Exception ex)
    {
        var friendly = LauncherLog.FriendlyMessage(ex, userMessage);
        ShowNotice(L10n.T("Ошибка"), friendly, showOpenLog: true, ex: ex);
    }

    private void BtnOpenLog_Click(object sender, RoutedEventArgs e)
    {
        if (!LauncherLog.TryOpen())
            ShowNotice(L10n.T("Ошибка"), L10n.T("Не удалось открыть журнал. Путь: ") + LauncherLog.Path);
    }

    private void BtnNoticeOk_Click(object sender, RoutedEventArgs e) => NoticeOverlay.Visibility = Visibility.Collapsed;
}
