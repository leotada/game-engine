/**
 * Typed errors for the safe DEFLATE compressor.
 *
 * The library never throws across the public API. Operations return a
 * `Result!T` carrying either a value or an `ErrorInfo`. The CLI converts
 * `ErrorInfo` to an exit code and a human-readable message.
 */
module zipd.compressor.errors;

@safe:
nothrow:
@nogc:

/// High-level error category. Maps directly to CLI exit codes (see
/// `zipd.cli.exitcode`).
enum ErrorKind : ubyte
{
    none           = 0,
    generic        = 1,
    invalidArgs    = 2,
    io             = 3,
    unsupported    = 4,
    corruptInput   = 5,
    checksum       = 6,
    internal       = 8,
}

/// Lightweight, allocation-free error carrier.
///
/// `message` is a slice into static string data or into an owned buffer
/// kept alive by the caller; the struct itself never owns memory.
struct ErrorInfo
{
    ErrorKind kind = ErrorKind.none;
    string    message;

    bool ok() const pure nothrow @nogc scope { return kind == ErrorKind.none; }
}

/// Construct an error.
ErrorInfo makeError(ErrorKind kind, string message) pure nothrow @nogc
{
    return ErrorInfo(kind, message);
}

/// Sentinel "no error" value.
enum ErrorInfo noError = ErrorInfo(ErrorKind.none, "");

/// Result type. Tagged by `error.kind == none`.
struct Result(T)
{
    T         value;
    ErrorInfo error;

    bool ok() const pure nothrow @nogc scope { return error.ok; }
}

/// Build a successful result.
Result!T success(T)(T value) pure nothrow @nogc
{
    return Result!T(value, noError);
}

/// Build a failed result. `T.init` is used as a placeholder value.
Result!T failure(T)(ErrorKind kind, string message) pure nothrow @nogc
{
    return Result!T(T.init, ErrorInfo(kind, message));
}

