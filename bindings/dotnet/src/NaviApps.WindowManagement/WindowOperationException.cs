namespace NaviApps.WindowManagement;

/// <summary>Portable native window operation failures.</summary>
public enum WindowOperationError
{
    /// <summary>The native backend is unavailable on this OS.</summary>
    UnsupportedPlatform = 1,
    /// <summary>The request or native identity is malformed.</summary>
    InvalidInput = 2,
    /// <summary>A requested window or display is unavailable.</summary>
    Unavailable = 3,
    /// <summary>The captured window disappeared, changed owners, or lost the foreground during capture.</summary>
    TargetChanged = 4,
    /// <summary>A native call failed. NativeCode is diagnostic and may be zero.</summary>
    NativeFailure = 5,
}
/// <summary>Structured native failure. A failed command does not promise rollback of earlier native effects.</summary>
public sealed class WindowOperationException : Exception
{
    /// <summary>Portable failure category.</summary>
    public WindowOperationError Code { get; }
    /// <summary>Native diagnostic code, when supplied by the platform.</summary>
    public uint NativeCode { get; }
    internal WindowOperationException(uint code, uint native) : base($"Window operation failed: status={code}, native={native}")
    { Code = (WindowOperationError)code; NativeCode = native; }
}
