using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace LuaApiLauncher;

/// <summary>
/// One entry of the faction drop down: the country name and its small icon.
///
/// The combo box gets data items with a template instead of ready made
/// elements. WPF moves UIElement items in and out of the selection box when
/// the drop down opens (it takes the element out of the list and shows it in
/// the closed box), and that moved the label of the closed box to the left
/// after the first click. A data item is always rendered by the same
/// template, so the label stays where it is.
/// </summary>
public sealed class FactionChoice
{
    public FactionChoice(string name, ImageSource? icon)
    {
        Name = name;
        Icon = icon;
    }

    public string Name { get; }

    public ImageSource? Icon { get; }

    /// <summary>
    /// The template of the drop down entries: the icon and the name as one
    /// centered block. The grid is stretched so the block keeps the same
    /// place in the closed box and in the open list.
    /// </summary>
    public static DataTemplate ItemTemplate { get; } = BuildTemplate();

    private static DataTemplate BuildTemplate()
    {
        var grid = new FrameworkElementFactory(typeof(Grid));
        grid.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Stretch);

        var block = new FrameworkElementFactory(typeof(StackPanel));
        block.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
        block.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        block.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);

        var icon = new FrameworkElementFactory(typeof(Image));
        icon.SetBinding(Image.SourceProperty, new Binding(nameof(Icon)));
        icon.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(Icon))
        {
            Converter = NullToCollapsedConverter.Instance
        });
        icon.SetValue(Image.WidthProperty, 21d);
        icon.SetValue(Image.HeightProperty, 14d);
        icon.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 6, 0));
        icon.SetValue(Image.StretchProperty, Stretch.Uniform);
        icon.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);

        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetBinding(TextBlock.TextProperty, new Binding(nameof(Name)));
        text.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        text.SetValue(FrameworkElement.MaxWidthProperty, 78d);
        text.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);

        block.AppendChild(icon);
        block.AppendChild(text);
        grid.AppendChild(block);

        var template = new DataTemplate();
        template.VisualTree = grid;
        return template;
    }
}

/// <summary>Hides an image without a source, so it leaves no empty gap.</summary>
public sealed class NullToCollapsedConverter : IValueConverter
{
    public static readonly NullToCollapsedConverter Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value == null ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
