using System.Globalization;
using System.IO;

namespace LuaApiLauncher;

/// <summary>
/// Starting-position waypoints of a skirmish map, projected onto the preview
/// image with the same isometric formula the CnCNet client uses. Keeping the
/// math identical matters: the numbers in MPMaps.ini are packed isometric
/// cells, not plain X/Y preview pixels.
/// </summary>
public static class StartLocations
{
    public sealed record Marker(int Number, double X, double Y);

    private sealed record MapData(string[] Waypoints, int[] Size, int[] Local);
    private sealed record MpMapsCache(string Path, long Ticks, long Size, IniFile Ini);

    private static readonly object _gate = new();
    private static MpMapsCache? _mpMaps;
    private static (string MapPath, long MapTicks, long MapSize, string MpKey, long MpTicks, long MpSize, MapData? Data) _mapData;

    /// <summary>
    /// Returns one marker per map waypoint (1-based numbers, preview pixel
    /// coordinates) for the given preview image size.
    /// </summary>
    public static List<Marker> Read(MapEntry map, int imageWidth, int imageHeight)
    {
        var markers = new List<Marker>();
        if (map == null || imageWidth <= 0 || imageHeight <= 0)
            return markers;

        var data = GetData(map);
        if (data == null) return markers;

        var mapWidth = data.Size[2];
        for (var i = 0; i < data.Waypoints.Length; i++)
        {
            var point = Project(data.Waypoints[i], mapWidth, data.Local[0], data.Local[1], data.Local[2], data.Local[3],
                imageWidth, imageHeight);
            if (point.HasValue)
                markers.Add(new Marker(i + 1, point.Value.X, point.Value.Y));
        }

        return markers;
    }

    private static MapData? GetData(MapEntry map)
    {
        var mpPath = Path.Combine(LauncherCore.Root, "INI", "MPMaps.ini");
        var (mpTicks, mpSize) = Stamp(mpPath);
        var (mapTicks, mapSize) = Stamp(map.FilePath);
        var mpKey = MpMapsKey(map);

        lock (_gate)
        {
            if (string.Equals(_mapData.MapPath, map.FilePath, StringComparison.OrdinalIgnoreCase)
                && _mapData.MapTicks == mapTicks && _mapData.MapSize == mapSize
                && string.Equals(_mapData.MpKey, mpKey, StringComparison.OrdinalIgnoreCase)
                && _mapData.MpTicks == mpTicks && _mapData.MpSize == mpSize)
                return _mapData.Data;

            var mpIni = GetMpMaps(mpPath, mpTicks, mpSize);
            var waypoints = ReadWaypointsFrom(mpIni, mpKey);
            var size = ParseFour(mpIni.Get(mpKey, "Size"));
            var local = ParseFour(mpIni.Get(mpKey, "LocalSize"));

            // Maps outside the catalog: fall back to the map file's own sections.
            if (waypoints.Count == 0 || size == null || local == null)
            {
                var mapIni = IniFile.Load(map.FilePath);
                if (waypoints.Count == 0) waypoints = ReadWaypointsFrom(mapIni, "Waypoints");
                size ??= ParseFour(mapIni.Get("Map", "Size"));
                local ??= ParseFour(mapIni.Get("Map", "LocalSize"));
            }

            MapData? data = null;
            if (size != null && local != null && waypoints.Count > 0)
                data = new MapData(waypoints.ToArray(), size, local);

            _mapData = (map.FilePath, mapTicks, mapSize, mpKey, mpTicks, mpSize, data);
            return data;
        }
    }

    private static IniFile GetMpMaps(string path, long ticks, long size)
    {
        if (_mpMaps != null && string.Equals(_mpMaps.Path, path, StringComparison.OrdinalIgnoreCase)
            && _mpMaps.Ticks == ticks && _mpMaps.Size == size)
            return _mpMaps.Ini;
        var ini = IniFile.Load(path);
        _mpMaps = new MpMapsCache(path, ticks, size, ini);
        return ini;
    }

    private static (long ticks, long size) Stamp(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                var fi = new FileInfo(path);
                return (fi.LastWriteTimeUtc.Ticks, fi.Length);
            }
        }
        catch { }
        return (0, 0);
    }

    private static string MpMapsKey(MapEntry map)
    {
        var key = (map.Relative ?? "").Replace('/', '\\');
        if (key.EndsWith(".map", StringComparison.OrdinalIgnoreCase) ||
            key.EndsWith(".yrm", StringComparison.OrdinalIgnoreCase))
            key = key[..^4];
        return key;
    }

    private static List<string> ReadWaypointsFrom(IniFile ini, string section)
    {
        var list = new List<string>();
        if (ini.Get(section, "Waypoint0") == null && ini.Get(section, "0") == null)
            return list;

        // MPMaps uses Waypoint0..N, map files use [Waypoints] 0..N.
        var mpStyle = ini.Get(section, "Waypoint0") != null;
        for (var i = 0; i < LauncherCore.MaxSkirmishSlots; i++)
        {
            var value = ini.Get(section, mpStyle ? "Waypoint" + i : i.ToString(CultureInfo.InvariantCulture));
            if (string.IsNullOrWhiteSpace(value)) break;
            list.Add(value);
        }
        return list;
    }

    private static int[]? ParseFour(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var parts = value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length != 4) return null;
        var result = new int[4];
        for (var i = 0; i < 4; i++)
            if (!int.TryParse(parts[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out result[i]))
                return null;
        return result;
    }

    /// <summary>
    /// CnCNet Map.GetIsoTilePixelCoord: turn a packed waypoint into isometric
    /// tile coordinates, project to the local map rectangle and scale it to the
    /// preview image. Cell size constants cancel out, so they are omitted.
    /// </summary>
    private static (double X, double Y)? Project(
        string waypoint, int mapWidth, int localX, int localY, int localWidth, int localHeight,
        int imageWidth, int imageHeight)
    {
        var packed = waypoint.Split(',')[0].Trim();
        if (packed.Length < 4 || !packed.All(char.IsDigit))
            return null;

        var split = packed.Length - 3;
        if (!int.TryParse(packed[..split], NumberStyles.Integer, CultureInfo.InvariantCulture, out var isoTileY))
            return null;
        if (!int.TryParse(packed[split..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var isoTileX))
            return null;

        var rx = isoTileX - isoTileY + mapWidth - 1;
        var ry = isoTileX + isoTileY - mapWidth - 1;

        var ratioX = (rx / 2.0 - localX) / localWidth;
        var ratioY = (ry / 2.0 - localY) / localHeight;

        var x = ratioX * imageWidth;
        var y = ratioY * imageHeight;
        if (x < 0 || y < 0 || x > imageWidth || y > imageHeight)
            return null;

        return (x, y);
    }
}
