using System.Media;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace LuaApiLauncher;

/// <summary>
/// Quiet UI sounds taken from the CnCNet client theme shipped with the mod.
/// Hover/click use button.wav, toggles use checkbox.wav (the campaign selector
/// uses the same sound), notices use message.wav. Files are embedded, so there
/// is nothing extra to deploy.
/// </summary>
internal static class UiSfx
{
    private static readonly SoundPlayer? Hover = Load("hover.wav");
    private static readonly SoundPlayer? Click = Load("click.wav");
    private static readonly SoundPlayer? Tick = Load("tick.wav");
    private static readonly SoundPlayer? Notice = Load("notice.wav");

    /// <summary>Global on/off switch for interface sounds (saved in launcher config).</summary>
    public static bool Enabled { get; set; } = true;

    public static void Install()
    {
        EventManager.RegisterClassHandler(typeof(ButtonBase), Mouse.MouseEnterEvent,
            new MouseEventHandler(OnButtonEnter));
        EventManager.RegisterClassHandler(typeof(ButtonBase), ButtonBase.ClickEvent,
            new RoutedEventHandler(OnButtonClick));
    }

    public static void PlayHover() => Play(Hover);
    public static void PlayClick() => Play(Click);
    public static void PlayTick() => Play(Tick);
    public static void PlayNotice() => Play(Notice);

    private static void OnButtonEnter(object sender, MouseEventArgs e)
    {
        if (sender is not ButtonBase button || button is RepeatButton || !button.IsEnabled) return;
        PlayHover();
    }

    private static void OnButtonClick(object sender, RoutedEventArgs e)
    {
        if (sender is not ButtonBase button || button is RepeatButton || !button.IsEnabled) return;
        if (button is ToggleButton) PlayTick();
        else PlayClick();
    }

    private static SoundPlayer? Load(string fileName)
    {
        try
        {
            var uri = new Uri("pack://application:,,,/Resources/Sfx/" + fileName, UriKind.Absolute);
            using var stream = Application.GetResourceStream(uri)?.Stream;
            if (stream is null) return null;

            var player = new SoundPlayer(stream);
            player.Load();
            return player;
        }
        catch
        {
            // Sound is cosmetic: never let a missing/broken file hurt the launcher.
            return null;
        }
    }

    private static void Play(SoundPlayer? player)
    {
        if (!Enabled) return;
        try { player?.Play(); } catch { }
    }
}
