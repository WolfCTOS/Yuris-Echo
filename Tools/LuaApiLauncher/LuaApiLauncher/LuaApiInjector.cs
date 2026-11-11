using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace LuaApiLauncher;

/// <summary>
/// Loads LuaAPI.dll into the running gamemd.exe.
///
/// LuaAPI.dll has no export table, so Syringe skips it: "Searching for DLLs
/// matching "LuaAPI.dll"..." is logged, but the DLL is never injected and no
/// script runs. The DLL starts its own bootstrap thread from DllMain, so a plain
/// remote LoadLibrary is enough (the same thing the working LMM flow does).
/// </summary>
internal static class LuaApiInjector
{
    private const uint ProcessAllAccess = 0x1F0FFF;
    private const uint MemCommitReserve = 0x3000;
    private const uint MemRelease = 0x8000;
    private const uint PageReadWrite = 0x04;
    private const uint ListModules32Bit = 0x01;

    private static uint? _loadLibraryRva;

    /// <summary>
    /// Waits for the game process started by the launcher and injects <paramref name="dllPath"/>.
    /// Returns null when the DLL was loaded, otherwise a localized error message.
    /// </summary>
    public static async Task<string?> InjectWhenGameStartsAsync(
        DateTime sinceUtc, string dllPath, string processName, int timeoutMs = 30000)
    {
        if (!File.Exists(dllPath)) return null;

        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            var pid = FindGameProcess(processName, sinceUtc);
            if (pid is int id)
            {
                // Let the process finish its loader work before touching it.
                await Task.Delay(150).ConfigureAwait(false);
                return Inject(id, dllPath) ? null : L10n.T("Не удалось загрузить LuaAPI.dll в игру.");
            }
            await Task.Delay(120).ConfigureAwait(false);
        }
        return L10n.T("gamemd.exe не запустился: LuaAPI не загружен.");
    }

    private static int? FindGameProcess(string processName, DateTime sinceUtc)
    {
        Process[] all;
        try { all = Process.GetProcessesByName(processName); }
        catch { return null; }

        int? result = null;
        DateTime newest = DateTime.MinValue;
        foreach (var p in all)
        {
            try
            {
                var started = p.StartTime.ToUniversalTime();
                if (started >= sinceUtc.AddSeconds(-3) && started > newest)
                {
                    newest = started;
                    result = p.Id;
                }
            }
            catch { }
            finally { p.Dispose(); }
        }
        return result;
    }

    private static bool Inject(int pid, string dllPath)
    {
        var proc = OpenProcess(ProcessAllAccess, false, pid);
        if (proc == IntPtr.Zero) return false;

        try
        {
            var loadLibrary = ResolveLoadLibraryW(proc);
            if (loadLibrary == IntPtr.Zero) return false;

            var bytes = Encoding.Unicode.GetBytes(dllPath + "\0");
            var mem = VirtualAllocEx(proc, IntPtr.Zero, (UIntPtr)bytes.Length, MemCommitReserve, PageReadWrite);
            if (mem == IntPtr.Zero) return false;

            try
            {
                if (!WriteProcessMemory(proc, mem, bytes, (UIntPtr)bytes.Length, out _)) return false;

                var thread = CreateRemoteThread(proc, IntPtr.Zero, UIntPtr.Zero, loadLibrary, mem, 0, out _);
                if (thread == IntPtr.Zero) return false;

                try
                {
                    if (WaitForSingleObject(thread, 15000) != 0) return false;
                    return GetExitCodeThread(thread, out var exit) && exit != 0;
                }
                finally { CloseHandle(thread); }
            }
            finally { VirtualFreeEx(proc, mem, UIntPtr.Zero, MemRelease); }
        }
        finally { CloseHandle(proc); }
    }

    private static IntPtr ResolveLoadLibraryW(IntPtr proc)
    {
        // 32-bit launcher on a 32-bit game: our own kernel32 address is valid in the target.
        if (IntPtr.Size == 4)
        {
            var own = GetModuleHandle("kernel32.dll");
            return own == IntPtr.Zero ? IntPtr.Zero : GetProcAddress(own, "LoadLibraryW");
        }

        // 64-bit launcher: use the WOW64 kernel32 mapped inside the 32-bit game.
        var kernel32 = FindWow64Module(proc, "kernel32.dll");
        if (kernel32 == IntPtr.Zero) return IntPtr.Zero;

        _loadLibraryRva ??= ExportRva(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SystemX86), "kernel32.dll"),
            "LoadLibraryW");
        return (IntPtr)(kernel32.ToInt64() + _loadLibraryRva.Value);
    }

    private static IntPtr FindWow64Module(IntPtr proc, string moduleName)
    {
        var modules = new IntPtr[1024];
        if (!EnumProcessModulesEx(proc, modules, (uint)(modules.Length * IntPtr.Size), out var needed, ListModules32Bit))
            return IntPtr.Zero;

        var count = (int)(needed / (uint)IntPtr.Size);
        if (count > modules.Length) count = modules.Length;

        var name = new StringBuilder(260);
        for (var i = 0; i < count; i++)
        {
            name.Clear();
            if (GetModuleBaseNameW(proc, modules[i], name, (uint)name.Capacity) == 0) continue;
            if (name.ToString().Equals(moduleName, StringComparison.OrdinalIgnoreCase)) return modules[i];
        }
        return IntPtr.Zero;
    }

    private static uint ExportRva(string pePath, string exportName)
    {
        var image = File.ReadAllBytes(pePath);
        var pe = BitConverter.ToInt32(image, 0x3C);
        var optional = pe + 24;
        var magic = BitConverter.ToUInt16(image, optional);
        var dataDir = optional + (magic == 0x20B ? 112 : 96);
        var exportRva = BitConverter.ToInt32(image, dataDir);
        if (exportRva == 0) throw new InvalidDataException("no exports in " + pePath);

        var export = RvaToOffset(image, pe, exportRva);
        var nameCount = BitConverter.ToInt32(image, export + 24);
        var namesRva = BitConverter.ToInt32(image, export + 32);
        var ordinalsRva = BitConverter.ToInt32(image, export + 36);
        var functionsRva = BitConverter.ToInt32(image, export + 28);

        for (var i = 0; i < nameCount; i++)
        {
            var nameRva = BitConverter.ToInt32(image, RvaToOffset(image, pe, namesRva) + i * 4);
            var nameOffset = RvaToOffset(image, pe, nameRva);
            var end = nameOffset;
            while (image[end] != 0) end++;
            if (Encoding.ASCII.GetString(image, nameOffset, end - nameOffset) != exportName) continue;

            var ordinal = BitConverter.ToUInt16(image, RvaToOffset(image, pe, ordinalsRva) + i * 2);
            return (uint)BitConverter.ToInt32(image, RvaToOffset(image, pe, functionsRva) + ordinal * 4);
        }
        throw new InvalidDataException("export not found: " + exportName);
    }

    private static int RvaToOffset(byte[] image, int pe, int rva)
    {
        var sections = BitConverter.ToUInt16(image, pe + 6);
        var optionalSize = BitConverter.ToUInt16(image, pe + 20);
        var section = pe + 24 + optionalSize;

        for (var i = 0; i < sections; i++)
        {
            var header = section + i * 40;
            var virtualAddress = BitConverter.ToInt32(image, header + 12);
            var virtualSize = BitConverter.ToInt32(image, header + 8);
            var rawSize = BitConverter.ToInt32(image, header + 16);
            var rawOffset = BitConverter.ToInt32(image, header + 20);
            var span = Math.Max(virtualSize, rawSize);
            if (rva >= virtualAddress && rva < virtualAddress + span)
                return rawOffset + (rva - virtualAddress);
        }
        throw new InvalidDataException("rva is not mapped: " + rva);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr written);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr attributes, UIntPtr stackSize, IntPtr startAddress, IntPtr parameter, uint flags, out uint threadId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeThread(IntPtr thread, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string moduleName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string procName);

    [DllImport("psapi.dll", SetLastError = true)]
    private static extern bool EnumProcessModulesEx(IntPtr process, [Out] IntPtr[] modules, uint size, out uint needed, uint filter);

    [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetModuleBaseNameW(IntPtr process, IntPtr module, StringBuilder name, uint size);
}
