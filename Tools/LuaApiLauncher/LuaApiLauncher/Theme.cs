using System.Windows;
using System.Windows.Media;

namespace LuaApiLauncher;

/// <summary>
/// All visual constants from the spec. Adjust here based on screenshot feedback.
/// </summary>
public static class Theme
{
    // Window
    public const double WindowWidth = 1280;
    public const double WindowHeight = 720;
    public const double TitleBarHeight = 32;

    // Palette
    public static readonly Color WindowBg = Hex("#0B0F14");
    public static readonly Color Overlay45 = Hex("#0B0F14", 0.45);
    public static readonly Color PanelBg = Hex("#151922", 0.85);
    public static readonly Color Stroke = Hex("#343A47");
    public static readonly Color TextPrimary = Hex("#C9CCD3");
    public static readonly Color TextSecondary = Hex("#7C8290");
    public static readonly Color Accent = Hex("#E6E8EC");
    public static readonly Color Pressed = Hex("#7C8290");
    public static readonly Color DisabledText = Hex("#4A505C");
    public static readonly Color DisabledStroke = Hex("#272B34");
    public static readonly Color DisabledFill = Hex("#151922", 0.60);
    public static readonly Color ButtonFill = Hex("#1E232D", 0.80);
    public static readonly Color White = Hex("#FFFFFF");
    public static readonly Color BgGradientTop = Hex("#141A22");
    public static readonly Color ModsRowSelected = Hex("#FFFFFF", 0.14);
    public static readonly Color ModsRowHover = Hex("#FFFFFF", 0.05);
    public static readonly Color CheckBg = Hex("#0B0F14");
    public static readonly Color ScrollThumb = Hex("#343A47");

    public static SolidColorBrush B(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    public static readonly SolidColorBrush WindowBgB = B(WindowBg);
    public static readonly SolidColorBrush StrokeB = B(Stroke);
    public static readonly SolidColorBrush TextPrimaryB = B(TextPrimary);
    public static readonly SolidColorBrush TextSecondaryB = B(TextSecondary);
    public static readonly SolidColorBrush AccentB = B(Accent);
    public static readonly SolidColorBrush PressedB = B(Pressed);
    public static readonly SolidColorBrush DisabledTextB = B(DisabledText);
    public static readonly SolidColorBrush DisabledStrokeB = B(DisabledStroke);
    public static readonly SolidColorBrush DisabledFillB = B(DisabledFill);
    public static readonly SolidColorBrush ButtonFillB = B(ButtonFill);
    public static readonly SolidColorBrush WhiteB = B(White);
    public static readonly SolidColorBrush PanelBgB = B(PanelBg);
    public static readonly SolidColorBrush CheckBgB = B(CheckBg);

    // Fonts
    public static readonly FontFamily UiFont = new("Bahnschrift, Segoe UI");
    public const double FontMainTitle = 56;
    public const double FontSubtitle = 16;
    public const double FontPanelTitle = 28;
    public const double FontGroupLabel = 11;
    public const double FontButton = 15;
    public const double FontStatus = 12;
    public const double FontModsTitle = 28;
    public const double FontModsSub = 11;

    // Main layout
    public const double LeftMargin = 48;
    public const double HeaderTop = 72;
    public const double HeaderAccentBarWidth = 3;
    public const double HeaderUnderlineWidth = 180;
    public const double HeaderUnderlineThickness = 1;
    public const double PanelWidth = 360;
    public const double PanelRightMargin = 48;
    public const double PanelTop = 96;
    public const double PanelBottom = 624; // from top
    public const double PanelChamfer = 16;
    public const double PanelPadding = 24;
    public const double PanelStroke = 1;
    public const double PanelAccentLineWidth = 96;
    public const double PanelAccentLineThickness = 2;
    public const double GroupLabelTop = 20;
    public const double GroupLabelBottom = 8;
    public const double ButtonGap = 8;

    // Button
    public const double ButtonWidth = 312;
    public const double ButtonHeight = 44;
    public const double ButtonChamfer = 8;
    public const double ButtonStroke = 1;
    public const double ButtonDividerRight = 40;
    public const double ButtonDividerHeight = 24;
    public const double DiamondSize = 8;
    public const double ButtonBottomLineWidth = 24;
    public const double ButtonBottomLineThickness = 2;
    public const double ButtonBottomLineLeft = 12;
    public const int HoverMs = 120;

    // Mods screen
    public const double ModsContentMargin = 48;
    public const double ModsGap = 24;
    public const double ModsPanelsTop = 140;
    public const double ModsPanelsHeight = 400;
    public const double ModsRowHeight = 36;
    public const double ModsCheckSize = 18;
    public const double ModsBottomButtonHeight = 40;
    public const double ScrollBarWidth = 6;

    private static Color Hex(string hex, double opacity = 1.0)
    {
        hex = hex.TrimStart('#');
        byte r = Convert.ToByte(hex.Substring(0, 2), 16);
        byte g = Convert.ToByte(hex.Substring(2, 2), 16);
        byte b = Convert.ToByte(hex.Substring(4, 2), 16);
        byte a = (byte)Math.Clamp((int)Math.Round(opacity * 255), 0, 255);
        return Color.FromArgb(a, r, g, b);
    }
}
