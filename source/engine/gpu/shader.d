/// Shader module creation — wraps WGSL source into WGPUShaderModule.
module engine.gpu.shader;

import bindings.wgpu;
import engine.core.log;

@safe:

WGPUShaderModule createShaderModule(WGPUDevice device, const(char)* wgslCode) nothrow @nogc @trusted {
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
