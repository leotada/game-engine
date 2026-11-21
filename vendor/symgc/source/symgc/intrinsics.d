module symgc.intrinsics;

public import core.bitop : bsr, bsf, popcnt, bswap;
static if(__traits(compiles, () nothrow @nogc @safe { import core.builtins : likely, unlikely; bool b = likely(true); })) {
	public import core.builtins : likely, unlikely;
}
else
{
	pragma(inline, true)
	bool likely(bool v) pure nothrow @nogc @safe => v;
	pragma(inline, true)
	bool unlikely(bool v) pure nothrow @nogc @safe => v;
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
			static if (op == "|") {
				asm pure nothrow @nogc @trusted {
					mov RCX, p;
					mov R8, m;
					mov RAX, [RCX];
				LretryOr:
					mov RDX, RAX;
					or RDX, R8;
					lock; cmpxchg [RCX], RDX;
					jne LretryOr;
					mov res, RAX;
				}
			} else static if (op == "&") {
				asm pure nothrow @nogc @trusted {
					mov RCX, p;
					mov R8, m;
					mov RAX, [RCX];
				LretryAnd:
					mov RDX, RAX;
					and RDX, R8;
					lock; cmpxchg [RCX], RDX;
					jne LretryAnd;
					mov res, RAX;
				}
			} else {
				asm pure nothrow @nogc @trusted {
					mov RCX, p;
					mov R8, m;
					mov RAX, [RCX];
				LretryXor:
					mov RDX, RAX;
					xor RDX, R8;
					lock; cmpxchg [RCX], RDX;
					jne LretryXor;
					mov res, RAX;
				}
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
