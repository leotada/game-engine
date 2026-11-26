/// GPU buffer helpers — create vertex, index, uniform buffers with one call.
module engine.gpu.buffer;

import bindings.wgpu;
import engine.core.log;

@safe:

WGPUBuffer createVertexBuffer(WGPUDevice device, WGPUQueue queue, const(void)* data, ulong size) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    // copySrc: static instance buffers copy meshes into shared pools.
    desc.usage = WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst | WGPUBufferUsage.copySrc;
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
    desc.usage = WGPUBufferUsage.index | WGPUBufferUsage.copyDst | WGPUBufferUsage.copySrc;
    desc.size  = (size + 3) & ~3UL;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) {
        err("Failed to create index buffer");
        return null;
    }
    // Writes must be 4-byte multiples: an odd count of 16-bit indices gets a padded tail.
    immutable size_t whole = cast(size_t) size & ~cast(size_t) 3;
    if (whole) wgpuQueueWriteBuffer(queue, buf, 0, data, whole);
    if (whole != size) {
        ubyte[4] tail;
        immutable rest = cast(size_t) size - whole;
        tail[0 .. rest] = (cast(const(ubyte)*) data)[whole .. whole + rest];
        wgpuQueueWriteBuffer(queue, buf, whole, tail.ptr, 4);
    }
    return buf;
}

/// Buffer with an explicit usage mask and no initial data.
WGPUBuffer createBufferWithUsage(WGPUDevice device, ulong size, WGPUBufferUsage usage) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    desc.usage = usage;
    desc.size  = size;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) err("Failed to create buffer");
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

WGPUBuffer createStorageBuffer(WGPUDevice device, ulong size) nothrow @nogc @trusted {
    WGPUBufferDescriptor desc;
    desc.usage = WGPUBufferUsage.storage | WGPUBufferUsage.copyDst;
    desc.size  = size;
    auto buf = wgpuDeviceCreateBuffer(device, &desc);
    if (buf is null) {
        err("Failed to create storage buffer");
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

// ---------------------------------------------------------------------------
// @safe slice-based overloads — eliminates @trusted at the call site
// ---------------------------------------------------------------------------

WGPUBuffer createVertexBuffer(T)(WGPUDevice device, WGPUQueue queue, const(T)[] data) @trusted {
    return createVertexBuffer(device, queue, data.ptr, data.length * T.sizeof);
}

WGPUBuffer createIndexBuffer(T)(WGPUDevice device, WGPUQueue queue, const(T)[] data) @trusted {
    return createIndexBuffer(device, queue, data.ptr, data.length * T.sizeof);
}

void updateBuffer(T)(WGPUQueue queue, WGPUBuffer buffer, scope const(T)[] data) @trusted {
    wgpuQueueWriteBuffer(queue, buffer, 0, data.ptr, data.length * T.sizeof);
}

void destroyBuffer(WGPUBuffer buf) nothrow @nogc @trusted {
    if (buf !is null) {
        wgpuBufferDestroy(buf);
        wgpuBufferRelease(buf);
    }
}

/// Take another reference to `buf` (null stays null). Pair with `releaseBuffer`.
WGPUBuffer retainBuffer(WGPUBuffer buf) nothrow @nogc @trusted {
    if (buf !is null) wgpuBufferAddRef(buf);
    return buf;
}

/// Drop one reference without destroying: the memory is freed once the last
/// reference is gone and the GPU no longer uses it. For buffers other owners
/// still draw with (`destroyBuffer` would invalidate them for everyone).
void releaseBuffer(WGPUBuffer buf) nothrow @nogc @trusted {
    if (buf !is null) wgpuBufferRelease(buf);
}

WGPUBindGroup createUniformBindGroup(WGPUDevice device, WGPUBindGroupLayout layout,
                                      WGPUBuffer uniformBuf, ulong size) @trusted {
    WGPUBindGroupEntry bgEntry;
    bgEntry.binding = 0;
    bgEntry.buffer  = uniformBuf;
    bgEntry.offset  = 0;
    bgEntry.size    = size;

    WGPUBindGroupDescriptor bgDesc;
    bgDesc.layout     = layout;
    bgDesc.entryCount = 1;
    bgDesc.entries    = &bgEntry;
    return wgpuDeviceCreateBindGroup(device, &bgDesc);
}

void releaseBindGroup(WGPUBindGroup bg) nothrow @nogc @trusted {
    if (bg !is null) wgpuBindGroupRelease(bg);
}
