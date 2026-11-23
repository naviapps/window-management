using System.Runtime.InteropServices;
namespace NaviApps.WindowManagement;

/// <summary>A rectangle in one caller-selected coordinate space. Rust normalizes geometry.</summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct Rect(double X, double Y, double Width, double Height);
/// <summary>Immutable display metadata in the caller's coordinate space. Frames are standardized in Rust.
/// Native Windows queries use physical pixels.</summary>
public readonly record struct Display(Rect Frame, Rect VisibleFrame, ulong? Identifier, bool IsMain)
{
    private readonly Rect frame = Geometry.Normalize(Frame);
    private readonly Rect visibleFrame = Geometry.Normalize(VisibleFrame);

    /// <summary>Finite standardized display bounds.</summary>
    public Rect Frame { get => frame; init => frame = Geometry.Normalize(value); }
    /// <summary>Finite standardized usable bounds excluding system-reserved areas.</summary>
    public Rect VisibleFrame { get => visibleFrame; init => visibleFrame = Geometry.Normalize(value); }
}
/// <summary>Shared geometry and display ordering. No native window is queried or changed.</summary>
public static unsafe class Geometry
{
    /// <summary>Standardize negative dimensions and invalid scalars, retaining finite edges.</summary>
    public static Rect Normalize(Rect rect) { Native.EnsureAbi(); return Native.Normalize(rect); }
    /// <summary>Rust-owned containment in the same coordinate space. Minimum edges included, maximum excluded.</summary>
    public static bool Contains(Rect rect, double x, double y) { Native.EnsureAbi(); return Native.Contains(rect, x, y) == 1; }
    /// <summary>Fill the supplied area after clamping a uniform inset.</summary>
    public static Rect Fill(Rect area, double inset = 0) => Place(area, inset, default);
    /// <summary>Resolve a clamped grid region. Row zero starts at the area's minimum Y.</summary>
    public static Rect Grid(Rect area, long columns, long rows, long column, long row, long columnSpan = 1, long rowSpan = 1, double inset = 0) => Place(area, inset, new() { Kind = 1, Columns = columns, Rows = rows, Column = column, Row = row, ColumnSpan = columnSpan, RowSpan = rowSpan });
    /// <summary>Center using ratios clamped to zero through one.</summary>
    public static Rect Centered(Rect area, double widthRatio, double heightRatio, double inset = 0) => Place(area, inset, new() { Kind = 2, WidthRatio = widthRatio, HeightRatio = heightRatio });
    private static Rect Place(Rect area, double inset, NativePlacement placement)
    {
        Native.EnsureAbi();
        var result = Native.Place(placement, area, inset); if (result.Code != 0) throw new ArgumentException("Invalid native placement."); return result.Frame;
    }
    /// <summary>Resolve reusable geometry in one caller-selected coordinate space.</summary>
    public static Rect Frame(WindowPlacement placement, Rect area, double inset = 0)
    { ArgumentNullException.ThrowIfNull(placement); return Place(area, inset, placement.Value); }
    /// <summary>Resolve placement with explicit fallback policy; null means no display match.</summary>
    public static Rect? ResolvePlacement(WindowPlacementRequest request, Rect window, ReadOnlySpan<Display> displays, bool fallback = false)
    {
        ArgumentNullException.ThrowIfNull(request); Native.EnsureAbi();
        var native = CopyDisplays(displays);
        fixed (NativeDisplay* data = native) return Resolved(Native.ResolvePlacement(request.Value, window, data, (nuint)native.Length, fallback ? 1u : 0u));
    }
    /// <summary>Resolve ordered-display movement in Rust. A window already on the only display keeps its normalized frame. Null means no display match.</summary>
    public static Rect? ResolveMovement(WindowMoveRequest request, Rect window, ReadOnlySpan<Display> displays, bool fallback = false)
    {
        ArgumentNullException.ThrowIfNull(request); Native.EnsureAbi();
        var native = CopyDisplays(displays);
        fixed (NativeDisplay* data = native) return Resolved(Native.ResolveMovement(request.Value, window, data, (nuint)native.Length, fallback ? 1u : 0u));
    }
    private static Rect? Resolved(RectResult result) => result.Code switch
    {
        0 => result.Frame,
        2 => null,
        _ => throw new InvalidDataException("Invalid native window request or buffer."),
    };
    /// <summary>Move a window into another usable area, preserving relative position or centering.</summary>
    public static Rect Move(Rect window, Rect source, Rect target, bool preservePosition = true) { Native.EnsureAbi(); return Native.Move(window, source, target, preservePosition ? 1u : 0u); }
    /// <summary>Wrap a signed display index; null means an empty/invalid display count.</summary>
    public static long? AdjacentIndex(long index, bool previous, long count) { Native.EnsureAbi(); var result = Native.Adjacent(index, previous ? 1u : 0u, count); return result < 0 ? null : result; }
    /// <summary>Return stable display indices in increasing X, Y, dimensions and identifier order.</summary>
    public static nuint[] OrderedIndices(ReadOnlySpan<Display> displays) => Order(CopyDisplays(displays));

    /// <summary>Return a copy of the displays in stable Rust-defined order.</summary>
    public static Display[] OrderedDisplays(ReadOnlySpan<Display> displays)
    {
        var indices = OrderedIndices(displays);
        var result = new Display[indices.Length];
        for (var i = 0; i < result.Length; i++) result[i] = displays[(int)indices[i]];
        return result;
    }

    /// <summary>Resolve the supplied display target without querying the OS. Pass false to reject unmatched targets.</summary>
    public static Display? SelectDisplay(DisplayTarget target, Rect window, ReadOnlySpan<Display> displays, bool fallback = true)
    {
        ArgumentNullException.ThrowIfNull(target);
        var selected = SelectOriginalIndex(target.SelectionValue, window, CopyDisplays(displays), fallback);
        return selected < 0 ? null : displays[(int)selected];
    }

    /// <summary>Return the ordered index of the display containing a point. Maximum edges are excluded.</summary>
    public static int? IndexContainingPoint(double x, double y, ReadOnlySpan<Display> displays)
    {
        Native.EnsureAbi();
        var native = CopyDisplays(displays);
        fixed (NativeDisplay* data = native)
        {
            var selected = Native.IndexContainingPoint(data, (nuint)native.Length, x, y);
            return selected < 0 ? null : (int)selected;
        }
    }

    private static NativeDisplay[] CopyDisplays(ReadOnlySpan<Display> displays)
    {
        var result = new NativeDisplay[displays.Length];
        for (var i = 0; i < result.Length; i++) result[i] = NativeDisplay.From(displays[i]);
        return result;
    }

    private static long SelectOriginalIndex(NativeDisplayTarget target, Rect window, ReadOnlySpan<NativeDisplay> displays, bool fallback)
    {
        Native.EnsureAbi();
        fixed (NativeDisplay* data = displays)
            return Native.Select(data, (nuint)displays.Length, target.Kind, window, target.X, target.Y,
                target.Identifier, target.Index, fallback ? 1u : 0u);
    }

    private static nuint[] Order(ReadOnlySpan<NativeDisplay> displays)
    {
        Native.EnsureAbi();
        var indices = new nuint[displays.Length];
        fixed (NativeDisplay* data = displays)
        fixed (nuint* output = indices)
            if (Native.Order(data, (nuint)displays.Length, output, (nuint)indices.Length) != (nuint)indices.Length)
                throw new InvalidDataException("Invalid native display order.");
        return indices;
    }
}
