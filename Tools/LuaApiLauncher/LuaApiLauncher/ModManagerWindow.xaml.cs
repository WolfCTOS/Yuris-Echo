using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace LuaApiLauncher;

/// <summary>
/// Separate mod manager window: load order, per-mod .lua/.json file list,
/// conflict check, and "Open mods folder". Mod descriptions are not shown here
/// to avoid duplicating the details panel on the Mods tab.
/// </summary>
public partial class ModManagerWindow : Window
{
    private readonly MainWindow _owner;
    private bool _syncing;
    private ModInfo? _selected;
    private List<ModInfo> _mods = new();
    private HashSet<string> _active = new(StringComparer.Ordinal);

    public ModManagerWindow(MainWindow owner)
    {
        _owner = owner;
        InitializeComponent();
        Owner = owner;
        Loaded += (_, _) =>
        {
            L10n.Apply(this);
            Title = L10n.T("Менеджер модов");
        };
        Reload();
    }

    /// <summary>Mods in load order: enabled mods in their saved order, then inactive ones.</summary>
    private static List<ModInfo> InLoadOrder(IReadOnlyList<ModInfo> mods, HashSet<string> active)
    {
        var list = new List<ModInfo>();
        foreach (var m in mods) if (active.Contains(m.Id)) list.Add(m);
        foreach (var m in mods) if (!active.Contains(m.Id)) list.Add(m);
        return list;
    }

    private void Reload(bool rescan = false)
    {
        if (rescan)
        {
            LauncherCore.InvalidateModsCache();
            _mods = LauncherCore.ScanMods();
            _active = LauncherCore.ReadActiveIds(_mods);
        }
        else
        {
            _mods = _owner.Mods.ToList();
            _active = new HashSet<string>(_owner.ActiveMods, StringComparer.Ordinal);
        }

        var ordered = InLoadOrder(_mods, _active);
        var selectedId = _selected?.Id;

        _syncing = true;
        ModList.Items.Clear();
        var loadPos = 0;
        foreach (var m in ordered)
        {
            var enabled = _active.Contains(m.Id);
            if (enabled) loadPos++;
            var label = enabled ? L10n.F("{0}. {1}", loadPos, m.DisplayName) : "-  " + m.DisplayName;

            var cb = new CheckBox
            {
                IsChecked = enabled,
                Content = label,
                Foreground = enabled ? Theme.TextPrimaryB : Theme.TextSecondaryB,
                FontSize = 13,
                Tag = m,
                Cursor = Cursors.Hand,
                ToolTip = m.Folder.Length > 0 ? m.Folder : null
            };
            cb.Click += (_, _) =>
            {
                if (_syncing) return;
                if (cb.IsChecked == true) _active.Add(m.Id);
                else _active.Remove(m.Id);
                Persist();
                Reload();
            };
            ModList.Items.Add(cb);
        }
        _syncing = false;

        if (ModList.Items.Count == 0)
        {
            _selected = null;
            ClearDetails();
        }
        else
        {
            var idx = 0;
            if (selectedId != null)
                for (var i = 0; i < ordered.Count; i++)
                    if (ordered[i].Id == selectedId) { idx = i; break; }
            ModList.SelectedIndex = idx;
        }

        RefreshStats();
        L10n.Apply(this);
        Title = L10n.T("Менеджер модов");
    }

    private void Persist()
    {
        try
        {
            // The owner gets the same set, and the configuration is written with
            // it, so the two sources of truth cannot drift apart.
            _owner.ApplyActiveMods(_active);
            LauncherCore.SaveActiveIds(_mods, _active, _owner.Config);
            _owner.UpdateModsUi();
        }
        catch (Exception ex) { LauncherLog.Error("The mod manager could not persist the active mod list", ex); }
    }

    private void RefreshStats()
    {
        var lua = _mods.Sum(m => m.LuaFiles.Count);
        var json = _mods.Sum(m => m.JsonFiles.Count);
        ManagerStats.Text = L10n.F("МОДОВ: {0}   |   АКТИВНО: {1}   |   .lua: {2}   |   .json: {3}",
            _mods.Count, _active.Count, lua, json);
    }

