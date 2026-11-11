using System.Runtime.InteropServices;

namespace LuaApiLauncher;

/// <summary>
/// Reads the resolutions actually supported by the active (primary) display
/// through Win32 EnumDisplaySettings instead of relying on a hard-coded list.
/// </summary>
public static class DisplayInfo
{
    public readonly record struct Resolution(int Width, int Height)
    {
        public override string ToString() => Width + "x" + Height;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumDisplaySettings(string? deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumDisplayDevices(string? device, uint devNum, ref DISPLAY_DEVICE displayDevice, uint flags);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private const int EnumCurrentSettings = -1;
    private const int SmCxScreen = 0;
    private const int SmCyScreen = 1;
    private const uint DisplayDevicePrimaryDevice = 0x4;

    private static string? PrimaryDeviceName()
    {
        var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++)
        {
            if ((dd.StateFlags & DisplayDevicePrimaryDevice) != 0) return dd.DeviceName;
            dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
        }
        return null;
    }

    private static bool CurrentMode(string? device, out Resolution res)
    {
        var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
        if (EnumDisplaySettings(device, EnumCurrentSettings, ref dm) && dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0)
        {
            res = new Resolution(dm.dmPelsWidth, dm.dmPelsHeight);
            return true;
        }
        res = default;
        return false;
    }

    /// <summary>Resolution the desktop is actually running at right now.</summary>
    public static Resolution DesktopResolution()
    {
        if (CurrentMode(PrimaryDeviceName(), out var res)) return res;
        if (CurrentMode(null, out res)) return res;
        return new Resolution(GetSystemMetrics(SmCxScreen), GetSystemMetrics(SmCyScreen));
    }

    /// <summary>All modes the active display reports, deduplicated and ordered by size.</summary>
    public static List<Resolution> SupportedResolutions()
    {
        var set = new HashSet<(int Width, int Height)>();

        void Collect(string? device)
        {
            var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
            for (var i = 0; i < 4096; i++)
            {
                dm.dmSize = (short)Marshal.SizeOf<DEVMODE>();
                if (!EnumDisplaySettings(device, i, ref dm)) break;
                if (dm.dmPelsWidth < 640 || dm.dmPelsHeight < 480) continue;
                if (dm.dmBitsPerPel is > 0 and < 16) continue;
                set.Add((dm.dmPelsWidth, dm.dmPelsHeight));
            }
        }

        var primary = PrimaryDeviceName();
        if (primary != null) Collect(primary);
        // EnumDisplaySettings(null) uses the display device of the calling thread;
        // collecting it as well covers session edge cases where the primary device
        // name cannot be resolved.
        Collect(null);

        var desktop = DesktopResolution();
        if (desktop.Width >= 640 && desktop.Height >= 480) set.Add((desktop.Width, desktop.Height));

        return set
            .Select(t => new Resolution(t.Width, t.Height))
            .OrderBy(r => (long)r.Width * r.Height)
            .ThenBy(r => r.Width)
            .ThenBy(r => r.Height)
            .ToList();
    }

    public static Resolution Max(IReadOnlyList<Resolution> supported)
    {
        Resolution best = default;
        foreach (var r in supported)
            if ((long)r.Width * r.Height > (long)best.Width * best.Height ||
                ((long)r.Width * r.Height == (long)best.Width * best.Height && r.Width > best.Width))
                best = r;
        return best;
    }

    public static bool Contains(IReadOnlyList<Resolution> supported, int width, int height) =>
        supported.Any(r => r.Width == width && r.Height == height);

    /// <summary>
    /// Resolves free-typed text ("1366x768") against the supported mode list.
    /// Returns the closest supported mode when the typed one is unavailable.
    /// </summary>
    public static bool TryResolve(string? text, IReadOnlyList<Resolution> supported,
        out Resolution result, out bool substituted)
    {
        substituted = false;
        result = default;

        var parts = (text ?? "").Trim().ToLowerInvariant().Split('x', 'х');
        if (parts.Length == 2 && int.TryParse(parts[0].Trim(), out var w) && int.TryParse(parts[1].Trim(), out var h) && w > 0 && h > 0)
        {
            if (Contains(supported, w, h))
            {
                result = new Resolution(w, h);
                return true;
            }

            if (supported.Count > 0)
            {
                result = supported
                    .OrderBy(r => Math.Abs((long)r.Width - w) + Math.Abs((long)r.Height - h))
                    .ThenByDescending(r => (long)r.Width * r.Height)
                    .First();
                substituted = true;
                return true;
            }
        }

        return false;
    }
}
