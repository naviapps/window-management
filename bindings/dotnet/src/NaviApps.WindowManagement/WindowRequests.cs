using System.Text;
using System.Text.Json;
namespace NaviApps.WindowManagement;

/// <summary>Malformed window request data rejected by the shared Rust codec.</summary>
public sealed class WindowDataException : FormatException
{
    internal WindowDataException(string message) : base(message) { }
}
internal static class WindowJson
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    internal static byte[] EncodeUtf8(string value)
    {
        try { return StrictUtf8.GetBytes(value); }
        catch (EncoderFallbackException) { throw new WindowDataException("Window data contains invalid Unicode."); }
    }

    internal static void ValidateUnicode(string value)
    {
        try { _ = StrictUtf8.GetByteCount(value); }
        catch (EncoderFallbackException) { throw new WindowDataException("Window data contains invalid Unicode."); }
    }

    internal static string Normalize(uint kind, ReadOnlySpan<byte> json) => Encoding.UTF8.GetString(Native.ValueJson(kind, json));
}

/// <summary>Reusable placement normalized in Rust. The factories do not query or control windows.</summary>
public sealed class WindowPlacement
{
    internal NativePlacement Value { get; }
    private WindowPlacement(NativePlacement value)
    {
        Native.EnsureAbi(); var result = Native.NormalizePlacement(value);
        if (result.Code != 0) throw new WindowDataException("Invalid placement kind.");
        Value = result.Value;
    }
    /// <summary>Fill the selected area.</summary>
    public static WindowPlacement Fill { get; } = new(default);
    /// <summary>A clamped grid rectangle. Row zero begins at minimum Y.</summary>
    public static WindowPlacement Grid(long columns, long rows, long column, long row, long columnSpan = 1, long rowSpan = 1) =>
        new(new() { Kind = 1, Columns = columns, Rows = rows, Column = column, Row = row, ColumnSpan = columnSpan, RowSpan = rowSpan });
    /// <summary>Center using ratios normalized into zero through one, including non-finite inputs.</summary>
    public static WindowPlacement Centered(double widthRatio, double heightRatio) => new(new() { Kind = 2, WidthRatio = widthRatio, HeightRatio = heightRatio });
    /// <summary>Canonical tagged placement JSON.</summary>
    public string ToJson() => Native.ToJson(Value);
    /// <summary>Strictly parse and normalize tagged placement JSON.</summary>
    public static WindowPlacement FromJson(string json)
    {
        using var document = JsonDocument.Parse(Native.ValueJson(0, WindowJson.EncodeUtf8(json)));
        return FromCanonical(document.RootElement);
    }

    internal static WindowPlacement FromCanonical(JsonElement value) =>
        value.GetProperty("kind").GetString() switch
        {
            "fill" => Fill,
            "grid" => Grid(value.GetProperty("columns").GetInt64(), value.GetProperty("rows").GetInt64(), value.GetProperty("column").GetInt64(), value.GetProperty("row").GetInt64(), value.GetProperty("columnSpan").GetInt64(), value.GetProperty("rowSpan").GetInt64()),
            "centered" => Centered(value.GetProperty("widthRatio").GetDouble(), value.GetProperty("heightRatio").GetDouble()),
            _ => throw new WindowDataException("Unsupported canonical placement."),
        };
}

/// <summary>Platform-native display selection. Identifiers belong to their native platform. Stored requests are normalized in Rust.</summary>
public sealed class DisplayTarget
{
    internal NativeDisplayTarget SelectionValue { get; }
    internal NativeDisplayTarget Value { get; }
    private DisplayTarget(NativeDisplayTarget value)
    {
        Native.EnsureAbi(); var result = Native.NormalizeTarget(value);
        if (result.Code != 0) throw new WindowDataException("Invalid display target.");
        SelectionValue = value;
        Value = result.Value;
    }
    private DisplayTarget(NativeDisplayTarget value, NativeDisplayTarget selectionValue)
    {
        Value = value;
        SelectionValue = selectionValue;
    }
    internal DisplayTarget Normalized() => SelectionValue.Equals(Value) ? this : new(Value, Value);
    /// <summary>The main display.</summary>
    public static DisplayTarget Main { get; } = new(default);
    /// <summary>The display with greatest positive window overlap. Equal areas prefer center
    /// containment, then stable display order. Zero-sized windows use center containment alone.</summary>
    public static DisplayTarget ContainingWindow { get; } = new(new() { Kind = 1 });
    /// <summary>The display containing a point in the supplied display coordinate space.</summary>
    public static DisplayTarget Point(double x, double y) => new(new() { Kind = 2, X = x, Y = y });
    /// <summary>The display with this native display identifier; zero remains a valid identifier.</summary>
    public static DisplayTarget DisplayIdentifier(ulong identifier) => new(new() { Kind = 3, Identifier = identifier });
    /// <summary>The display at a nonnegative index in deterministic display order.</summary>
    public static DisplayTarget OrderedIndex(long index) => new(new() { Kind = 4, Index = index });
    /// <summary>Canonical tagged selection JSON.</summary>
    public string ToJson() => Native.ToJson(Value);
    /// <summary>Strictly parse and normalize tagged selection JSON.</summary>
    public static DisplayTarget FromJson(string json)
    {
        using var document = JsonDocument.Parse(Native.ValueJson(1, WindowJson.EncodeUtf8(json)));
        return FromCanonical(document.RootElement);
    }

