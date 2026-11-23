namespace NaviApps.WindowManagement;

/// <summary>Why a window hit test produced no matching snapshot.</summary>
public enum WindowHitTestMissReason
{
    /// <summary>The native window source could not be read.</summary>
    SourceUnavailable,
    /// <summary>No eligible window containing the point matched the filter.</summary>
    NoMatchingWindowAtPoint,
}

/// <summary>A captured snapshot or the reason no window matched.</summary>
public sealed record WindowHitTestResult
{
    private WindowHitTestResult(WindowSnapshot? snapshot, WindowHitTestMissReason? missReason)
    {
        Snapshot = snapshot;
        MissReason = missReason;
    }

    /// <summary>The matching snapshot when the hit test succeeds.</summary>
    public WindowSnapshot? Snapshot { get; }

    /// <summary>The reason the hit test returned no matching snapshot.</summary>
    public WindowHitTestMissReason? MissReason { get; }

    /// <summary>Create a successful hit result from a captured snapshot.</summary>
    public static WindowHitTestResult Hit(WindowSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return new(snapshot, null);
    }

    /// <summary>Create a miss with a known reason.</summary>
    public static WindowHitTestResult Miss(WindowHitTestMissReason reason)
    {
        if (!Enum.IsDefined(reason)) throw new ArgumentOutOfRangeException(nameof(reason));
        return new(null, reason);
    }

    internal static WindowHitTestResult FirstMatch(
        Func<IReadOnlyList<WindowSnapshot>> readCandidates, WindowSnapshotFilter? filter,
        Func<WindowIdentity, string?>? resolveOwnerApplicationIdentifier)
    {
        IReadOnlyList<WindowSnapshot> candidates;
        try
        {
            candidates = readCandidates();
        }
        catch (WindowOperationException failure)
            when (failure.Code is WindowOperationError.NativeFailure or WindowOperationError.Unavailable)
        {
            return Miss(WindowHitTestMissReason.SourceUnavailable);
        }

        foreach (var snapshot in candidates)
        {
            if (filter is null || (resolveOwnerApplicationIdentifier is null
                ? filter.Includes(snapshot)
                : filter.IncludesWithResolver(snapshot, resolveOwnerApplicationIdentifier)))
                return Hit(snapshot);
        }
        return Miss(WindowHitTestMissReason.NoMatchingWindowAtPoint);
    }
}
