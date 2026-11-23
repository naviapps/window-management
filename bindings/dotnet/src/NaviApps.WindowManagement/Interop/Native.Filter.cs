using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace NaviApps.WindowManagement;

internal sealed class WindowFilterHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public WindowFilterHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.DestroyFilter(handle); return true; }
}
internal static unsafe partial class Native
{
    internal static (WindowFilterHandle Owner, string Json) CompileFilter(ReadOnlySpan<byte> json)
    {
        EnsureAbi();
        WindowFilterHandle owner;
        JsonHandle result;
        fixed (byte* data = json) owner = FilterCompile(data, (nuint)json.Length, out result);
        try
        {
            var canonical = Encoding.UTF8.GetString(CopyJson(result));
            if (owner.IsInvalid) throw new InvalidOperationException("Native snapshot filter owner is unavailable.");
            return (owner, canonical);
        }
        catch
        {
            owner.Dispose();
            throw;
        }
    }
    internal static bool FilterIncludes(WindowFilterHandle filter, ulong window, long process, string? application)
    {
        uint result;
        if (application is null) result = FilterMatch(filter, window, process, null, 0);
        else
        {
            // Retain one byte for a present empty string; null/zero means absent.
            var bytes = WindowJson.EncodeUtf8(application + "\0");
            fixed (byte* data = bytes) result = FilterMatch(filter, window, process, data, (nuint)(bytes.Length - 1));
        }
        return result switch { 0 => false, 1 => true, _ => throw new InvalidDataException("Invalid native snapshot filter response.") };
    }
    [DllImport(Library, EntryPoint = "window_management_window_filter_compile")] private static extern WindowFilterHandle FilterCompile(byte* data, nuint length, out JsonHandle json);
    [DllImport(Library, EntryPoint = "window_management_window_filter_match_identity")] internal static extern uint FilterMatchIdentity(WindowFilterHandle filter, ulong window, long process);
    [DllImport(Library, EntryPoint = "window_management_window_filter_includes")] private static extern uint FilterMatch(WindowFilterHandle filter, ulong window, long process, byte* application, nuint length);
    [DllImport(Library, EntryPoint = "window_management_window_filter_destroy")] internal static extern void DestroyFilter(nint filter);
}
