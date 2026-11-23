using NaviApps.WindowManagement;
using System.Text.Json;
static void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}, got {actual}"); }
static void RejectsWindowData(Action operation)
{
    try { operation(); throw new InvalidOperationException("Accepted invalid window data"); }
    catch (WindowDataException) { }
}
Equal(new Rect(0, 0, 100, 80), Geometry.Normalize(new(100, 80, -100, -80)));
Equal(true, Geometry.Contains(new(0, 0, 100, 80), 0, 0));
Equal(false, Geometry.Contains(new(0, 0, 100, 80), 100, 0));
Equal(false, Geometry.Contains(new(0, 0, 100, 80), double.NaN, 0));
var snapshot = new WindowSnapshot(new(ulong.MaxValue, 12, 13), default, "owned", false, false);
var restoredSnapshot = JsonSerializer.Deserialize<WindowSnapshot>("""
    {"Identity":{"Handle":456,"ProcessId":123,"ThreadId":120},
    "Frame":{"X":100,"Y":100,"Width":-80,"Height":-60},"Title":"Recording","IsMinimized":false,"IsMaximized":true}
    """) ?? throw new InvalidOperationException("Could not restore snapshot.");
Equal(new Rect(20, 40, 80, 60), restoredSnapshot.Frame);
Equal(new WindowIdentity(456, 123, 120), restoredSnapshot.Identity);
Equal("Recording", restoredSnapshot.Title);
Equal(true, restoredSnapshot.IsMaximized);
Equal(true, restoredSnapshot.Contains(restoredSnapshot.Frame.X, restoredSnapshot.Frame.Y));
Equal(false, restoredSnapshot.Contains(restoredSnapshot.Frame.X + restoredSnapshot.Frame.Width, restoredSnapshot.Frame.Y));
var editedSnapshot = restoredSnapshot with { Frame = new Rect(600, 500, -400, -300) };
Equal(new Rect(200, 200, 400, 300), editedSnapshot.Frame);
Equal(restoredSnapshot.Identity, editedSnapshot.Identity);
Equal(true, editedSnapshot.Contains(200, 200));
var front = snapshot with { Identity = new(43, 12, 13) };
var back = snapshot with { Identity = new(44, 12, 13) };
Equal(WindowHitTestResult.Hit(front), WindowHitTestResult.FirstMatch(() => [front, back], null, null));
Equal(WindowHitTestMissReason.NoMatchingWindowAtPoint,
    WindowHitTestResult.FirstMatch(() => [], null, null).MissReason);
Equal(WindowHitTestMissReason.SourceUnavailable,
    WindowHitTestResult.FirstMatch(() => throw new WindowOperationException(5, 0), null, null).MissReason);
