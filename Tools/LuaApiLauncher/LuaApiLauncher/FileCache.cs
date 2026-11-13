using System;
using System.Collections.Generic;
using System.IO;

namespace LuaApiLauncher;

/// <summary>
/// Caches a value that was derived from files. The key identifies the entry,
/// the version says whether it is still current - usually the write time and
/// the size of the files it was built from.
///
/// The launcher reads the rules file and the map files on every interaction of
/// the setup table; without the cache every keystroke costs a few
/// milliseconds of file parsing that nothing changes.
/// </summary>
internal sealed class FileCache<T> where T : class
{
    private readonly Func<string, T> _factory;
    private readonly object _sync = new();
    private readonly Dictionary<string, (string Version, T Value)> _entries = new(StringComparer.Ordinal);

    public FileCache(Func<string, T> factory) => _factory = factory;

    public T Get(string key, string version)
    {
        lock (_sync)
        {
            if (_entries.TryGetValue(key, out var hit) && hit.Version == version) return hit.Value;
            var value = _factory(key);
            _entries[key] = (version, value);
            return value;
        }
    }
}

/// <summary>The version of a file: its write time and its size.</summary>
internal static class FileVersion
{
    public static string Of(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists) return "-";
            return fi.LastWriteTimeUtc.Ticks + ":" + fi.Length;
        }
        catch { return "-"; }
    }
}
