using System.Reflection;
using System.Runtime.InteropServices;
namespace NaviApps.WindowManagement;

[StructLayout(LayoutKind.Sequential)]
internal struct RectResult { internal uint Code; internal Rect Frame; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativePlacement { internal uint Kind; internal long Columns, Rows, Column, Row, ColumnSpan, RowSpan; internal double WidthRatio, HeightRatio; }
[StructLayout(LayoutKind.Sequential)]
internal struct PlacementResult { internal uint Code; internal NativePlacement Value; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativeDisplayTarget { internal uint Kind; internal double X, Y; internal ulong Identifier; internal long Index; }
[StructLayout(LayoutKind.Sequential)]
internal struct SelectionResult { internal uint Code; internal NativeDisplayTarget Value; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativePlacementRequest { internal NativePlacement Placement; internal NativeDisplayTarget Display; internal uint Area; internal double Inset; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativeMoveRequest { internal uint Direction, PreservesRelativePosition; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativeDisplay
{
    internal Rect Frame, VisibleFrame; internal ulong Identifier; internal uint HasIdentifier, IsMain;
    internal static NativeDisplay From(Display value) => new() { Frame = value.Frame, VisibleFrame = value.VisibleFrame, Identifier = value.Identifier ?? 0, HasIdentifier = value.Identifier.HasValue ? 1u : 0u, IsMain = value.IsMain ? 1u : 0u };
    internal readonly Display Read() => new(Frame, VisibleFrame, HasIdentifier == 0 ? null : Identifier, IsMain != 0);
}
internal static unsafe partial class Native
{
    private const string Library = "window_management_ffi";
    static Native()
    {
        if (OperatingSystem.IsWindows()) NativeLibrary.SetDllImportResolver(typeof(Native).Assembly, Resolve);
    }
    private static nint Resolve(string name, Assembly assembly, DllImportSearchPath? search)
    {
        if (name != Library) return 0;
        var directories = (AppContext.GetData("NATIVE_DLL_SEARCH_DIRECTORIES") as string ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Append(Path.GetDirectoryName(assembly.Location)!).Append(Environment.SystemDirectory);
        foreach (var directory in directories) if (!string.IsNullOrEmpty(directory) && NativeLibrary.TryLoad(Path.Combine(directory, Library + ".dll"), out var handle)) return handle;
        throw new DllNotFoundException("Place the native WindowManagement library beside its assembly or install a native runtime asset.");
    }
    internal static void EnsureAbi() { if (Version() != 5) throw new InvalidOperationException("Unsupported native window ABI."); }
    [DllImport(Library, EntryPoint = "window_management_abi_version")] private static extern uint Version();
    [DllImport(Library, EntryPoint = "window_management_rect_normalize")] internal static extern Rect Normalize(Rect value);
    [DllImport(Library, EntryPoint = "window_management_rect_contains")] internal static extern uint Contains(Rect value, double x, double y);
    [DllImport(Library, EntryPoint = "window_management_placement")] internal static extern RectResult Place(NativePlacement placement, Rect area, double inset);
    [DllImport(Library, EntryPoint = "window_management_placement_normalize")] internal static extern PlacementResult NormalizePlacement(NativePlacement placement);
    [DllImport(Library, EntryPoint = "window_management_display_target_normalize")] internal static extern SelectionResult NormalizeTarget(NativeDisplayTarget target);
    [DllImport(Library, EntryPoint = "window_management_inset_normalize")] internal static extern double NormalizeInset(double inset);
    [DllImport(Library, EntryPoint = "window_management_placement_resolve")] internal static extern RectResult ResolvePlacement(NativePlacementRequest request, Rect window, NativeDisplay* displays, nuint count, uint fallback);
    [DllImport(Library, EntryPoint = "window_management_movement_resolve")] internal static extern RectResult ResolveMovement(NativeMoveRequest request, Rect window, NativeDisplay* displays, nuint count, uint fallback);
    [DllImport(Library, EntryPoint = "window_management_move")] internal static extern Rect Move(Rect window, Rect source, Rect target, uint preserves);
    [DllImport(Library, EntryPoint = "window_management_display_adjacent")] internal static extern long Adjacent(long index, uint previous, long count);
    [DllImport(Library, EntryPoint = "window_management_display_order")] internal static extern nuint Order(NativeDisplay* displays, nuint count, nuint* output, nuint capacity);
    [DllImport(Library, EntryPoint = "window_management_display_select")]
    internal static extern long Select(NativeDisplay* displays, nuint count, uint kind, Rect window, double x, double y, ulong identifier, long index, uint fallback);
    [DllImport(Library, EntryPoint = "window_management_display_index_containing_point")]
    internal static extern long IndexContainingPoint(NativeDisplay* displays, nuint count, double x, double y);
    [DllImport(Library, EntryPoint = "window_management_windows_foreground_identity")] internal static extern WindowIdentityResult ForegroundIdentity();
    [DllImport(Library, EntryPoint = "window_management_windows_query")] internal static extern QueryHandle Query(uint kind, WindowIdentity identity, double x, double y);
    [DllImport(Library, EntryPoint = "window_management_windows_displays")] internal static extern QueryHandle Displays();
    [DllImport(Library, EntryPoint = "window_management_windows_command")] internal static extern QueryHandle Command(WindowIdentity identity, uint operation, Rect frame);
    [DllImport(Library, EntryPoint = "window_management_windows_query_view")] internal static extern QueryView View(QueryHandle query);
    [DllImport(Library, EntryPoint = "window_management_windows_query_window")] internal static extern WindowView Window(QueryHandle query, nuint index);
    [DllImport(Library, EntryPoint = "window_management_windows_query_destroy")] internal static extern void Destroy(nint query);
}
[StructLayout(LayoutKind.Sequential)]
internal struct WindowIdentityResult { internal uint Code, NativeError; internal WindowIdentity Identity; }
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct QueryView { internal uint Code, NativeError; internal nuint Count; internal NativeDisplay* Displays; internal nuint DisplayCount; }
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct WindowView { internal WindowIdentity Identity; internal Rect Frame; internal byte* Title; internal nuint TitleLength; internal uint Minimized, Maximized; }
internal sealed class QueryHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
{
    public QueryHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.Destroy(handle); return true; }
}
