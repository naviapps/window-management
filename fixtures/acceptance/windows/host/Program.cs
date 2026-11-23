using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using NaviApps.WindowManagement;

internal static class Program
{
    private static readonly JsonSerializerOptions ResultJson = new() { WriteIndented = true };
    private const string Title = "WindowManagement acceptance — λ 日本";
    private sealed record Ready(ulong Handle, uint Process, uint Thread);
    private sealed class HitProbe : NativeWindow, IDisposable
    {
        private const int WindowStylePopup = unchecked((int)0x80000000);
        private const int WindowExtendedStyleNoActivate = 0x08000000;
        private const uint NoActivate = 0x0010;
        private const uint ShowWindow = 0x0040;

        internal HitProbe() => CreateHandle(new CreateParams
        {
            Caption = "Owned hit-test probe",
            Style = WindowStylePopup,
            ExStyle = WindowExtendedStyleNoActivate,
        });

        internal void ShowAt(Rect backgroundFrame)
        {
            // Showing a TopMost WinForms Form can focus it after the initial display.
            if (!SetWindowPos(Handle, new nint(-1), checked((int)backgroundFrame.X + 96),
                checked((int)backgroundFrame.Y + 96), 128, 96, NoActivate | ShowWindow))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
        }

        public void Dispose() => DestroyHandle();
    }
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint handle, out uint process);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint handle);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint handle, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern nint GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] private static extern bool AreDpiAwarenessContextsEqual(nint first, nint second);
    [DllImport("user32.dll")] private static extern nint SetThreadDpiAwarenessContext(nint context);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PrintWindow(nint handle, nint destination, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint handle, uint attribute, out uint value, uint size);

    [STAThread]
    private static int Main(string[] args)
    {
        Require(RuntimeInformation.ProcessArchitecture == Architecture.X64, "Use the x64 .NET process for owned Windows acceptance.");
        if (args.Length != 1) throw new ArgumentException("Provide an owned output directory.");
        var output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
        var readyPath = Path.Combine(output, "ready-" + Guid.NewGuid().ToString("N") + ".json");
        var executable = Path.Combine(AppContext.BaseDirectory, "window-acceptance-target.exe");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add(readyPath);
        using var child = Process.Start(start) ?? throw new InvalidOperationException("Cannot start owned target.");
        var steps = new List<string>();
        var dpi = GetThreadDpiAwarenessContext();
        try
        {
            Wait(() =>
            {
                if (child.HasExited)
                    throw new InvalidOperationException($"Owned target exited before readiness with code {child.ExitCode}.");
                return File.Exists(readyPath);
            }, "target startup");
            var ready = JsonSerializer.Deserialize<Ready>(File.ReadAllText(readyPath))!;
            Require(ready.Process == child.Id, "Ready file does not belong to the child process.");
            var identity = new WindowIdentity(ready.Handle, ready.Process, ready.Thread);
            var window = unchecked((nint)identity.Handle);
            var thread = GetWindowThreadProcessId(window, out var process);
            Require(thread != 0 && thread == ready.Thread && process == ready.Process, "Ready window is not owned by the child thread.");
            _ = SetForegroundWindow(window);
            Wait(() => GetForegroundWindow() == window, "owned foreground window");
            Require(WindowsDesktop.GetForegroundWindowIdentity() == identity, "Foreground identity did not match the owned window.");
            Require(GetForegroundWindow() == unchecked((nint)identity.Handle), "Capturing foreground identity changed the foreground window.");
            Require(WindowsDesktop.GetForegroundWindow().Identity == identity, "Foreground snapshot returned a different owned identity.");
            var original = WindowsDesktop.GetWindow(identity);
            Require(original.Title == Title, "UTF-16 native title was not copied as UTF-8.");
            Require(WindowsDesktop.GetWindows().Any(w => w.Identity == identity), "Visible enumeration missed the target.");
            steps.Add("owned foreground identity, cross-process snapshot, Unicode title and visible enumeration");
            using (var filter = new WindowSnapshotFilter(includedOwnerProcessIdentifiers: [identity.ProcessId], includedWindowIdentifiers: [identity.Handle]))
                Require(WindowsDesktop.GetWindows(filter).All(w => w.Identity == identity) && WindowsDesktop.GetWindows(filter).Count == 1, "Shared native query filter did not select the owned identity.");
            const string ownerId = "example.fixture.日本";
            using (var filter = new WindowSnapshotFilter(includedOwnerApplicationIdentifiers: [ownerId], includedWindowIdentifiers: [identity.Handle]))
            {
                var resolutions = 0;
                var matched = WindowsDesktop.GetWindows(filter, captured =>
                {
                    Require(captured == identity, "A numerically rejected window reached the application resolver.");
                    resolutions++;
                    return ownerId;
                });
                Require(matched.Count == 1 && matched[0].Identity == identity && resolutions == 1, "An application include did not use the owned window's captured identity.");
                Require(WindowsDesktop.GetWindows(filter).Count == 0, "The original query inferred an application identifier.");
                Require(WindowsDesktop.GetWindows(filter, _ => null).Count == 0, "An unresolved application satisfied an include set.");
            }
            using (var filter = new WindowSnapshotFilter(includedWindowIdentifiers: [identity.Handle], excludedOwnerApplicationIdentifiers: [ownerId]))
            {
                Require(WindowsDesktop.GetWindows(filter, captured => captured == identity ? ownerId : null).Count == 0, "An application exclusion did not remove the owned window.");
                var unresolved = WindowsDesktop.GetWindows(filter, _ => null);
                Require(unresolved.Count == 1 && unresolved[0].Identity == identity, "An unresolved application matched an exclusion.");
            }
            using (var filter = new WindowSnapshotFilter(includedWindowIdentifiers: [identity.Handle]))
            {
                var numeric = WindowsDesktop.GetWindows(filter, _ => throw new InvalidOperationException("Numeric-only filtering resolved application metadata."));
                Require(numeric.Count == 1 && numeric[0].Identity == identity, "Numeric-only filtering did not retain the owned window.");
            }
            using (var filter = new WindowSnapshotFilter(includedWindowIdentifiers: [identity.Handle], excludedWindowIdentifiers: [identity.Handle], includedOwnerApplicationIdentifiers: [ownerId]))
            {
                var rejected = WindowsDesktop.GetWindows(filter, _ => throw new InvalidOperationException("A numeric exclusion resolved application metadata."));
                Require(rejected.Count == 0, "A numeric exclusion did not win over inclusion.");
            }
            steps.Add("shared application filters with a caller-resolved owned identity and unavailable metadata");
            // Test physical hit coordinates while the initial foreground fixture is stable.
            // DWM cloak/uncloak deliberately changes visibility and is a separate phase.
            var desired = new Rect(original.Frame.X + 20, original.Frame.Y + 20, 480, 360);
            var positioned = WindowsDesktop.SetFrame(identity, desired);
            Require(positioned.Frame == desired, "SetFrame did not return the actual requested physical frame.");
            var atPoint = WindowsDesktop.GetWindowAt(desired.X + desired.Width / 2, desired.Y + desired.Height / 2);
            Require(atPoint.Identity == identity, $"Physical hit testing expected {identity} at {desired}, got {atPoint.Identity} at {atPoint.Frame}; foreground=0x{GetForegroundWindow():X}.");
            CheckFractionalHit(identity, positioned.Frame);
            steps.Add("physical frame set/readback, root and filtered bounds hits, fractional edges, typed misses and foreground preservation");

            File.WriteAllText(readyPath + ".cloak", "1");
            Wait(() => IsCloaked(identity.Handle), "owned cloaked state");
            Require(!WindowsDesktop.GetWindows().Any(w => w.Identity == identity), "A cloaked window appeared in visible enumeration.");
            Require(WindowsDesktop.GetWindow(identity).Identity == identity, "Explicit identity query lost a cloaked target.");
            File.Delete(readyPath + ".cloak");
            Wait(() => !IsCloaked(identity.Handle) && WindowsDesktop.GetWindows().Any(w => w.Identity == identity), "owned uncloaked enumeration");
            steps.Add("shared process/window filters and owned DWM cloak/uncloak visibility; explicit identity queries remain available");

            var wrongProcess = identity with { ProcessId = identity.ProcessId + 1 };
            var wrongThread = identity with { ThreadId = identity.ThreadId + 1 };
            ExpectError(() => { _ = WindowsDesktop.GetWindow(wrongProcess); }, WindowOperationError.TargetChanged);
            ExpectError(() => { _ = WindowsDesktop.GetWindow(wrongThread); }, WindowOperationError.TargetChanged);
            ExpectError(() => { _ = WindowsDesktop.SetFrame(wrongProcess, desired); }, WindowOperationError.TargetChanged);
            ExpectError(() => { _ = WindowsDesktop.Minimize(wrongThread); }, WindowOperationError.TargetChanged);
            foreach (var malformed in new[] { identity with { Handle = 0 }, identity with { ProcessId = 0 }, identity with { ThreadId = 0 } })
                ExpectError(() => { _ = WindowsDesktop.GetWindow(malformed); }, WindowOperationError.InvalidInput);
            ExpectError(() => { _ = WindowsDesktop.SetFrame(identity, new(double.NaN, 0, 480, 360)); }, WindowOperationError.InvalidInput);
            var unchanged = WindowsDesktop.GetWindow(identity);
            Require(unchanged.Frame == desired && !unchanged.IsMinimized, "Rejected input changed the owned window.");
            steps.Add("wrong process/thread, malformed identity and non-finite input rejected without changing the owned window");

            var constrained = WindowsDesktop.SetFrame(identity, new(desired.X, desired.Y, 1, 1));
            Require(constrained.Frame.Width > 1 && constrained.Frame.Height > 1, "Native size constraints were not read back.");
            _ = WindowsDesktop.SetFrame(identity, desired);
            steps.Add("native minimum-size constraint returned as actual frame");

            var displays = WindowsDesktop.GetDisplays();
            Require(displays.Count > 0, "No physical monitor metadata.");
            var request = new WindowPlacementRequest(WindowPlacement.Grid(2, 1, 1, 0), inset: 4);
            var expected = Geometry.ResolvePlacement(request, desired, displays.ToArray()) ?? throw new InvalidOperationException("No containing display.");
            var placed = WindowsDesktop.Place(identity, request);
            Require(Nearly(placed.Frame, expected), "Native placement differs from shared Rust resolution.");
            var movement = new WindowMoveRequest(DisplayCycleDirection.Next, preservesRelativePosition: displays.Count != 1);
            ExpectError(() => { _ = WindowsDesktop.MoveToAdjacentDisplay(wrongThread, movement); }, WindowOperationError.TargetChanged);
            Require(WindowsDesktop.GetWindow(identity).Frame == placed.Frame, "Rejected movement changed the owned window.");
            var movedExpected = Geometry.ResolveMovement(movement, placed.Frame, displays.ToArray())!.Value;
            var moved = WindowsDesktop.MoveToAdjacentDisplay(identity, movement);
            Require(Nearly(moved.Frame, movedExpected), "Native movement differs from shared Rust resolution.");
            if (displays.Count == 1)
                Require(moved.Frame == placed.Frame, "A window on the only display was moved or resized.");
            ExpectError(() => { _ = WindowsDesktop.Place(identity, new(WindowPlacement.Fill, DisplayTarget.DisplayIdentifier(ulong.MaxValue))); }, WindowOperationError.Unavailable);
            Require(WindowsDesktop.GetWindow(identity).Frame == moved.Frame, "Missing display changed the owned window.");
            steps.Add("shared placement, adjacent-display movement and explicit missing-display failure");

            _ = WindowsDesktop.Minimize(identity);
            Wait(() => WindowsDesktop.GetWindow(identity).IsMinimized, "minimize state");
            _ = WindowsDesktop.Restore(identity);
            Wait(() => !WindowsDesktop.GetWindow(identity).IsMinimized, "restore state");
            _ = WindowsDesktop.Maximize(identity);
            Wait(() => WindowsDesktop.GetWindow(identity).IsMaximized, "maximize state");
            _ = WindowsDesktop.Restore(identity);
            Wait(() => !WindowsDesktop.GetWindow(identity).IsMaximized, "restore maximized state");
            _ = WindowsDesktop.SetFrame(identity, desired);
            steps.Add("native minimize, maximize and restore state readback");
            Require(AreDpiAwarenessContextsEqual(dpi, GetThreadDpiAwarenessContext()), "SDK leaked thread DPI awareness.");
            steps.Add("thread DPI context restored after queries, commands and failures");

            Capture(identity, WindowsDesktop.GetWindow(identity).Frame, Path.Combine(output, "owned-window.png"));
            steps.Add("owned full-window PrintWindow capture including non-client frame");
            WindowsDesktop.RequestClose(identity);
            Require(child.WaitForExit(10_000) && child.ExitCode == 0, "Close request was not handled by the owned target.");
            ExpectError(() => { _ = WindowsDesktop.GetWindow(identity); }, WindowOperationError.TargetChanged);
            ExpectError(() => { _ = WindowsDesktop.SetFrame(identity, desired); }, WindowOperationError.TargetChanged);
            ExpectError(() => WindowsDesktop.RequestClose(identity), WindowOperationError.TargetChanged);
            steps.Add("queued close observed by target and stale identity distinguished from an unavailable window or display");
            File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new
            {
                status = "passed",
                architecture = RuntimeInformation.OSArchitecture.ToString(),
                processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                os = Environment.OSVersion.VersionString,
                targetProcess = ready.Process,
                steps,
                displayCount = displays.Count,
            }, ResultJson));
            Console.WriteLine("WindowManagement native cross-process acceptance passed.");
            return 0;
        }
        finally
        {
            if (!child.HasExited)
            {
                _ = child.CloseMainWindow();
                if (!child.WaitForExit(5000))
                {
                    child.Kill(entireProcessTree: true);
                    Require(child.WaitForExit(5000), "Owned target did not terminate.");
                }
            }
            File.Delete(readyPath);
            File.Delete(readyPath + ".tmp");
            File.Delete(readyPath + ".cloak");
        }
    }
    private static void CheckFractionalHit(WindowIdentity background, Rect backgroundFrame)
    {
        void CheckForeground(string step)
        {
            var foreground = GetForegroundWindow();
            Require(foreground == unchecked((nint)background.Handle),
                $"Unexpected foreground {step}. Expected background 0x{background.Handle:X}, observed 0x{foreground:X}.");
        }

        T ReadWithoutActivation<T>(string operation, Func<T> read)
        {
            CheckForeground($"before {operation}");
            var value = read();
            CheckForeground($"after {operation}");
            return value;
        }

        CheckForeground("before probe setup");
        var previous = SetThreadDpiAwarenessContext(new nint(-4));
        if (previous == 0) throw new InvalidOperationException("Cannot scope hit probe DPI awareness.");
        try
        {
            using var probe = new HitProbe();
            CheckForeground("after creating the probe");
            var handle = probe.Handle;
            var thread = GetWindowThreadProcessId(handle, out var process);
            Require(process == Environment.ProcessId && thread != 0, "The hit probe is not owned by the fixture.");
            var probeIdentity = new WindowIdentity(unchecked((ulong)handle.ToInt64()), process, thread);
            probe.ShowAt(backgroundFrame);
            CheckForeground($"after showing probe 0x{probeIdentity.Handle:X}");
            var frame = ReadWithoutActivation("reading the probe bounds", () => WindowsDesktop.GetWindow(probeIdentity)).Frame;
            var edge = frame.X + frame.Width;
            var y = frame.Y + Math.Floor(frame.Height / 2);
            var integerLeft = ReadWithoutActivation("the root hit one pixel inside the probe", () => WindowsDesktop.GetWindowAt(edge - 1, y));
            var integerEdge = ReadWithoutActivation("the root hit at the probe edge", () => WindowsDesktop.GetWindowAt(edge, y));
            Require(integerLeft.Identity == probeIdentity && integerEdge.Identity == background,
                $"Integer hit samples did not straddle the owned windows. Probe={probeIdentity}, background={background}, hits={integerLeft.Identity}, {integerEdge.Identity}, probe bounds={frame}.");
            var fractionalLeft = ReadWithoutActivation("the root hit just inside the probe", () => WindowsDesktop.GetWindowAt(edge - 0.25, y));
            var fractionalRight = ReadWithoutActivation("the root hit just outside the probe", () => WindowsDesktop.GetWindowAt(edge + 0.25, y));
            Require(fractionalLeft.Identity == probeIdentity && fractionalRight.Identity == background,
                $"Fractional root hits crossed the pixel boundary. Hits={fractionalLeft.Identity}, {fractionalRight.Identity}, probe bounds={frame}.");
            using var owned = new WindowSnapshotFilter(includedWindowIdentifiers: [probeIdentity.Handle, background.Handle]);
            var boundsLeft = ReadWithoutActivation("the bounds hit just inside the probe", () => WindowsDesktop.HitTest(edge - 0.25, y, owned));
            var boundsRight = ReadWithoutActivation("the bounds hit just outside the probe", () => WindowsDesktop.HitTest(edge + 0.25, y, owned));
            Require(boundsLeft.Snapshot?.Identity == probeIdentity && boundsRight.Snapshot?.Identity == background,
                $"Filtered bounds hits did not retain native z order and half-open pixel edges. Hits={boundsLeft.Snapshot?.Identity}, {boundsRight.Snapshot?.Identity}, misses={boundsLeft.MissReason}, {boundsRight.MissReason}, probe bounds={frame}.");
            using var backOnly = new WindowSnapshotFilter(
                includedWindowIdentifiers: [probeIdentity.Handle, background.Handle],
                excludedWindowIdentifiers: [probeIdentity.Handle],
                includedOwnerApplicationIdentifiers: ["owned"]);
            var resolutions = new List<WindowIdentity>();
            var hit = ReadWithoutActivation("the bounds hit with application resolution", () =>
                WindowsDesktop.HitTest(edge - 0.25, y, backOnly, identity =>
                {
                    resolutions.Add(identity);
                    return "owned";
                }));
            Require(hit.Snapshot?.Identity == background && resolutions.SequenceEqual([background]),
                "Filtered bounds hits did not defer application resolution until after numeric filtering.");
            var unresolved = ReadWithoutActivation("the bounds hit with a missing application identifier", () =>
                WindowsDesktop.HitTest(edge - 0.25, y, backOnly));
            var invalid = ReadWithoutActivation("the bounds hit with an invalid coordinate", () =>
                WindowsDesktop.HitTest(double.NaN, y, owned));
            Require(unresolved.MissReason == WindowHitTestMissReason.NoMatchingWindowAtPoint
                && invalid.MissReason == WindowHitTestMissReason.NoMatchingWindowAtPoint,
                "Filtered bounds hits did not return typed misses for a missing identifier or invalid point.");
        }
        finally { _ = SetThreadDpiAwarenessContext(previous); }
        CheckForeground("after disposing the probe");
    }
    private static bool IsCloaked(ulong handle)
    {
        Require(DwmGetWindowAttribute(unchecked((nint)handle), 14, out var value, 4) == 0, "Owned DWM cloak query failed.");
        return value != 0;
    }
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static void Wait(Func<bool> predicate, string stage)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < TimeSpan.FromSeconds(10)) { if (predicate()) return; Thread.Sleep(25); }
        throw new TimeoutException(stage);
    }
    private static void ExpectError(Action action, WindowOperationError expected)
    {
        try { action(); } catch (WindowOperationException error) when (error.Code == expected) { return; }
        throw new InvalidOperationException("Expected native failure: " + expected);
    }
    private static bool Nearly(Rect a, Rect b) => Math.Abs(a.X - b.X) <= 1 && Math.Abs(a.Y - b.Y) <= 1 && Math.Abs(a.Width - b.Width) <= 1 && Math.Abs(a.Height - b.Height) <= 1;
    private static void Capture(WindowIdentity identity, Rect frame, string path)
    {
        var handle = unchecked((nint)identity.Handle);
        var thread = GetWindowThreadProcessId(handle, out var process);
        Require(thread == identity.ThreadId && process == identity.ProcessId, "Capture target identity changed.");
        var previous = SetThreadDpiAwarenessContext(new nint(-4));
        if (previous == 0) throw new InvalidOperationException("Cannot scope capture DPI awareness.");
        try
        {
            using var bitmap = new Bitmap(checked((int)frame.Width), checked((int)frame.Height));
            using var graphics = Graphics.FromImage(bitmap);
            var destination = graphics.GetHdc();
            try
            {
                // Flags zero requests the entire owned window, including its non-client area.
                Require(PrintWindow(handle, destination, 0), "Owned window did not render its capture.");
            }
            finally { graphics.ReleaseHdc(destination); }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        finally { _ = SetThreadDpiAwarenessContext(previous); }
    }
}
