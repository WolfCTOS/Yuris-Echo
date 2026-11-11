using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace LuaApiLauncher;

public partial class MenuActionButton : UserControl
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(MenuActionButton),
        new PropertyMetadata("", (d, _) =>
        {
            var c = (MenuActionButton)d;
            var t = c.Text?.ToUpperInvariant() ?? "";
            c.Label.Text = t;
            c.LabelMeasure.Text = t;
        }));
    public static readonly DependencyProperty IsActionEnabledProperty = DependencyProperty.Register(
        nameof(IsActionEnabled), typeof(bool), typeof(MenuActionButton),
        new PropertyMetadata(true, (d, _) => ((MenuActionButton)d).ApplyState(true)));
    public static readonly DependencyProperty DisabledReasonProperty = DependencyProperty.Register(
        nameof(DisabledReason), typeof(string), typeof(MenuActionButton), new PropertyMetadata(""));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public bool IsActionEnabled { get => (bool)GetValue(IsActionEnabledProperty); set => SetValue(IsActionEnabledProperty, value); }
    public string DisabledReason { get => (string)GetValue(DisabledReasonProperty); set => SetValue(DisabledReasonProperty, value); }
    public event EventHandler? Click;

    private bool _hover, _pressed, _focused;
    private readonly SolidColorBrush _fill = new(Theme.ButtonFill);
    private readonly SolidColorBrush _stroke = new(Theme.Stroke);

    public MenuActionButton()
    {
        InitializeComponent();
        Bg.Data = Chamfer.Rect(Theme.ButtonWidth, Theme.ButtonHeight, Theme.ButtonChamfer);
        FocusBorder.Data = Bg.Data;
        Bg.Fill = _fill; Bg.Stroke = _stroke;
        KeyDown += Root_KeyDown;
        KeyUp += Root_KeyUp;
        ApplyState(true);
    }

    private void ApplyState(bool immediate = false)
    {
        var disabled = !IsActionEnabled;
        Cursor = disabled ? Cursors.Arrow : Cursors.Hand;
        ToolTip = disabled && !string.IsNullOrWhiteSpace(DisabledReason) ? DisabledReason : null;

        // States: disabled, selected/pressed (light fill, dark text), hover (lighter bg, white text, left bar),
        // normal (unchanged). Keyboard focus shown as light border distinct from selected.
        var darkText = Theme.WindowBg; // #0E1117 in theme is WindowBg (#0B0F14 is close; use WindowBg for existing resource)
        Color fill, stroke, text, divider, diamond, bottom;
        bool diamondFilled;
        FontWeight weight = FontWeights.Normal;
        bool hoverBar = false;
        bool focusBorder = false;

        if (disabled)
        {
            fill = Theme.DisabledFill; stroke = Theme.DisabledStroke; text = Theme.DisabledText;
            divider = Theme.DisabledStroke; diamond = Theme.DisabledText; bottom = Theme.DisabledStroke;
            diamondFilled = false;
        }
        else if (_pressed)
        {
            // Selected/active: light fill (as now), dark text/diamond/underline, SemiBold. Contrast >= 7:1.
            fill = Theme.Accent; stroke = Theme.Accent; text = darkText;
            divider = Theme.Stroke; diamond = darkText; bottom = darkText;
            diamondFilled = true; weight = FontWeights.SemiBold;
        }
        else if (_hover)
        {
            // Hover (not selected): slightly lighter than normal, white text, left accent bar 3px.
            fill = Color.FromArgb(0xE0, 0x2A, 0x30, 0x3D);
            stroke = _focused ? Theme.White : Color.FromArgb(0xFF, 0x4A, 0x52, 0x64);
            text = Theme.White; divider = Theme.TextSecondary; diamond = Theme.Accent; bottom = Theme.Accent;
            diamondFilled = true; hoverBar = true; focusBorder = _focused;
        }
        else
        {
            // Normal: unchanged.
            fill = Theme.ButtonFill; stroke = Theme.Stroke; text = Theme.TextPrimary;
            divider = Theme.Stroke; diamond = Theme.Accent; bottom = Theme.Accent;
            diamondFilled = false; focusBorder = _focused;
        }

        var dur = immediate ? TimeSpan.Zero : TimeSpan.FromMilliseconds(Theme.HoverMs);
        Anim(_fill, fill, dur);
        Anim(_stroke, stroke, dur);
        Label.Foreground = Theme.B(text);
        Label.FontWeight = weight;
        Divider.Fill = Theme.B(divider);
        Diamond.Stroke = Theme.B(diamond);
        Diamond.Fill = diamondFilled ? Theme.B(diamond) : Brushes.Transparent;
        BottomLine.Fill = Theme.B(bottom);

        HoverBar.Visibility = hoverBar ? Visibility.Visible : Visibility.Collapsed;
        HoverBar.Fill = Theme.AccentB;
        FocusBorder.Visibility = focusBorder ? Visibility.Visible : Visibility.Collapsed;
        FocusBorder.Stroke = Theme.WhiteB;
    }

    private static void Anim(SolidColorBrush b, Color to, TimeSpan dur)
    {
        b.BeginAnimation(SolidColorBrush.ColorProperty, null);
        if (dur == TimeSpan.Zero) b.Color = to;
        else b.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(to, dur) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
    }

    private void Root_MouseEnter(object sender, MouseEventArgs e) { _hover = true; if (IsActionEnabled) { ApplyState(); UiSfx.PlayHover(); } }
    private void Root_MouseLeave(object sender, MouseEventArgs e) { _hover = false; _pressed = false; ApplyState(); }
    private void Root_MouseDown(object sender, MouseButtonEventArgs e) { if (!IsActionEnabled) return; _pressed = true; Focus(); ApplyState(true); }
    private void Root_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!IsActionEnabled) return;
        var was = _pressed; _pressed = false; ApplyState();
        if (was && IsMouseOver) { UiSfx.PlayClick(); Click?.Invoke(this, EventArgs.Empty); }
    }

    private void PerformClick()
    {
        if (!IsActionEnabled) return;
        UiSfx.PlayClick();
        Click?.Invoke(this, EventArgs.Empty);
    }

    private void Root_KeyDown(object sender, KeyEventArgs e)
    {
        if (!IsActionEnabled) return;
        if (e.Key == Key.Enter)
        {
            PerformClick();
            e.Handled = true;
        }
        else if (e.Key == Key.Space)
        {
            _pressed = true;
            ApplyState(true);
            e.Handled = true;
        }
    }

    private void Root_KeyUp(object sender, KeyEventArgs e)
    {
        if (!IsActionEnabled) return;
        if (e.Key == Key.Space)
        {
            var was = _pressed;
            _pressed = false;
            ApplyState(true);
            if (was) PerformClick();
            e.Handled = true;
        }
    }

    private void Root_GotFocus(object sender, RoutedEventArgs e) { _focused = true; ApplyState(true); }
    private void Root_LostFocus(object sender, RoutedEventArgs e) { _focused = false; _pressed = false; ApplyState(true); }
}
