using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
namespace NaviApps.WindowManagement;

/// <summary>A captured HWND/PID/thread identity. Validation before commands is best effort.</summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct WindowIdentity(ulong Handle, uint ProcessId, uint ThreadId);
/// <summary>Owned native window metadata, independent of query handle lifetime. Rust standardizes its frame.</summary>
public sealed record WindowSnapshot(WindowIdentity Identity, Rect Frame, string Title, bool IsMinimized, bool IsMaximized)
{
    private readonly Rect frame = Geometry.Normalize(Frame);

    /// <summary>Finite standardized frame in the snapshot's coordinate space.</summary>
    public Rect Frame { get => frame; init => frame = Geometry.Normalize(value); }

    /// <summary>Test a point in the snapshot's coordinate space. Maximum edges are excluded.</summary>
    public bool Contains(double x, double y) => Geometry.Contains(Frame, x, y);
}
/// <summary>Windows native query/control. No window is activated implicitly by discovery.
/// Coordinates use physical virtual-desktop pixels. No process-wide DPI setting changes.</summary>
[SupportedOSPlatform("windows")]
public static unsafe class WindowsDesktop
{
    private static void CheckPlatform() { if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Native Windows desktop required."); Native.EnsureAbi(); }
    /// <summary>Enumerate visible, non-tool, non-cloaked top-level windows in native z order.
    /// Optional filtering uses native window/process IDs; this query does not provide application identifiers.</summary>
    public static IReadOnlyList<WindowSnapshot> GetWindows(WindowSnapshotFilter? filter = null) =>
        EnumerateWindows(filter, null);

    /// <summary>Enumerate visible windows in native z order and filter using caller-supplied
    /// application identifiers. The resolver receives numeric matches when the filter has application conditions.
    /// Return null when its owner application identifier is unavailable.</summary>
    public static IReadOnlyList<WindowSnapshot> GetWindows(
        WindowSnapshotFilter filter, Func<WindowIdentity, string?> resolveOwnerApplicationIdentifier)
    {
        ArgumentNullException.ThrowIfNull(filter);
        ArgumentNullException.ThrowIfNull(resolveOwnerApplicationIdentifier);
        return EnumerateWindows(filter, resolveOwnerApplicationIdentifier);
    }

    private static System.Collections.ObjectModel.ReadOnlyCollection<WindowSnapshot> EnumerateWindows(
        WindowSnapshotFilter? filter, Func<WindowIdentity, string?>? resolveOwnerApplicationIdentifier)
    {
        var snapshots = Read(0, default, 0, 0);
        if (filter is null) return snapshots;
        return Array.AsReadOnly(snapshots
            .Where(snapshot => resolveOwnerApplicationIdentifier is null
                ? filter.Includes(snapshot)
                : filter.IncludesWithResolver(snapshot, resolveOwnerApplicationIdentifier))
            .ToArray());
    }
    /// <summary>Snapshot the foreground window without activating another window.</summary>
    public static WindowSnapshot GetForegroundWindow() => Read(1, default, 0, 0).Single();
    /// <summary>Capture the foreground identity without reading the title, frame or window state.</summary>
    /// <exception cref="WindowOperationException">The foreground window is unavailable or changed during capture.</exception>
    public static WindowIdentity GetForegroundWindowIdentity()
    {
        CheckPlatform();
        var result = Native.ForegroundIdentity();
        if (result.Code != 0) throw new WindowOperationException(result.Code, result.NativeError);
        return result.Identity;
    }
    /// <summary>Read a window and recheck its captured process and thread before returning the snapshot.</summary>
    public static WindowSnapshot GetWindow(WindowIdentity identity) => Read(2, identity, 0, 0).Single();
    /// <summary>Read the root window at a physical virtual-desktop point. Fractional coordinates sample the containing pixel.</summary>
    public static WindowSnapshot GetWindowAt(double x, double y) => Read(3, default, x, y).Single();

    /// <summary>Find the topmost visible, non-minimized window with bounds containing the physical
    /// virtual-desktop point. Uses the containing pixel and native enumeration order. Tool windows
    /// and DWM-cloaked windows are excluded. Input-region transparency does not affect this query.</summary>
    public static WindowHitTestResult HitTest(double x, double y, WindowSnapshotFilter? filter = null) =>
        WindowHitTestResult.FirstMatch(() => Read(4, default, x, y), filter, null);

    /// <summary>Find the topmost matching window by bounds. Resolve application metadata only for
    /// candidates that contain the point and pass numeric filter conditions, stopping at the first hit.
    /// Return null from the resolver when the application identifier is unavailable.</summary>
    public static WindowHitTestResult HitTest(
        double x, double y, WindowSnapshotFilter filter,
        Func<WindowIdentity, string?> resolveOwnerApplicationIdentifier)
    {
        ArgumentNullException.ThrowIfNull(filter);
        ArgumentNullException.ThrowIfNull(resolveOwnerApplicationIdentifier);
        return WindowHitTestResult.FirstMatch(
            () => Read(4, default, x, y), filter, resolveOwnerApplicationIdentifier);
    }

    private static System.Collections.ObjectModel.ReadOnlyCollection<WindowSnapshot> Read(uint kind, WindowIdentity identity, double x, double y) { CheckPlatform(); using var query = Native.Query(kind, identity, x, y); return Windows(query); }
    /// <summary>Read full and usable monitor areas. No permission or global DPI setting changes.</summary>
    public static IReadOnlyList<Display> GetDisplays()
    {
        CheckPlatform(); using var query = Native.Displays(); var view = Check(query); var result = new Display[checked((int)view.DisplayCount)];
        for (var i = 0; i < result.Length; i++) result[i] = view.Displays[i].Read();
        return Array.AsReadOnly(result);
    }
    /// <summary>Set finite physical coordinates and return the actual constrained native frame.</summary>
    public static WindowSnapshot SetFrame(WindowIdentity identity, Rect frame) => Command(identity, 0, frame).Single();
    /// <summary>Restore a captured window using native placement behavior.</summary>
    public static WindowSnapshot Restore(WindowIdentity identity) => Command(identity, 1, default).Single();
    /// <summary>Minimize a captured window using native placement behavior.</summary>
    public static WindowSnapshot Minimize(WindowIdentity identity) => Command(identity, 2, default).Single();
    /// <summary>Maximize a captured window using native placement behavior.</summary>
    public static WindowSnapshot Maximize(WindowIdentity identity) => Command(identity, 3, default).Single();
    /// <summary>Post a close request. Success acknowledges queueing, not destruction or saved data.</summary>
    public static void RequestClose(WindowIdentity identity) => Command(identity, 4, default);
    /// <summary>Place a captured window using shared display/frame resolution. Fallback is explicit.</summary>
    public static WindowSnapshot Place(WindowIdentity identity, WindowPlacementRequest request, bool fallback = false)
    { ArgumentNullException.ThrowIfNull(request); return Request(identity, 0, request.ToJson(), fallback); }
    /// <summary>Move a captured window between ordered displays. A window already on the only display stays unchanged. Fallback is explicit.</summary>
    public static WindowSnapshot MoveToAdjacentDisplay(WindowIdentity identity, WindowMoveRequest request, bool fallback = false)
    { ArgumentNullException.ThrowIfNull(request); return Request(identity, 1, request.ToJson(), fallback); }
    private static WindowSnapshot Request(WindowIdentity identity, uint kind, string json, bool fallback)
    {
        CheckPlatform(); var bytes = Encoding.UTF8.GetBytes(json);
        fixed (byte* data = bytes) { using var query = Native.Request(identity, kind, data, (nuint)bytes.Length, fallback ? 1u : 0u); return Windows(query).Single(); }
    }
    private static System.Collections.ObjectModel.ReadOnlyCollection<WindowSnapshot> Command(WindowIdentity identity, uint operation, Rect frame) { CheckPlatform(); using var query = Native.Command(identity, operation, frame); return Windows(query); }
    private static QueryView Check(QueryHandle query)
    {
        if (query.IsInvalid) throw new InvalidDataException("Missing native query.");
        var view = Native.View(query);
        if (view.Code != 0) throw new WindowOperationException(view.Code, view.NativeError);
        return view;
    }
    private static System.Collections.ObjectModel.ReadOnlyCollection<WindowSnapshot> Windows(QueryHandle query)
    {
        var view = Check(query); var result = new WindowSnapshot[checked((int)view.Count)];
        for (var i = 0; i < result.Length; i++) { var value = Native.Window(query, (nuint)i); result[i] = new(value.Identity, value.Frame, Encoding.UTF8.GetString(new ReadOnlySpan<byte>(value.Title, checked((int)value.TitleLength))), value.Minimized != 0, value.Maximized != 0); }
        return Array.AsReadOnly(result);
    }
}