    private void ModList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ModList.SelectedItem is CheckBox cb && cb.Tag is ModInfo m)
        {
            _selected = m;
            ShowDetails(m);
        }
        else
        {
            _selected = null;
            ClearDetails();
        }
    }

    private void ShowDetails(ModInfo m)
    {
        DetName.Text = m.DisplayName;
        var meta = new List<string>();
        if (!string.IsNullOrWhiteSpace(m.Version)) meta.Add(L10n.T("ВЕРСИЯ: ") + m.Version);
        if (!string.IsNullOrWhiteSpace(m.Author)) meta.Add(L10n.T("АВТОР: ") + m.Author);
        if (!string.Equals(m.Id, m.Name, StringComparison.Ordinal) || !string.Equals(m.Id, m.DisplayName, StringComparison.Ordinal)) meta.Add("ID: " + m.Id);
        if (m.Folder.Length > 0) meta.Add(L10n.T("ПАПКА: mods\\") + m.Folder);
        if (m.IsLuaApi) meta.Add("LuaAPI");
        meta.Add(L10n.T("СТАТУС: ") + (_active.Contains(m.Id) ? L10n.T("ВКЛЮЧЁН") : L10n.T("ВЫКЛЮЧЕН")));
        if (_active.Contains(m.Id))
        {
            var pos = 0;
            foreach (var x in _mods) { if (_active.Contains(x.Id)) pos++; if (x.Id == m.Id) break; }
            meta.Add(L10n.F("ПОРЯДОК ЗАГРУЗКИ: {0}", pos));
        }
        DetMeta.Text = string.Join("\n", meta);

        // Conflict check: declared + currently active. No description duplicated.
        var conflictLines = new List<string>();
        var activeOthers = LauncherCore.FindModConflicts(_mods.Where(x => _active.Contains(x.Id)))
            .Where(c => c.A.Id == m.Id || c.B.Id == m.Id)
            .Select(c => c.A.Id == m.Id ? c.B : c.A)
            .GroupBy(x => x.Id)
            .Select(g => g.First())
            .ToList();
        if (activeOthers.Count > 0)
            conflictLines.Add(L10n.F("Включён конфликт с: {0}", string.Join(", ", activeOthers.Select(x => x.DisplayName))));
        foreach (var c in m.Conflicts)
            if (!string.IsNullOrWhiteSpace(c) &&
                !activeOthers.Any(x => c.Trim().Equals(x.Id, StringComparison.OrdinalIgnoreCase) ||
                                       c.Trim().Equals(x.Name, StringComparison.OrdinalIgnoreCase)))
                conflictLines.Add(c);
        if (conflictLines.Count > 0)
        {
            DetWarn.Text = L10n.T("КОНФЛИКТЫ: ") + string.Join("; ", conflictLines);
            DetWarnBox.Visibility = Visibility.Visible;
        }
        else
        {
            DetWarnBox.Visibility = Visibility.Collapsed;
        }

        FilesPanel.Children.Clear();
        AddFileSection(".LUA", m.LuaFiles);
        AddFileSection(".JSON", m.JsonFiles);
        if (m.LuaFiles.Count + m.JsonFiles.Count == 0)
            FilesPanel.Children.Add(new TextBlock
            {
                Text = L10n.T("В папке мода нет файлов .lua или .json."),
                FontSize = 12,
                Foreground = Theme.TextSecondaryB
            });
    }

    private void ClearDetails()
    {
        DetName.Text = L10n.T("ВЫБЕРИТЕ МОД");
        DetMeta.Text = "";
        DetWarnBox.Visibility = Visibility.Collapsed;
        FilesPanel.Children.Clear();
    }

    private void AddFileSection(string title, List<ModFile> files)
    {
        FilesPanel.Children.Add(new TextBlock
        {
            Text = $"{title} — {files.Count}",
            FontSize = 11,
            Foreground = Theme.AccentB,
            Margin = new Thickness(0, 10, 0, 4)
        });

        if (files.Count == 0)
        {
            FilesPanel.Children.Add(new TextBlock
            {
                Text = "—",
                FontSize = 12,
                Foreground = Theme.TextSecondaryB,
                Margin = new Thickness(4, 0, 0, 2)
            });
            return;
        }

        foreach (var f in files)
        {
            var row = new Grid { Margin = new Thickness(0, 1, 0, 1) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var name = new TextBlock
            {
                Text = f.RelPath,
                FontFamily = new FontFamily("Consolas, Bahnschrift, Segoe UI"),
                FontSize = 12,
                Foreground = Theme.TextPrimaryB,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(4, 0, 8, 0)
            };
            var size = new TextBlock
            {
                Text = LauncherCore.FormatSize(f.Size),
                FontSize = 11,
                Foreground = Theme.TextSecondaryB
            };

            Grid.SetColumn(size, 1);
            row.Children.Add(name);
            row.Children.Add(size);
            FilesPanel.Children.Add(row);
        }
    }

    private void BtnEnableAll_Click(object sender, RoutedEventArgs e)
    {
        _active.Clear();
        foreach (var m in _mods) _active.Add(m.Id);
        Persist();
        Reload();
    }

    private void BtnDisableAll_Click(object sender, RoutedEventArgs e)
    {
        _active.Clear();
        Persist();
        Reload();
    }

    private void BtnRefresh_Click(object sender, RoutedEventArgs e) => Reload(rescan: true);

    private void BtnOpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(LauncherCore.ModsDir);
            Process.Start(new ProcessStartInfo("explorer.exe", LauncherCore.ModsDir) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, L10n.T("ОШИБКА"), MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();
}
