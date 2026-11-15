using System;
using System.Windows;
using System.Windows.Markup;
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
    /// The entry of the closed box and of the open list: the icon in the
    /// first column, the name in the second one. A faction without an icon
    /// leaves that column empty, so the name has the whole width of the
    /// field and a long name like "European Union" fits next to the arrow.
    /// A name that still does not fit is cut off with an ellipsis.
    /// </summary>
    public static DataTemplate ItemTemplate { get; } = (DataTemplate)XamlReader.Parse(IconXaml);

    private const string IconXaml = @"
<DataTemplate xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation""
             xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml"">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width=""Auto""/>
      <ColumnDefinition Width=""*""/>
    </Grid.ColumnDefinitions>
    <Image Grid.Column=""0"" Source=""{Binding Icon}"" Width=""21"" Height=""14"" Margin=""0,0,6,0""
           Stretch=""Uniform"" SnapsToDevicePixels=""True"" VerticalAlignment=""Center"">
      <Image.Style>
        <Style TargetType=""Image"">
          <Setter Property=""Visibility"" Value=""Visible""/>
          <Style.Triggers>
            <DataTrigger Binding=""{Binding Icon}"" Value=""{x:Null}"">
              <Setter Property=""Visibility"" Value=""Collapsed""/>
            </DataTrigger>
          </Style.Triggers>
        </Style>
      </Image.Style>
    </Image>
    <TextBlock Grid.Column=""1"" Text=""{Binding Name}"" VerticalAlignment=""Center""
               TextTrimming=""CharacterEllipsis""/>
  </Grid>
</DataTemplate>";
}
