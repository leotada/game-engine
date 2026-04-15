/// GPU buffer helpers — create vertex, index, uniform buffers with one call.
module engine.gpu.buffer;

import bindings.wgpu;
import engine.core.log;

@safe:

WGPUBuffer createVertexBuffer(WGPUDevice device, WGPUQueue queue, const(void)* data, ulong size) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    desc.usage = WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst;
    desc.size  = size;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) {
        err("Failed to create vertex buffer");
        return null;
    }
    wgpuQueueWriteBuffer(queue, buf, 0, data, cast(size_t) size);
    return buf;
}

WGPUBuffer createIndexBuffer(WGPUDevice device, WGPUQueue queue, const(void)* data, ulong size) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    desc.usage = WGPUBufferUsage.index | WGPUBufferUsage.copyDst;
    desc.size  = size;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) {
        err("Failed to create index buffer");
        return null;
    }
    wgpuQueueWriteBuffer(queue, buf, 0, data, cast(size_t) size);
    return buf;
}

WGPUBuffer createUniformBuffer(WGPUDevice device, ulong size) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    desc.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst;
    desc.size  = size;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) {
        err("Failed to create uniform buffer");
    }
    return buf;
}

WGPUBuffer createDynamicVertexBuffer(WGPUDevice device, ulong size) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    desc.usage = WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst;
    desc.size  = size;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) {
        err("Failed to create dynamic vertex buffer");
    }
    return buf;
}

void updateBuffer(WGPUQueue queue, WGPUBuffer buffer, const(void)* data, size_t size) nothrow @nogc @trusted {
    wgpuQueueWriteBuffer(queue, buffer, 0, data, size);
}