using (var hitFilter = new WindowSnapshotFilter(
    includedOwnerApplicationIdentifiers: ["owned"], excludedWindowIdentifiers: [front.Identity.Handle]))
{
    var resolved = new List<WindowIdentity>();
    Equal(WindowHitTestResult.Hit(back), WindowHitTestResult.FirstMatch(() => [front, back, snapshot], hitFilter, identity =>
    {
        resolved.Add(identity);
        return "owned";
    }));
    Equal(true, resolved.SequenceEqual([back.Identity]));
    Equal(WindowHitTestMissReason.NoMatchingWindowAtPoint,
        WindowHitTestResult.FirstMatch(() => [front, back], hitFilter, _ => null).MissReason);
    var resolverFailure = new WindowOperationException(5, 0);
    try
    {
        _ = WindowHitTestResult.FirstMatch(() => [back], hitFilter, _ => throw resolverFailure);
        throw new InvalidOperationException("The hit test suppressed a resolver failure.");
    }
    catch (WindowOperationException error) when (ReferenceEquals(error, resolverFailure)) { }
}
using (var filter = new WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["example.日本"], includedOwnerProcessIdentifiers: [12], includedWindowIdentifiers: [ulong.MaxValue]))
{
    Equal(true, filter.Includes(snapshot, "example.日本"));
    Equal(false, filter.Includes(snapshot));
    Equal(false, filter.Includes(snapshot with { Identity = new(1, 12, 13) }, "example.日本"));
    Equal(true, filter.ToJson().Contains("includedOwnerApplicationIdentifiers"));
    Equal(false, filter.ToJson().Contains("OwnerBundleIdentifiers"));
    using var copy = WindowSnapshotFilter.FromJson(filter.ToJson());
    Parallel.For(0, 32, _ => Equal(true, copy.Includes(snapshot, "example.日本")));
}
const string embeddedNullIdentifier = "日本語😀\0window";
using (var optionalApplication = new WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["", embeddedNullIdentifier]))
{
    Equal(true, optionalApplication.Includes(snapshot, ""));
    Equal(true, optionalApplication.Includes(snapshot, embeddedNullIdentifier));
    Equal(false, optionalApplication.Includes(snapshot));
    Equal(false, optionalApplication.Includes(snapshot, "日本語😀"));
}
var narrowSnapshot = snapshot with { Identity = new(222, 111, 13) };
using (var wide = WindowSnapshotFilter.FromJsonUtf8("""
    {"includedOwnerProcessIdentifiers":[111,-9223372036854775808,9223372036854775807],
     "includedWindowIdentifiers":[222,18446744073709551615],
     "excludedOwnerProcessIdentifiers":[4294967407],"excludedWindowIdentifiers":[4294967518]}
    """u8))
{
    Equal(true, wide.Includes(narrowSnapshot));
    using var fields = JsonDocument.Parse(wide.ToJson());
    Equal(long.MinValue, fields.RootElement.GetProperty("includedOwnerProcessIdentifiers")[0].GetInt64());
    Equal(long.MaxValue, fields.RootElement.GetProperty("includedOwnerProcessIdentifiers")[2].GetInt64());
    Equal(ulong.MaxValue, fields.RootElement.GetProperty("includedWindowIdentifiers")[1].GetUInt64());
    using var roundTrip = WindowSnapshotFilter.FromJson(wide.ToJson());
    Equal(wide.ToJson(), roundTrip.ToJson());
}
const string invalidApplicationIdentifier = "\uD800";
using (var replacement = new WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["\uFFFD"]))
{
    Equal(true, replacement.Includes(snapshot, "\uFFFD"));
    RejectsWindowData(() => replacement.Includes(snapshot, invalidApplicationIdentifier));
}
RejectsWindowData(() => { using var invalid = new WindowSnapshotFilter(includedOwnerApplicationIdentifiers: [invalidApplicationIdentifier]); });
RejectsWindowData(() => { using var invalid = new WindowSnapshotFilter(excludedOwnerApplicationIdentifiers: [invalidApplicationIdentifier]); });
RejectsWindowData(() => { using var invalid = WindowSnapshotFilter.FromJson("{\"includedOwnerApplicationIdentifiers\":[\"" + invalidApplicationIdentifier + "\"]}"); });
using (var opaque = WindowSnapshotFilter.FromJsonUtf8("""{"includedOwnerApplicationIdentifiers":["\u00e9","e\u0301"],"excludedOwnerApplicationIdentifiers":["e\u0301"]}"""u8))
{
    Equal(true, opaque.Includes(snapshot, "\u00E9"));
    Equal(false, opaque.Includes(snapshot, "e\u0301"));
}
RejectsWindowData(() =>
{
    var malformed = """{"includedOwnerApplicationIdentifiers":["!"]}"""u8.ToArray();
    malformed[Array.IndexOf(malformed, (byte)'!')] = 0xff;
    using var invalid = WindowSnapshotFilter.FromJsonUtf8(malformed);
});
using (var empty = WindowSnapshotFilter.FromJson("{}")) Equal(true, empty.Includes(snapshot));
RejectsWindowData(() =>
{
    using var invalid = WindowSnapshotFilter.FromJsonUtf8("""{"includedWindowIdentifiers":[1],"includedWindowIdentifiers":[2]}"""u8);
});
Equal(new Rect(50, 0, 50, 80), Geometry.Grid(new(0, 0, 100, 80), 2, 1, 1, 0));
// Exercise the same precision-sensitive ABI projection as the Swift binding.
var smallest = double.Epsilon;
Equal(new Rect(smallest, smallest, smallest, smallest), Geometry.Grid(new(0, 0, 2 * smallest, 2 * smallest), 8, 8, 4, 4, 4, 4));
Equal(new Rect(25, 20, 50, 40), Geometry.Centered(new(0, 0, 100, 80), 0.5, 0.5));
Equal(new Rect(0, 20, 100, 40), Geometry.Move(new(0, 0, 200, 40), default, new(0, 0, 100, 80), false));
Equal<long?>(long.MaxValue - 2, Geometry.AdjacentIndex(long.MinValue, true, long.MaxValue));
Equal<long?>(null, Geometry.AdjacentIndex(long.MaxValue, false, long.MinValue));
Equal<ulong?>(0, new Display(default, default, 0, true).Identifier);
var restoredDisplay = JsonSerializer.Deserialize<Display>("""
    {"Frame":{"X":800,"Y":600,"Width":-800,"Height":-600},
    "VisibleFrame":{"X":800,"Y":600,"Width":-780,"Height":-560},"Identifier":123,"IsMain":true}
    """);
