using System.Text;
using System.Text.Json;
namespace NaviApps.WindowManagement;

/// <summary>Immutable Rust-owned snapshot selection. All nonempty include sets must
/// match; any exclusion wins. Native IDs belong to their platform. Application IDs
/// are opaque strings supplied by the adapter or caller, never paths to execute.</summary>
public sealed class WindowSnapshotFilter : IDisposable
{
    private readonly WindowFilterHandle owner;
    private readonly string json;
    /// <summary>Create a reusable selector. Empty include sets accept all values.</summary>
    public WindowSnapshotFilter(
        IEnumerable<string>? includedOwnerApplicationIdentifiers = null,
        IEnumerable<long>? includedOwnerProcessIdentifiers = null,
        IEnumerable<ulong>? includedWindowIdentifiers = null,
        IEnumerable<string>? excludedOwnerApplicationIdentifiers = null,
        IEnumerable<long>? excludedOwnerProcessIdentifiers = null,
        IEnumerable<ulong>? excludedWindowIdentifiers = null)
        : this(JsonSerializer.SerializeToUtf8Bytes(new
        {
            includedOwnerApplicationIdentifiers = CaptureIdentifiers(includedOwnerApplicationIdentifiers),
            includedOwnerProcessIdentifiers = includedOwnerProcessIdentifiers?.ToArray() ?? [],
            includedWindowIdentifiers = includedWindowIdentifiers?.ToArray() ?? [],
            excludedOwnerApplicationIdentifiers = CaptureIdentifiers(excludedOwnerApplicationIdentifiers),
            excludedOwnerProcessIdentifiers = excludedOwnerProcessIdentifiers?.ToArray() ?? [],
            excludedWindowIdentifiers = excludedWindowIdentifiers?.ToArray() ?? [],
        }))
    { }
    private WindowSnapshotFilter(ReadOnlySpan<byte> data)
    {
        var canonical = Native.ValueJson(4, data);
        json = Encoding.UTF8.GetString(canonical);
        owner = Native.CreateFilter(canonical);
        if (owner.IsInvalid) throw new WindowDataException("Cannot create a native snapshot filter.");
    }

    private static string[] CaptureIdentifiers(IEnumerable<string>? identifiers)
    {
        var values = identifiers?.ToArray() ?? [];
        foreach (var value in values)
        {
            if (value is null) throw new WindowDataException("An application identifier cannot be null.");
            WindowJson.ValidateUnicode(value);
        }
        return values;
    }

    /// <summary>Strictly decode original JSON in Rust. Legacy bundle-ID filter keys require host migration.</summary>
    public static WindowSnapshotFilter FromJson(string json) => FromJsonUtf8(WindowJson.EncodeUtf8(json));
    /// <summary>Strictly decode original UTF-8 JSON without replacing malformed input.</summary>
    public static WindowSnapshotFilter FromJsonUtf8(ReadOnlySpan<byte> json) => new(json);
    /// <summary>Canonical filter JSON uses includedOwnerApplicationIdentifiers and excludedOwnerApplicationIdentifiers.</summary>
    public string ToJson() => json;
    /// <summary>Test a snapshot. Missing application metadata cannot satisfy an application include set.</summary>
    public bool Includes(WindowSnapshot snapshot, string? ownerApplicationIdentifier = null)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return Native.FilterIncludes(owner, snapshot.Identity.Handle, snapshot.Identity.ProcessId, ownerApplicationIdentifier);
    }

    internal bool IncludesWithResolver(WindowSnapshot snapshot, Func<WindowIdentity, string?> resolveApplicationIdentifier)
    {
        return Native.FilterMatchIdentity(owner, snapshot.Identity.Handle, snapshot.Identity.ProcessId) switch
        {
            0 => false,
            1 => true,
            3 => Includes(snapshot, resolveApplicationIdentifier(snapshot.Identity)),
            _ => throw new InvalidDataException("Invalid native snapshot identity response."),
        };
    }

    /// <summary>Release the compiled selector. Concurrent native queries retain their SafeHandle borrow.</summary>
    public void Dispose() => owner.Dispose();
}