    internal static DisplayTarget FromCanonical(JsonElement value) =>
        value.GetProperty("kind").GetString() switch
        {
            "main" => Main,
            "containing-window" => ContainingWindow,
            "point" => Point(value.GetProperty("x").GetDouble(), value.GetProperty("y").GetDouble()),
            "display-identifier" => DisplayIdentifier(value.GetProperty("displayIdentifier").GetUInt64()),
            "ordered-index" => OrderedIndex(value.GetProperty("orderedIndex").GetInt64()),
            _ => throw new WindowDataException("Unsupported canonical display target."),
        };
}

/// <summary>Display area used by placement.</summary>
public enum DisplayArea
{
    /// <summary>Exclude system-reserved areas.</summary>
    Visible,
    /// <summary>Use the entire display rectangle.</summary>
    Full,
}
/// <summary>Direction in deterministic display order.</summary>
public enum DisplayCycleDirection
{
    /// <summary>Next display, wrapping at the end.</summary>
    Next,
    /// <summary>Previous display, wrapping at the beginning.</summary>
    Previous,
}

/// <summary>Immutable reusable placement request. Rust owns validation and normalization.</summary>
public sealed class WindowPlacementRequest
{
    private readonly string json;
    /// <summary>Normalized placement geometry.</summary>
    public WindowPlacement Placement { get; }
    /// <summary>Normalized display selection.</summary>
    public DisplayTarget Display { get; }
    /// <summary>Full or usable display area.</summary>
    public DisplayArea Area { get; }
    /// <summary>Finite nonnegative inset.</summary>
    public double Inset { get; }
    internal NativePlacementRequest Value => new() { Placement = Placement.Value, Display = Display.Value, Area = (uint)Area, Inset = Inset };
    /// <summary>Create a request. Default selection is the containing window's usable area.</summary>
    public WindowPlacementRequest(WindowPlacement placement, DisplayTarget? display = null, DisplayArea area = DisplayArea.Visible, double inset = 0)
        : this(placement, display, area, inset, null) { }

    private WindowPlacementRequest(WindowPlacement placement, DisplayTarget? display, DisplayArea area, double inset, string? canonicalJson)
    {
        ArgumentNullException.ThrowIfNull(placement);
        Placement = placement; Display = (display ?? DisplayTarget.ContainingWindow).Normalized(); Area = area;
        Native.EnsureAbi(); Inset = Native.NormalizeInset(inset);
        json = canonicalJson ?? Native.ToJson(Value);
    }
    /// <summary>Canonical request JSON, also accepted by DesktopActions window-placement inputs.</summary>
    public string ToJson() => json;
    /// <summary>Parse strict JSON in Rust before projecting canonical fields into managed values.</summary>
    public static WindowPlacementRequest FromJson(string json) => FromJsonUtf8(WindowJson.EncodeUtf8(json));
    /// <summary>Parse original UTF-8 bytes in Rust, including strict field and duplicate-key checks.</summary>
    public static WindowPlacementRequest FromJsonUtf8(ReadOnlySpan<byte> json)
    {
        var canonical = WindowJson.Normalize(2, json);
        using var document = JsonDocument.Parse(canonical);
        var value = document.RootElement;
        return new(WindowPlacement.FromCanonical(value.GetProperty("placement")), DisplayTarget.FromCanonical(value.GetProperty("screen")),
            value.GetProperty("area").GetString() == "full" ? DisplayArea.Full : DisplayArea.Visible, value.GetProperty("inset").GetDouble(), canonical);
    }
}

/// <summary>Immutable adjacent-display movement request, including the relative-position policy.</summary>
public sealed class WindowMoveRequest
{
    private readonly string json;
    /// <summary>Movement direction.</summary>
    public DisplayCycleDirection Direction { get; }
    /// <summary>Preserve relative position, or center while preserving size.</summary>
    public bool PreservesRelativePosition { get; }
    internal NativeMoveRequest Value => new() { Direction = (uint)Direction, PreservesRelativePosition = PreservesRelativePosition ? 1u : 0u };
    /// <summary>Create a movement request with Rust validation.</summary>
    public WindowMoveRequest(DisplayCycleDirection direction, bool preservesRelativePosition = true)
        : this(direction, preservesRelativePosition, null) { }

    private WindowMoveRequest(DisplayCycleDirection direction, bool preservesRelativePosition, string? canonicalJson)
    {
        Direction = direction; PreservesRelativePosition = preservesRelativePosition;
        json = canonicalJson ?? Native.ToJson(Value);
    }
    /// <summary>Canonical movement request JSON.</summary>
    public string ToJson() => json;
    /// <summary>Strictly parse movement JSON and shared defaults.</summary>
    public static WindowMoveRequest FromJson(string json) => FromJsonUtf8(WindowJson.EncodeUtf8(json));
    /// <summary>Parse original UTF-8 movement JSON with the same Rust schema.</summary>
    public static WindowMoveRequest FromJsonUtf8(ReadOnlySpan<byte> json)
    {
        var canonical = WindowJson.Normalize(3, json);
        using var document = JsonDocument.Parse(canonical);
        var value = document.RootElement;
        return new(value.GetProperty("direction").GetString() == "next" ? DisplayCycleDirection.Next : DisplayCycleDirection.Previous, value.GetProperty("preservesRelativePosition").GetBoolean(), canonical);
    }
}
