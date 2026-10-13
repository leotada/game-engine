/// 128-bit POD AssetGuid and strongly typed AssetRef!T handles.
module engine.project.asset_ref;

import engine.core.pod : isPod;
import std.format : format;

@safe:

/// 128-bit persistent asset GUID (POD).
struct AssetGuid {
    ubyte[16] bytes;

    bool isNull() const pure nothrow @nogc {
        foreach (b; bytes) {
            if (b != 0) return false;
        }
        return true;
    }

    string toString() const @trusted {
        char[32] hex;
        enum hexChars = "0123456789abcdef";
        foreach (i; 0 .. 16) {
            hex[i * 2]     = hexChars[(bytes[i] >> 4) & 0x0F];
            hex[i * 2 + 1] = hexChars[bytes[i] & 0x0F];
        }
        return hex.idup;
    }

    static AssetGuid fromString(scope const(char)[] hex) @trusted nothrow {
        AssetGuid g;
        if (hex.length < 32) return g;

        static ubyte hexVal(char c) nothrow @nogc {
            if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
            if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
            if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
            return 0;
        }

        foreach (i; 0 .. 16) {
            g.bytes[i] = cast(ubyte)((hexVal(hex[i * 2]) << 4) | hexVal(hex[i * 2 + 1]));
        }
        return g;
    }

    static AssetGuid generate() @trusted {
        import std.random : rndGen;
        AssetGuid g;
        foreach (i; 0 .. 16) {
            g.bytes[i] = cast(ubyte)(rndGen.front & 0xFF);
            rndGen.popFront();
        }
        // RFC 4122 variant and version 4 bits
        g.bytes[6] = (g.bytes[6] & 0x0F) | 0x40;
        g.bytes[8] = (g.bytes[8] & 0x3F) | 0x80;
        return g;
    }
}

static assert(isPod!AssetGuid);

/// Strongly-typed reference to an asset (POD).
struct AssetRef(T) {
    AssetGuid guid;

    bool isNull() const pure nothrow @nogc {
        return guid.isNull();
    }
}

static assert(isPod!(AssetRef!int));
