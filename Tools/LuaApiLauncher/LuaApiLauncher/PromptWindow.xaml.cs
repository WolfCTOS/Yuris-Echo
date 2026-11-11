using System.Windows;

namespace LuaApiLauncher;

/// <summary>
/// A one-line modal prompt (used for naming a mod preset). Keeps the launcher's
/// look instead of showing the system dialog.
/// </summary>
public partial class PromptWindow : Window
{
    public string Value => PromptInput.Text.Trim();

    public PromptWindow(string title, string label)
    {
        InitializeComponent();
        Title = title;
        PromptLabel.Text = label;
        Loaded += (_, _) => { PromptInput.Focus(); PromptInput.SelectAll(); };
    }

    private void OkBtn_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(PromptInput.Text))
        {
            PromptInput.Focus();
            return;
        }
        DialogResult = true;
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