Equal(new Rect(0, 0, 800, 600), restoredDisplay.Frame);
Equal(new Rect(20, 40, 780, 560), restoredDisplay.VisibleFrame);
Equal<ulong?>(123, restoredDisplay.Identifier);
Equal(true, restoredDisplay.IsMain);
var updatedDisplay = restoredDisplay with { Frame = new Rect(600, 500, -400, -300), VisibleFrame = new Rect(double.NaN, double.PositiveInfinity, double.NegativeInfinity, double.NaN) };
var (updatedFrame, updatedVisibleFrame, updatedIdentifier, updatedIsMain) = updatedDisplay;
Equal(new Rect(200, 200, 400, 300), updatedFrame);
Equal(default, updatedVisibleFrame);
Equal(restoredDisplay.Identifier, updatedIdentifier);
Equal(restoredDisplay.IsMain, updatedIsMain);
var indices = Geometry.OrderedIndices([new(new(100, 0, 100, 100), default, 1, false), new(new(0, 0, 100, 100), default, 0, true)]);
Equal((nuint)1, indices[0]); Equal((nuint)0, indices[1]);
var grid = WindowPlacement.Grid(0, 2, -1, 10, 20, 0);
Equal(new Rect(0, 40, 100, 40), Geometry.Frame(grid, new(0, 0, 100, 80)));
var placement = new WindowPlacementRequest(WindowPlacement.Centered(double.PositiveInfinity, double.NaN), DisplayTarget.DisplayIdentifier(ulong.MaxValue), inset: double.PositiveInfinity);
Equal(0.0, placement.Inset);
Equal(placement.ToJson(), WindowPlacementRequest.FromJson(placement.ToJson()).ToJson());
var defaults = WindowPlacementRequest.FromJson("{\"placement\":{\"kind\":\"fill\"}}");
Equal(DisplayArea.Visible, defaults.Area);
Equal("{\"kind\":\"containing-window\"}", defaults.Display.ToJson());
Equal(true, ReferenceEquals(DisplayTarget.ContainingWindow, defaults.Display));
var preciseRequest = WindowPlacementRequest.FromJsonUtf8("""{"placement":{"kind":"fill"},"screen":{"kind":"point","x":-0.0,"y":5e-324}}"""u8);
using (var coordinates = JsonDocument.Parse(preciseRequest.Display.ToJson()))
{
    Equal(BitConverter.DoubleToInt64Bits(-0.0), BitConverter.DoubleToInt64Bits(coordinates.RootElement.GetProperty("x").GetDouble()));
    Equal(double.Epsilon, coordinates.RootElement.GetProperty("y").GetDouble());
}
Equal(preciseRequest.ToJson(), new WindowPlacementRequest(WindowPlacement.Fill, DisplayTarget.Point(-0.0, double.Epsilon)).ToJson());
var displays = new Display[] { new(new(100, 0, 100, 80), new(100, 0, 100, 80), 2, false), new(new(0, 0, 100, 80), new(0, 0, 100, 80), 0, true) };
Equal<Display?>(displays[1], Geometry.SelectDisplay(DisplayTarget.Main, displays[0].Frame, displays, false));
Equal<Display?>(displays[0], Geometry.SelectDisplay(DisplayTarget.DisplayIdentifier(2), default, displays, false));
Equal<Display?>(displays[1], Geometry.SelectDisplay(DisplayTarget.DisplayIdentifier(0), default, displays, false));
Equal<Display?>(displays[0], Geometry.SelectDisplay(DisplayTarget.OrderedIndex(1), default, displays, false));
Equal<Display?>(displays[0], Geometry.SelectDisplay(DisplayTarget.Point(100, 10), default, displays, false));
Equal<Display?>(displays[0], Geometry.SelectDisplay(DisplayTarget.ContainingWindow, new(50, 0, 100, 80), displays, false));
Equal<Display?>(null, Geometry.SelectDisplay(DisplayTarget.Main, default, []));
Equal<Display?>(null, Geometry.SelectDisplay(DisplayTarget.DisplayIdentifier(99), default, displays, false));
Equal<Display?>(displays[1], Geometry.SelectDisplay(DisplayTarget.DisplayIdentifier(99), default, displays));
Equal<int?>(1, Geometry.IndexContainingPoint(100, 10, displays));
Equal<int?>(null, Geometry.IndexContainingPoint(200, 10, displays));
var tiedDisplays = new[] { displays[1] with { VisibleFrame = default, IsMain = false }, displays[1] };
Equal<Display?>(tiedDisplays[0], Geometry.SelectDisplay(DisplayTarget.Point(0, 10), default, tiedDisplays));
var zeroOrigin = new Display(new(0, 0, 100, 100), new(0, 10, 100, 90), 1, false);
var larger = zeroOrigin with { Frame = new(-0.0, -0.0, 200, 100), Identifier = 0 };
var higherIdentifier = zeroOrigin with { Frame = new(-0.0, 0, 100, 100), Identifier = 9 };
var missingIdentifier = zeroOrigin with { Frame = new(0, -0.0, 100, 100), Identifier = null };
var duplicateIdentifier = zeroOrigin with { Frame = new(-0.0, -0.0, 100, 100), VisibleFrame = new(0, 20, 100, 80) };
var zeroOriginDisplays = new[] { zeroOrigin, larger, higherIdentifier, missingIdentifier, duplicateIdentifier };
var orderedZeroOrigins = Geometry.OrderedDisplays(zeroOriginDisplays);
Equal(true, orderedZeroOrigins.SequenceEqual([zeroOrigin, duplicateIdentifier, higherIdentifier, missingIdentifier, larger]));
Equal(BitConverter.DoubleToInt64Bits(-0.0), BitConverter.DoubleToInt64Bits(orderedZeroOrigins[2].Frame.X));
Equal(BitConverter.DoubleToInt64Bits(-0.0), BitConverter.DoubleToInt64Bits(orderedZeroOrigins[3].Frame.Y));
foreach (var invalidTarget in new[] { DisplayTarget.Point(double.NaN, 10), DisplayTarget.OrderedIndex(-1) })
{
    Equal<Display?>(null, Geometry.SelectDisplay(invalidTarget, default, displays, false));
    Equal<Display?>(displays[1], Geometry.SelectDisplay(invalidTarget, default, displays));
    var normalizedRequest = new WindowPlacementRequest(WindowPlacement.Fill, invalidTarget);
    Equal<Display?>(displays[1], Geometry.SelectDisplay(normalizedRequest.Display, default, displays, false));
}
var request = new WindowPlacementRequest(WindowPlacement.Fill, DisplayTarget.DisplayIdentifier(99));
Equal<Rect?>(null, Geometry.ResolvePlacement(request, default, displays));
Equal<Rect?>(new(0, 0, 100, 80), Geometry.ResolvePlacement(request, default, displays, true));
var movement = new WindowMoveRequest(DisplayCycleDirection.Next);
Equal<Rect?>(new(125, 20, 50, 40), Geometry.ResolveMovement(movement, new(25, 20, 50, 40), displays));
Equal<Rect?>(null, Geometry.ResolveMovement(movement, default, [], true));
// Keep the ABI projection of a subnormal frame alongside the ordinary movement case.
var precisionDisplays = new Display[] {
    new(new(200,0,100,100),new(200,0,100,100),2,false),
    new(new(0,0,100,100),new(0,0,100,100),1,true),
};
var tiny = new Rect(1, 1, double.Epsilon, double.Epsilon);
Equal<Rect?>(new(250, 50, double.Epsilon, double.Epsilon), Geometry.ResolveMovement(new(DisplayCycleDirection.Next, false), tiny, precisionDisplays));
var restoredMovement = WindowMoveRequest.FromJsonUtf8("""{"direction":"next"}"""u8);
Equal(DisplayCycleDirection.Next, restoredMovement.Direction);
Equal(true, restoredMovement.PreservesRelativePosition);
Equal(movement.ToJson(), restoredMovement.ToJson());
RejectsWindowData(() => _ = WindowMoveRequest.FromJsonUtf8("""{"direction":"next","direction":"previous"}"""u8));
RejectsWindowData(() => _ = WindowPlacementRequest.FromJson("""{"placement":{"kind":"fill","extra":0}}"""));
RejectsWindowData(() => _ = WindowPlacementRequest.FromJsonUtf8("""{"placement":{"kind":"fill"},"inset":1,"inset":2}"""u8));
RejectsWindowData(() => _ = new WindowMoveRequest((DisplayCycleDirection)99));
Console.WriteLine("WindowManagement geometry/native ABI passed.");
