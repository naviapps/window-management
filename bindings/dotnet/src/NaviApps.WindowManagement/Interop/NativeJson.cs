using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace NaviApps.WindowManagement;

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct WindowJsonView { internal uint Code; internal byte* Data; internal nuint Length; }
internal sealed class JsonHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public JsonHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.DestroyJson(handle); return true; }
}
internal static unsafe partial class Native
{
    internal static byte[] ValueJson(uint kind, ReadOnlySpan<byte> bytes)
    {
        EnsureAbi();
        fixed (byte* data = bytes)
            return CopyJson(NormalizeJson(kind, data, (nuint)bytes.Length));
    }
    internal static string ToJson(NativePlacement value) { EnsureAbi(); return Encoding.UTF8.GetString(CopyJson(EncodePlacement(value))); }
    internal static string ToJson(NativeDisplayTarget value) { EnsureAbi(); return Encoding.UTF8.GetString(CopyJson(EncodeDisplayTarget(value))); }
    internal static string ToJson(NativePlacementRequest value) { EnsureAbi(); return Encoding.UTF8.GetString(CopyJson(EncodePlacementRequest(value))); }
    internal static string ToJson(NativeMoveRequest value) { EnsureAbi(); return Encoding.UTF8.GetString(CopyJson(EncodeMoveRequest(value))); }
    private static byte[] CopyJson(JsonHandle owner)
    {
        using (owner)
        {
            if (owner.IsInvalid) throw new InvalidOperationException("Native JSON owner is unavailable.");
            var view = JsonView(owner);
            if (view.Data == null) throw new InvalidOperationException("Native JSON bytes are unavailable.");
            var result = new ReadOnlySpan<byte>(view.Data, checked((int)view.Length)).ToArray();
            if (view.Code != 0) throw new WindowDataException(Encoding.UTF8.GetString(result));
            return result;
        }
    }
    [DllImport(Library, EntryPoint = "window_management_value_json")] private static extern JsonHandle NormalizeJson(uint kind, byte* data, nuint length);
    [DllImport(Library, EntryPoint = "window_management_placement_json")] private static extern JsonHandle EncodePlacement(NativePlacement value);
    [DllImport(Library, EntryPoint = "window_management_display_target_json")] private static extern JsonHandle EncodeDisplayTarget(NativeDisplayTarget value);
    [DllImport(Library, EntryPoint = "window_management_placement_request_json")] private static extern JsonHandle EncodePlacementRequest(NativePlacementRequest value);
    [DllImport(Library, EntryPoint = "window_management_move_request_json")] private static extern JsonHandle EncodeMoveRequest(NativeMoveRequest value);
    [DllImport(Library, EntryPoint = "window_management_json_view")] private static extern WindowJsonView JsonView(JsonHandle owner);
    [DllImport(Library, EntryPoint = "window_management_json_destroy")] internal static extern void DestroyJson(nint owner);
    [DllImport(Library, EntryPoint = "window_management_windows_request")] internal static extern QueryHandle Request(WindowIdentity identity, uint kind, byte* data, nuint length, uint fallback);
}
