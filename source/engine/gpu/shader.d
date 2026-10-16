/// Shader module creation — wraps WGSL source into WGPUShaderModule with layout validation.
module engine.gpu.shader;

import bindings.wgpu;
import engine.core.log;
import engine.core.pod : isPod;

@safe:

/// Compile-time verification that uniform buffers conform to WGSL 16-byte alignment and POD restrictions.
enum bool isValidUniformStruct(T) = isPod!T && (T.sizeof % 16 == 0);

mixin template ValidateUniformLayout(T) {
    static assert(isPod!T, "Uniform struct '" ~ T.stringof ~ "' must be a plain POD struct (no GC references)");
    static assert(T.sizeof % 16 == 0, "Uniform struct '" ~ T.stringof ~ "' size must be a multiple of 16 bytes for WebGPU alignment (got " ~ T.sizeof.stringof ~ " bytes)");
}

/// Create a shader module from a null-terminated C string.
WGPUShaderModule createShaderModule(WGPUDevice device, const(char)* wgslCode) nothrow @nogc @trusted {
    if (wgslCode is null) return null;
    WGPUShaderSourceWGSL wgslSource;
    wgslSource.chain.sType = WGPUSType.shaderSourceWGSL;
    wgslSource.chain.next  = null;
    wgslSource.code        = wgpuStringView(wgslCode);

    WGPUShaderModuleDescriptor desc;
    desc.nextInChain = cast(WGPUChainedStruct*) &wgslSource;

    auto mod = wgpuDeviceCreateShaderModule(device, &desc);
    if (mod is null) {
        err("Failed to create shader module");
    }
    return mod;
}

/// Create a shader module from a slice of characters without requiring extra null termination.
WGPUShaderModule createShaderModule(WGPUDevice device, scope const(char)[] wgslSlice, const(char)* label = null) nothrow @nogc @trusted {
    if (wgslSlice.length == 0) return null;
    WGPUShaderSourceWGSL wgslSource;
    wgslSource.chain.sType = WGPUSType.shaderSourceWGSL;
    wgslSource.chain.next  = null;
    wgslSource.code        = WGPUStringView(wgslSlice.ptr, wgslSlice.length);

    WGPUShaderModuleDescriptor desc;
    desc.nextInChain = cast(WGPUChainedStruct*) &wgslSource;
    if (label !is null) {
        desc.label = wgpuStringView(label);
    }

    auto mod = wgpuDeviceCreateShaderModule(device, &desc);
    if (mod is null) {
        err("Failed to create shader module");
    }
    return mod;
}
