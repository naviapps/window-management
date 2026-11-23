using NaviApps.WindowManagement;
using System.Text.Json;
using var filter = WindowSnapshotFilter.FromJsonUtf8("""
    {"includedOwnerProcessIdentifiers":[12,-9223372036854775808],"includedWindowIdentifiers":[42,18446744073709551615]}
    """u8);
var snapshot = JsonSerializer.Deserialize<WindowSnapshot>("""
    {"Identity":{"Handle":18446744073709551615,"ProcessId":12,"ThreadId":13},
    "Frame":{"X":100,"Y":100,"Width":-80,"Height":-60},"Title":"owned","IsMinimized":false,"IsMaximized":false}
    """) ?? throw new InvalidOperationException("Could not restore the packaged snapshot.");
if (!filter.Includes(snapshot) || snapshot.Frame != new Rect(20, 40, 80, 60)
    || !snapshot.Contains(20, 40) || snapshot.Contains(100, 40))
    throw new InvalidOperationException("Packaged snapshot selector failed.");
if (WindowHitTestResult.Hit(snapshot).Snapshot != snapshot ||
    WindowHitTestResult.Miss(WindowHitTestMissReason.NoMatchingWindowAtPoint).Snapshot is not null)
    throw new InvalidOperationException("Packaged point-query result projection failed.");
if (OperatingSystem.IsWindows() && WindowsDesktop.HitTest(double.NaN, 0).MissReason != WindowHitTestMissReason.NoMatchingWindowAtPoint)
    throw new InvalidOperationException("Packaged native point-query did not return a typed miss.");
var frame = Geometry.Frame(WindowPlacement.Grid(2, 1, 1, 0), new Rect(0, 0, 1200, 800), 4);
if (frame != new Rect(600, 4, 596, 792)) throw new InvalidOperationException("Packaged native geometry failed.");
var tinyArea = new Rect(0, 0, double.Epsilon, double.Epsilon);
if (Geometry.Grid(tinyArea, 2, 2, 0, 0, 2, 2) != tinyArea)
    throw new InvalidOperationException("Packaged full grid span lost a positive extent.");
var smallest = double.Epsilon;
if (Geometry.Fill(new(0, 0, 3 * smallest, 7 * smallest), 1) != new Rect(2 * smallest, 2 * smallest, 0, 4 * smallest))
    throw new InvalidOperationException("Packaged inset failed to collapse the shorter dimension.");
var request = new WindowPlacementRequest(WindowPlacement.Fill, DisplayTarget.DisplayIdentifier(ulong.MaxValue));
var storedRequest = WindowPlacementRequest.FromJsonUtf8("""{"placement":{"kind":"fill"},"screen":{"kind":"display-identifier","displayIdentifier":18446744073709551615}}"""u8);
if (storedRequest.ToJson() != request.ToJson())
    throw new InvalidOperationException("Packaged request codec failed.");
var displays = new Display[] {
    JsonSerializer.Deserialize<Display>("""
        {"Frame":{"X":400,"Y":200,"Width":-300,"Height":-300},
        "VisibleFrame":{"X":400,"Y":200,"Width":-300,"Height":-280},"Identifier":2,"IsMain":false}
        """),
    new(new(-400,-100,200,300),new(-400,-100,200,300),1,true),
};
var spanning = new Rect(-250, -50, 450, 100);
if (Geometry.ResolvePlacement(new(WindowPlacement.Fill), spanning, displays) != displays[0].VisibleFrame
    || Geometry.SelectDisplay(DisplayTarget.ContainingWindow, spanning, displays, false) != displays[0]
    || Geometry.IndexContainingPoint(100, 0, displays) != 1)
    throw new InvalidOperationException("Packaged native display overlap selection failed.");
if (Geometry.ResolveMovement(new(DisplayCycleDirection.Next), spanning, displays.AsSpan(0, 1)) != spanning)
    throw new InvalidOperationException("Packaged adjacent movement changed a window on the only display.");
var coincident = new Display[] { new(new(0, 0, 100, 100), default, 1, false), new(new(-0.0, -0.0, 100, 100), default, 9, false) };
if (Geometry.SelectDisplay(DisplayTarget.Point(10, 10), default, coincident, false) != coincident[0])
    throw new InvalidOperationException("Packaged selection did not break a signed-zero display tie by identifier.");
