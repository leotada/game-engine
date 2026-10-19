module symgc.intrinsics;

public import core.bitop : bsr, bsf, popcnt, bswap;
static if(__traits(compiles, () {import core.builtins : likely, unlikely; })) {
	public import core.builtins : likely, unlikely;
}
else
{
	bool likely(bool v) => v;
	bool unlikely(bool v) => v;
}

// TODO: Change all uses of countLeadingZeros to bsr directly
pragma(inline, true)
auto countLeadingZeros(T)(T x) {
	enum S = T.sizeof * 8;
	return S - 1 - bsr(x);
}
alias countTrailingZeros = bsf;
alias popCount = popcnt;

void atomicOrUlong(shared(ulong)* p, ulong mask) nothrow @nogc {
	version (D_InlineAsm_X86_64) {
		asm pure nothrow @nogc @trusted {
			mov RAX, p;
			mov RDX, mask;
			lock; or [RAX], RDX;
		}
	} else {
		atomicFetchOp!"|"(*p, mask);
	}
}

void atomicAndUlong(shared(ulong)* p, ulong mask) nothrow @nogc {
	version (D_InlineAsm_X86_64) {
		asm pure nothrow @nogc @trusted {
			mov RAX, p;
			mov RDX, mask;
			lock; and [RAX], RDX;
		}
	} else {
		atomicFetchOp!"&"(*p, mask);
	}
}

// copy atomicOp, but with returning the get value.
T atomicFetchOp(string op, T, V1)(ref shared T val, V1 mod)
{
	version (D_InlineAsm_X86_64) {
		static if (is(T == ulong) && (op == "|" || op == "&" || op == "^")) {
			shared(ulong)* p = &val;
			ulong m = mod;
			ulong res = void;
			asm pure nothrow @nogc @trusted {
				mov RCX, p;
				mov R8, m;
				mov RAX, [RCX];
			Lretry:
				mov RDX, RAX;
			}
			static if (op == "|") {
				asm pure nothrow @nogc @trusted { or RDX, R8; }
			} else static if (op == "&") {
				asm pure nothrow @nogc @trusted { and RDX, R8; }
			} else {
				asm pure nothrow @nogc @trusted { xor RDX, R8; }
			}
			asm pure nothrow @nogc @trusted {
				lock; cmpxchg [RCX], RDX;
				jne Lretry;
				mov res, RAX;
			}
			return res;
		} else {
			import core.atomic : atomicLoad, casWeak, MemoryOrder;
			T set, get = atomicLoad!(MemoryOrder.raw, T)(val);
			do
			{
				set = get;
				mixin("set = get " ~ op ~ " mod;");
			} while (!casWeak(&val, &get, set));
			return get;
		}
	} else {
		import core.atomic : atomicLoad, casWeak, MemoryOrder;
		T set, get = atomicLoad!(MemoryOrder.raw, T)(val);
		do
		{
			set = get;
			mixin("set = get " ~ op ~ " mod;");
		} while (!casWeak(&val, &get, set));
		return get;
	}
}
