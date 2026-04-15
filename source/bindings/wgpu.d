/// WGPU-native bindings for the game engine.
/// Based on the official webgpu.h (webgpu-native/webgpu-headers).
/// Only the subset needed for rendering is included.
module bindings.wgpu;

extern (C):
nothrow:
@nogc:

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------
alias WGPUAdapter             = void*;
alias WGPUBindGroup           = void*;
alias WGPUBindGroupLayout     = void*;
alias WGPUBuffer              = void*;
alias WGPUCommandBuffer       = void*;
alias WGPUCommandEncoder      = void*;
alias WGPUComputePassEncoder  = void*;
alias WGPUComputePipeline     = void*;
alias WGPUDevice              = void*;
alias WGPUInstance             = void*;
alias WGPUPipelineLayout      = void*;
alias WGPUQuerySet            = void*;
alias WGPUQueue               = void*;
alias WGPURenderBundle        = void*;
alias WGPURenderBundleEncoder = void*;
alias WGPURenderPassEncoder   = void*;
alias WGPURenderPipeline      = void*;
alias WGPUSampler             = void*;
alias WGPUShaderModule        = void*;
alias WGPUSurface             = void*;
alias WGPUTexture             = void*;
alias WGPUTextureView         = void*;

// ---------------------------------------------------------------------------
// Scalar types
// ---------------------------------------------------------------------------
alias WGPUBool  = uint;   // 0 = false, 1 = true
alias WGPUFlags = ulong;

enum WGPUBool WGPU_FALSE = 0;
enum WGPUBool WGPU_TRUE  = 1;

// ---------------------------------------------------------------------------
// String view (new in webgpu.h)
// ---------------------------------------------------------------------------
enum size_t WGPU_STRLEN = size_t.max;

struct WGPUStringView {
    const(char)* data;
    size_t length = WGPU_STRLEN;
}

WGPUStringView wgpuStringView(const(char)* s) {
    return WGPUStringView(s, WGPU_STRLEN);
}

// ---------------------------------------------------------------------------
// Chained struct
// ---------------------------------------------------------------------------
struct WGPUChainedStruct {
    WGPUChainedStruct* next;
    WGPUSType sType;
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------
enum WGPUSType : uint {
    shaderSourceSPIRV              = 0x0000_0001,
    shaderSourceWGSL               = 0x0000_0002,
    renderPassMaxDrawCount         = 0x0000_0003,
    surfaceSourceMetalLayer        = 0x0000_0004,
    surfaceSourceWindowsHWND       = 0x0000_0005,
    surfaceSourceXlibWindow        = 0x0000_0006,
    surfaceSourceWaylandSurface    = 0x0000_0007,
    surfaceSourceAndroidNativeWindow = 0x0000_0008,
    surfaceSourceXCBWindow         = 0x0000_0009,
}

enum WGPUBackendType : uint {
    undefined = 0x0000_0000,
    null_     = 0x0000_0001,
    webGPU    = 0x0000_0002,
    d3d11     = 0x0000_0003,
    d3d12     = 0x0000_0004,
    metal     = 0x0000_0005,
    vulkan    = 0x0000_0006,
    openGL    = 0x0000_0007,
    openGLES  = 0x0000_0008,
}

enum WGPUPowerPreference : uint {
    undefined       = 0x0000_0000,
    lowPower        = 0x0000_0001,
    highPerformance = 0x0000_0002,
}

enum WGPUFeatureLevel : uint {
    undefined     = 0x0000_0000,
    compatibility = 0x0000_0001,
    core          = 0x0000_0002,
}

enum WGPUPresentMode : uint {
    undefined   = 0x0000_0000,
    fifo        = 0x0000_0001,
    fifoRelaxed = 0x0000_0002,
    immediate   = 0x0000_0003,
    mailbox     = 0x0000_0004,
}

enum WGPUCompositeAlphaMode : uint {
    auto_    = 0x0000_0000,
    opaque   = 0x0000_0001,
    premultiplied = 0x0000_0002,
    unpremultiplied = 0x0000_0003,
    inherit_ = 0x0000_0004,
}

enum WGPUTextureFormat : uint {
    undefined       = 0x0000_0000,
    r8Unorm         = 0x0000_0001,
    r8Snorm         = 0x0000_0002,
    r8Uint          = 0x0000_0003,
    r8Sint          = 0x0000_0004,
    rg8Unorm        = 0x0000_000A,
    rg8Snorm        = 0x0000_000B,
    rgba8Unorm      = 0x0000_0016,
    rgba8UnormSrgb  = 0x0000_0017,
    rgba8Snorm      = 0x0000_0018,
    bgra8Unorm      = 0x0000_001B,
    bgra8UnormSrgb  = 0x0000_001C,
    depth24Plus            = 0x0000_002E,
    depth24PlusStencil8    = 0x0000_002F,
    depth32Float           = 0x0000_0030,
    depth32FloatStencil8   = 0x0000_0031,
}

enum WGPUTextureUsage : WGPUFlags {
    none              = 0x0000_0000,
    copySrc           = 0x0000_0001,
    copyDst           = 0x0000_0002,
    textureBinding    = 0x0000_0004,
    storageBinding    = 0x0000_0008,
    renderAttachment  = 0x0000_0010,
}

enum WGPUBufferUsage : WGPUFlags {
    none     = 0x0000_0000,
    mapRead  = 0x0000_0001,
    mapWrite = 0x0000_0002,
    copySrc  = 0x0000_0004,
    copyDst  = 0x0000_0008,
    index    = 0x0000_0010,
    vertex   = 0x0000_0020,
    uniform  = 0x0000_0040,
    storage  = 0x0000_0080,
    indirect = 0x0000_0100,
}

enum WGPULoadOp : uint {
    undefined = 0x0000_0000,
    load      = 0x0000_0001,
    clear     = 0x0000_0002,
}

enum WGPUStoreOp : uint {
    undefined = 0x0000_0000,
    store     = 0x0000_0001,
    discard   = 0x0000_0002,
}

enum WGPUPrimitiveTopology : uint {
    undefined     = 0x0000_0000,
    pointList     = 0x0000_0001,
    lineList      = 0x0000_0002,
    lineStrip     = 0x0000_0003,
    triangleList  = 0x0000_0004,
    triangleStrip = 0x0000_0005,
}

enum WGPUIndexFormat : uint {
    undefined = 0x0000_0000,
    uint16    = 0x0000_0001,
    uint32    = 0x0000_0002,
}

enum WGPUFrontFace : uint {
    undefined = 0x0000_0000,
    ccw       = 0x0000_0001,
    cw        = 0x0000_0002,
}

enum WGPUCullMode : uint {
    undefined = 0x0000_0000,
    none      = 0x0000_0001,
    front     = 0x0000_0002,
    back      = 0x0000_0003,
}

enum WGPUVertexFormat : uint {
    float32   = 0x0000_001C,
    float32x2 = 0x0000_001D,
    float32x3 = 0x0000_001E,
    float32x4 = 0x0000_001F,
    uint32    = 0x0000_0020,
    uint32x2  = 0x0000_0021,
    uint32x3  = 0x0000_0022,
    uint32x4  = 0x0000_0023,
    unorm8x4  = 0x0000_0009,
}

enum WGPUVertexStepMode : uint {
    undefined = 0x0000_0000,
    vertex    = 0x0000_0001,
    instance_ = 0x0000_0002,
}

enum WGPUColorWriteMask : WGPUFlags {
    none  = 0x0000_0000,
    red   = 0x0000_0001,
    green = 0x0000_0002,
    blue  = 0x0000_0004,
    alpha = 0x0000_0008,
    all   = 0x0000_000F,
}

enum WGPUBlendFactor : uint {
    undefined       = 0x0000_0000,
    zero            = 0x0000_0001,
    one             = 0x0000_0002,
    src             = 0x0000_0003,
    oneMinusSrc     = 0x0000_0004,
    srcAlpha        = 0x0000_0005,
    oneMinusSrcAlpha = 0x0000_0006,
    dst             = 0x0000_0007,
    oneMinusDst     = 0x0000_0008,
    dstAlpha        = 0x0000_0009,
    oneMinusDstAlpha = 0x0000_000A,
}

enum WGPUBlendOperation : uint {
    undefined      = 0x0000_0000,
    add            = 0x0000_0001,
    subtract       = 0x0000_0002,
    reverseSubtract = 0x0000_0003,
    min            = 0x0000_0004,
    max            = 0x0000_0005,
}

enum WGPUTextureViewDimension : uint {
    undefined  = 0x0000_0000,
    dim1D      = 0x0000_0001,
    dim2D      = 0x0000_0002,
    dim2DArray = 0x0000_0003,
    cube       = 0x0000_0004,
    cubeArray  = 0x0000_0005,
    dim3D      = 0x0000_0006,
}

enum WGPUTextureAspect : uint {
    undefined   = 0x0000_0000,
    all         = 0x0000_0001,
    stencilOnly = 0x0000_0002,
    depthOnly   = 0x0000_0003,
}

enum WGPUTextureDimension : uint {
    undefined = 0x0000_0000,
    dim1D     = 0x0000_0001,
    dim2D     = 0x0000_0002,
    dim3D     = 0x0000_0003,
}

enum WGPURequestAdapterStatus : uint {
    success           = 0x0000_0001,
    callbackCancelled = 0x0000_0002,
    unavailable       = 0x0000_0003,
    error             = 0x0000_0004,
}

enum WGPURequestDeviceStatus : uint {
    success           = 0x0000_0001,
    callbackCancelled = 0x0000_0002,
    error             = 0x0000_0003,
}

enum WGPUSurfaceGetCurrentTextureStatus : uint {
    successOptimal    = 0x0000_0001,
    successSuboptimal = 0x0000_0002,
    timeout           = 0x0000_0003,
    outdated          = 0x0000_0004,
    lost              = 0x0000_0005,
    error             = 0x0000_0006,
}

enum WGPUCallbackMode : uint {
    waitAnyOnly       = 0x0000_0001,
    allowProcessEvents = 0x0000_0002,
    allowSpontaneous  = 0x0000_0003,
}

enum WGPUDeviceLostReason : uint {
    unknown           = 0x0000_0001,
    destroyed         = 0x0000_0002,
    callbackCancelled = 0x0000_0003,
    failedCreation    = 0x0000_0004,
}

enum WGPUErrorType : uint {
    noError    = 0x0000_0001,
    validation = 0x0000_0002,
    outOfMemory = 0x0000_0003,
    internal_  = 0x0000_0004,
    unknown    = 0x0000_0005,
}

enum WGPUStatus : uint {
    success = 0x0000_0001,
    error   = 0x0000_0002,
}

enum WGPUOptionalBool : uint {
    false_    = 0x0000_0000,
    true_     = 0x0000_0001,
    undefined = 0x0000_0002,
}

enum WGPUCompareFunction : uint {
    undefined    = 0x0000_0000,
    never        = 0x0000_0001,
    less         = 0x0000_0002,
    equal        = 0x0000_0003,
    lessEqual    = 0x0000_0004,
    greater      = 0x0000_0005,
    notEqual     = 0x0000_0006,
    greaterEqual = 0x0000_0007,
    always       = 0x0000_0008,
}

enum WGPUStencilOperation : uint {
    undefined      = 0x0000_0000,
    keep           = 0x0000_0001,
    zero           = 0x0000_0002,
    replace        = 0x0000_0003,
    invert         = 0x0000_0004,
    incrementClamp = 0x0000_0005,
    decrementClamp = 0x0000_0006,
    incrementWrap  = 0x0000_0007,
    decrementWrap  = 0x0000_0008,
}

enum WGPUBufferBindingType : uint {
    bindingNotUsed  = 0x0000_0000,
    undefined       = 0x0000_0001,
    uniform         = 0x0000_0002,
    storage         = 0x0000_0003,
    readOnlyStorage = 0x0000_0004,
}

enum WGPUSamplerBindingType : uint {
    bindingNotUsed = 0x0000_0000,
    undefined      = 0x0000_0001,
    filtering      = 0x0000_0002,
    nonFiltering   = 0x0000_0003,
    comparison     = 0x0000_0004,
}

enum WGPUTextureSampleType : uint {
    bindingNotUsed    = 0x0000_0000,
    undefined         = 0x0000_0001,
    float_            = 0x0000_0002,
    unfilterableFloat = 0x0000_0003,
    depth             = 0x0000_0004,
    sint              = 0x0000_0005,
    uint_             = 0x0000_0006,
}

enum WGPUStorageTextureAccess : uint {
    bindingNotUsed = 0x0000_0000,
    undefined      = 0x0000_0001,
    writeOnly      = 0x0000_0002,
    readOnly       = 0x0000_0003,
    readWrite      = 0x0000_0004,
}

enum WGPUFilterMode : uint {
    undefined = 0x0000_0000,
    nearest   = 0x0000_0001,
    linear    = 0x0000_0002,
}

enum WGPUMipmapFilterMode : uint {
    undefined = 0x0000_0000,
    nearest   = 0x0000_0001,
    linear    = 0x0000_0002,
}

enum WGPUAddressMode : uint {
    undefined    = 0x0000_0000,
    clampToEdge  = 0x0000_0001,
    repeat       = 0x0000_0002,
    mirrorRepeat = 0x0000_0003,
}

enum WGPUShaderStage : WGPUFlags {
    none     = 0x0000_0000,
    vertex   = 0x0000_0001,
    fragment = 0x0000_0002,
    compute  = 0x0000_0004,
}

// ---------------------------------------------------------------------------
// Sentinel constants
// ---------------------------------------------------------------------------
enum uint WGPU_DEPTH_SLICE_UNDEFINED      = 0xFFFF_FFFF;
enum uint WGPU_MIP_LEVEL_COUNT_UNDEFINED  = 0xFFFF_FFFF;
enum uint WGPU_ARRAY_LAYER_COUNT_UNDEFINED = 0xFFFF_FFFF;

// ---------------------------------------------------------------------------
// Callback types
// ---------------------------------------------------------------------------
alias WGPURequestAdapterCallback = void function(
    WGPURequestAdapterStatus status,
    WGPUAdapter adapter,
    WGPUStringView message,
    void* userdata1,
    void* userdata2,
);

alias WGPURequestDeviceCallback = void function(
    WGPURequestDeviceStatus status,
    WGPUDevice device,
    WGPUStringView message,
    void* userdata1,
    void* userdata2,
);

alias WGPUDeviceLostCallback = void function(
    const(WGPUDevice)* device,
    WGPUDeviceLostReason reason,
    WGPUStringView message,
    void* userdata1,
    void* userdata2,
);

alias WGPUUncapturedErrorCallback = void function(
    const(WGPUDevice)* device,
    WGPUErrorType type,
    WGPUStringView message,
    void* userdata1,
    void* userdata2,
);

// ---------------------------------------------------------------------------
// Descriptor / info structs
// ---------------------------------------------------------------------------
struct WGPUColor {
    double r = 0.0;
    double g = 0.0;
    double b = 0.0;
    double a = 0.0;
}

struct WGPUExtent3D {
    uint width  = 0;
    uint height = 1;
    uint depthOrArrayLayers = 1;
}

struct WGPUFuture {
    ulong id = 0;
}

struct WGPUInstanceDescriptor {
    WGPUChainedStruct* nextInChain;
    size_t requiredFeatureCount = 0;
    void* requiredFeatures;
    void* requiredLimits;
}

struct WGPUSurfaceDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
}

struct WGPUSurfaceSourceWaylandSurface {
    WGPUChainedStruct chain;
    void* display;
    void* surface;
}

struct WGPUSurfaceSourceXlibWindow {
    WGPUChainedStruct chain;
    void* display;
    ulong window;
}

struct WGPURequestAdapterOptions {
    WGPUChainedStruct* nextInChain;
    WGPUFeatureLevel featureLevel = WGPUFeatureLevel.undefined;
    WGPUPowerPreference powerPreference = WGPUPowerPreference.undefined;
    WGPUBool forceFallbackAdapter = WGPU_FALSE;
    WGPUBackendType backendType = WGPUBackendType.undefined;
    WGPUSurface compatibleSurface;
}

struct WGPURequestAdapterCallbackInfo {
    WGPUChainedStruct* nextInChain;
    WGPUCallbackMode mode;
    WGPURequestAdapterCallback callback;
    void* userdata1;
    void* userdata2;
}

struct WGPUQueueDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
}

struct WGPUDeviceLostCallbackInfo {
    WGPUChainedStruct* nextInChain;
    WGPUCallbackMode mode;
    WGPUDeviceLostCallback callback;
    void* userdata1;
    void* userdata2;
}

struct WGPUUncapturedErrorCallbackInfo {
    WGPUChainedStruct* nextInChain;
    WGPUUncapturedErrorCallback callback;
    void* userdata1;
    void* userdata2;
}

struct WGPUDeviceDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    size_t requiredFeatureCount = 0;
    void* requiredFeatures;
    void* requiredLimits;
    WGPUQueueDescriptor defaultQueue;
    WGPUDeviceLostCallbackInfo deviceLostCallbackInfo;
    WGPUUncapturedErrorCallbackInfo uncapturedErrorCallbackInfo;
}

struct WGPURequestDeviceCallbackInfo {
    WGPUChainedStruct* nextInChain;
    WGPUCallbackMode mode;
    WGPURequestDeviceCallback callback;
    void* userdata1;
    void* userdata2;
}

struct WGPUSurfaceConfiguration {
    WGPUChainedStruct* nextInChain;
    WGPUDevice device;
    WGPUTextureFormat format = WGPUTextureFormat.undefined;
    WGPUTextureUsage usage = WGPUTextureUsage.renderAttachment;
    uint width  = 0;
    uint height = 0;
    size_t viewFormatCount = 0;
    WGPUTextureFormat* viewFormats;
    WGPUCompositeAlphaMode alphaMode = WGPUCompositeAlphaMode.auto_;
    WGPUPresentMode presentMode = WGPUPresentMode.undefined;
}

struct WGPUSurfaceTexture {
    WGPUChainedStruct* nextInChain;
    WGPUTexture texture;
    WGPUSurfaceGetCurrentTextureStatus status;
}

struct WGPUSurfaceCapabilities {
    WGPUChainedStruct* nextInChain;
    WGPUTextureUsage usages;
    size_t formatCount;
    WGPUTextureFormat* formats;
    size_t presentModeCount;
    WGPUPresentMode* presentModes;
    size_t alphaModeCount;
    WGPUCompositeAlphaMode* alphaModes;
}

struct WGPUTextureViewDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    WGPUTextureFormat format = WGPUTextureFormat.undefined;
    WGPUTextureViewDimension dimension = WGPUTextureViewDimension.undefined;
    uint baseMipLevel = 0;
    uint mipLevelCount = WGPU_MIP_LEVEL_COUNT_UNDEFINED;
    uint baseArrayLayer = 0;
    uint arrayLayerCount = WGPU_ARRAY_LAYER_COUNT_UNDEFINED;
    WGPUTextureAspect aspect = WGPUTextureAspect.undefined;
    WGPUTextureUsage usage = WGPUTextureUsage.none;
}

struct WGPUCommandEncoderDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
}

struct WGPUCommandBufferDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
}

struct WGPURenderPassColorAttachment {
    WGPUChainedStruct* nextInChain;
    WGPUTextureView view;
    uint depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
    WGPUTextureView resolveTarget;
    WGPULoadOp loadOp = WGPULoadOp.undefined;
    WGPUStoreOp storeOp = WGPUStoreOp.undefined;
    WGPUColor clearValue;
}

struct WGPURenderPassDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    size_t colorAttachmentCount = 0;
    const(WGPURenderPassColorAttachment)* colorAttachments;
    const(WGPURenderPassDepthStencilAttachment)* depthStencilAttachment;
    void* occlusionQuerySet;
    void* timestampWrites;
}

struct WGPURenderPassDepthStencilAttachment {
    WGPUChainedStruct* nextInChain;
    WGPUTextureView view;
    WGPULoadOp depthLoadOp = WGPULoadOp.undefined;
    WGPUStoreOp depthStoreOp = WGPUStoreOp.undefined;
    float depthClearValue = 0.0f;
    WGPUBool depthReadOnly = WGPU_FALSE;
    WGPULoadOp stencilLoadOp = WGPULoadOp.undefined;
    WGPUStoreOp stencilStoreOp = WGPUStoreOp.undefined;
    uint stencilClearValue = 0;
    WGPUBool stencilReadOnly = WGPU_FALSE;
}

// --- Shader ---
struct WGPUShaderSourceWGSL {
    WGPUChainedStruct chain;
    WGPUStringView code;
}

struct WGPUShaderModuleDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
}

// --- Pipeline ---
struct WGPUBlendComponent {
    WGPUBlendOperation operation = WGPUBlendOperation.undefined;
    WGPUBlendFactor srcFactor = WGPUBlendFactor.undefined;
    WGPUBlendFactor dstFactor = WGPUBlendFactor.undefined;
}

struct WGPUBlendState {
    WGPUBlendComponent color;
    WGPUBlendComponent alpha;
}

struct WGPUColorTargetState {
    WGPUChainedStruct* nextInChain;
    WGPUTextureFormat format = WGPUTextureFormat.undefined;
    const(WGPUBlendState)* blend;
    WGPUColorWriteMask writeMask = WGPUColorWriteMask.all;
}

struct WGPUFragmentState {
    WGPUChainedStruct* nextInChain;
    WGPUShaderModule module_;
    WGPUStringView entryPoint;
    size_t constantCount = 0;
    void* constants;
    size_t targetCount = 0;
    const(WGPUColorTargetState)* targets;
}

struct WGPUVertexAttribute {
    WGPUChainedStruct* nextInChain;
    WGPUVertexFormat format;
    ulong offset;
    uint shaderLocation;
}

struct WGPUVertexBufferLayout {
    WGPUChainedStruct* nextInChain;
    WGPUVertexStepMode stepMode = WGPUVertexStepMode.undefined;
    ulong arrayStride;
    size_t attributeCount = 0;
    const(WGPUVertexAttribute)* attributes;
}

struct WGPUVertexState {
    WGPUChainedStruct* nextInChain;
    WGPUShaderModule module_;
    WGPUStringView entryPoint;
    size_t constantCount = 0;
    void* constants;
    size_t bufferCount = 0;
    const(WGPUVertexBufferLayout)* buffers;
}

struct WGPUPrimitiveState {
    WGPUChainedStruct* nextInChain;
    WGPUPrimitiveTopology topology = WGPUPrimitiveTopology.undefined;
    WGPUIndexFormat stripIndexFormat = WGPUIndexFormat.undefined;
    WGPUFrontFace frontFace = WGPUFrontFace.undefined;
    WGPUCullMode cullMode = WGPUCullMode.undefined;
    WGPUBool unclippedDepth = WGPU_FALSE;
}

struct WGPUMultisampleState {
    WGPUChainedStruct* nextInChain;
    uint count = 1;
    uint mask = 0xFFFF_FFFF;
    WGPUBool alphaToCoverageEnabled = WGPU_FALSE;
}

struct WGPUStencilFaceState {
    WGPUCompareFunction compare = WGPUCompareFunction.undefined;
    WGPUStencilOperation failOp = WGPUStencilOperation.undefined;
    WGPUStencilOperation depthFailOp = WGPUStencilOperation.undefined;
    WGPUStencilOperation passOp = WGPUStencilOperation.undefined;
}

struct WGPUDepthStencilState {
    WGPUChainedStruct* nextInChain;
    WGPUTextureFormat format = WGPUTextureFormat.undefined;
    WGPUOptionalBool depthWriteEnabled = WGPUOptionalBool.undefined;
    WGPUCompareFunction depthCompare = WGPUCompareFunction.undefined;
    WGPUStencilFaceState stencilFront;
    WGPUStencilFaceState stencilBack;
    uint stencilReadMask  = 0xFFFF_FFFF;
    uint stencilWriteMask = 0xFFFF_FFFF;
    int depthBias = 0;
    float depthBiasSlopeScale = 0.0f;
    float depthBiasClamp = 0.0f;
}

struct WGPURenderPipelineDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    WGPUPipelineLayout layout;
    WGPUVertexState vertex;
    WGPUPrimitiveState primitive;
    const(WGPUDepthStencilState)* depthStencil;
    WGPUMultisampleState multisample;
    const(WGPUFragmentState)* fragment;
}

struct WGPUPipelineLayoutDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    size_t bindGroupLayoutCount = 0;
    const(WGPUBindGroupLayout)* bindGroupLayouts;
    uint immediateSize = 0;
}

// --- Buffer ---
struct WGPUBufferDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    WGPUBufferUsage usage = WGPUBufferUsage.none;
    ulong size = 0;
    WGPUBool mappedAtCreation = WGPU_FALSE;
}

// --- Texture ---
struct WGPUTextureDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    WGPUTextureUsage usage = WGPUTextureUsage.none;
    WGPUTextureDimension dimension = WGPUTextureDimension.undefined;
    WGPUExtent3D size;
    WGPUTextureFormat format = WGPUTextureFormat.undefined;
    uint mipLevelCount = 1;
    uint sampleCount = 1;
    size_t viewFormatCount = 0;
    WGPUTextureFormat* viewFormats;
}

// --- Sampler ---
struct WGPUSamplerDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    WGPUAddressMode addressModeU = WGPUAddressMode.clampToEdge;
    WGPUAddressMode addressModeV = WGPUAddressMode.clampToEdge;
    WGPUAddressMode addressModeW = WGPUAddressMode.clampToEdge;
    WGPUFilterMode magFilter = WGPUFilterMode.nearest;
    WGPUFilterMode minFilter = WGPUFilterMode.nearest;
    WGPUMipmapFilterMode mipmapFilter = WGPUMipmapFilterMode.nearest;
    float lodMinClamp = 0.0f;
    float lodMaxClamp = 32.0f;
    WGPUCompareFunction compare = WGPUCompareFunction.undefined;
    ushort maxAnisotropy = 1;
}

// --- Bind Group ---
struct WGPUBufferBindingLayout {
    WGPUChainedStruct* nextInChain;
    WGPUBufferBindingType type = WGPUBufferBindingType.bindingNotUsed;
    WGPUBool hasDynamicOffset = WGPU_FALSE;
    ulong minBindingSize = 0;
}

struct WGPUSamplerBindingLayout {
    WGPUChainedStruct* nextInChain;
    WGPUSamplerBindingType type = WGPUSamplerBindingType.bindingNotUsed;
}

struct WGPUTextureBindingLayout {
    WGPUChainedStruct* nextInChain;
    WGPUTextureSampleType sampleType = WGPUTextureSampleType.bindingNotUsed;
    WGPUTextureViewDimension viewDimension = WGPUTextureViewDimension.undefined;
    WGPUBool multisampled = WGPU_FALSE;
}

struct WGPUStorageTextureBindingLayout {
    WGPUChainedStruct* nextInChain;
    WGPUStorageTextureAccess access = WGPUStorageTextureAccess.bindingNotUsed;
    WGPUTextureFormat format = WGPUTextureFormat.undefined;
    WGPUTextureViewDimension viewDimension = WGPUTextureViewDimension.undefined;
}

struct WGPUBindGroupLayoutEntry {
    WGPUChainedStruct* nextInChain;
    uint binding = 0;
    WGPUShaderStage visibility = WGPUShaderStage.none;
    uint bindingArraySize = 0;
    WGPUBufferBindingLayout buffer;
    WGPUSamplerBindingLayout sampler;
    WGPUTextureBindingLayout texture;
    WGPUStorageTextureBindingLayout storageTexture;
}

struct WGPUBindGroupLayoutDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    size_t entryCount = 0;
    const(WGPUBindGroupLayoutEntry)* entries;
}

struct WGPUBindGroupEntry {
    WGPUChainedStruct* nextInChain;
    uint binding = 0;
    WGPUBuffer buffer;
    ulong offset = 0;
    ulong size = 0;
    WGPUSampler sampler;
    WGPUTextureView textureView;
}

struct WGPUBindGroupDescriptor {
    WGPUChainedStruct* nextInChain;
    WGPUStringView label;
    WGPUBindGroupLayout layout;
    size_t entryCount = 0;
    const(WGPUBindGroupEntry)* entries;
}

// --- Texture write ---
struct WGPUOrigin3D {
    uint x = 0;
    uint y = 0;
    uint z = 0;
}

struct WGPUImageCopyTexture {
    WGPUTexture texture;
    uint mipLevel = 0;
    WGPUOrigin3D origin;
    WGPUTextureAspect aspect = WGPUTextureAspect.all;
}

struct WGPUTextureDataLayout {
    ulong offset = 0;
    uint bytesPerRow = 0;
    uint rowsPerImage = 0;
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

// Global
WGPUInstance wgpuCreateInstance(const(WGPUInstanceDescriptor)* descriptor);

// Instance
WGPUSurface wgpuInstanceCreateSurface(WGPUInstance instance, const(WGPUSurfaceDescriptor)* descriptor);
WGPUFuture wgpuInstanceRequestAdapter(WGPUInstance instance, const(WGPURequestAdapterOptions)* options, WGPURequestAdapterCallbackInfo callbackInfo);
void wgpuInstanceProcessEvents(WGPUInstance instance);
void wgpuInstanceAddRef(WGPUInstance instance);
void wgpuInstanceRelease(WGPUInstance instance);

// Adapter
WGPUFuture wgpuAdapterRequestDevice(WGPUAdapter adapter, const(WGPUDeviceDescriptor)* descriptor, WGPURequestDeviceCallbackInfo callbackInfo);
void wgpuAdapterAddRef(WGPUAdapter adapter);
void wgpuAdapterRelease(WGPUAdapter adapter);

// Device
WGPUQueue wgpuDeviceGetQueue(WGPUDevice device);
WGPUCommandEncoder wgpuDeviceCreateCommandEncoder(WGPUDevice device, const(WGPUCommandEncoderDescriptor)* descriptor);
WGPUShaderModule wgpuDeviceCreateShaderModule(WGPUDevice device, const(WGPUShaderModuleDescriptor)* descriptor);
WGPURenderPipeline wgpuDeviceCreateRenderPipeline(WGPUDevice device, const(WGPURenderPipelineDescriptor)* descriptor);
WGPUBuffer wgpuDeviceCreateBuffer(WGPUDevice device, const(WGPUBufferDescriptor)* descriptor);
WGPUPipelineLayout wgpuDeviceCreatePipelineLayout(WGPUDevice device, const(WGPUPipelineLayoutDescriptor)* descriptor);
WGPUTexture wgpuDeviceCreateTexture(WGPUDevice device, const(WGPUTextureDescriptor)* descriptor);
WGPUSampler wgpuDeviceCreateSampler(WGPUDevice device, const(WGPUSamplerDescriptor)* descriptor);
WGPUBindGroupLayout wgpuDeviceCreateBindGroupLayout(WGPUDevice device, const(WGPUBindGroupLayoutDescriptor)* descriptor);
WGPUBindGroup wgpuDeviceCreateBindGroup(WGPUDevice device, const(WGPUBindGroupDescriptor)* descriptor);
void wgpuDeviceDestroy(WGPUDevice device);
void wgpuDeviceAddRef(WGPUDevice device);
void wgpuDeviceRelease(WGPUDevice device);

// Queue
void wgpuQueueSubmit(WGPUQueue queue, size_t commandCount, const(WGPUCommandBuffer)* commands);
void wgpuQueueWriteBuffer(WGPUQueue queue, WGPUBuffer buffer, ulong bufferOffset, const(void)* data, size_t size);
void wgpuQueueWriteTexture(WGPUQueue queue, const(WGPUImageCopyTexture)* destination, const(void)* data, size_t dataSize, const(WGPUTextureDataLayout)* dataLayout, const(WGPUExtent3D)* writeSize);
void wgpuQueueAddRef(WGPUQueue queue);
void wgpuQueueRelease(WGPUQueue queue);

// Surface
void wgpuSurfaceConfigure(WGPUSurface surface, const(WGPUSurfaceConfiguration)* config);
void wgpuSurfaceGetCurrentTexture(WGPUSurface surface, WGPUSurfaceTexture* surfaceTexture);
WGPUStatus wgpuSurfacePresent(WGPUSurface surface);
void wgpuSurfaceUnconfigure(WGPUSurface surface);
WGPUStatus wgpuSurfaceGetCapabilities(WGPUSurface surface, WGPUAdapter adapter, WGPUSurfaceCapabilities* capabilities);
void wgpuSurfaceCapabilitiesFreeMembers(WGPUSurfaceCapabilities capabilities);
void wgpuSurfaceAddRef(WGPUSurface surface);
void wgpuSurfaceRelease(WGPUSurface surface);

// Texture
WGPUTextureView wgpuTextureCreateView(WGPUTexture texture, const(WGPUTextureViewDescriptor)* descriptor);
uint wgpuTextureGetWidth(WGPUTexture texture);
uint wgpuTextureGetHeight(WGPUTexture texture);
WGPUTextureFormat wgpuTextureGetFormat(WGPUTexture texture);
void wgpuTextureAddRef(WGPUTexture texture);
void wgpuTextureRelease(WGPUTexture texture);

// TextureView
void wgpuTextureViewAddRef(WGPUTextureView view);
void wgpuTextureViewRelease(WGPUTextureView view);

// CommandEncoder
WGPURenderPassEncoder wgpuCommandEncoderBeginRenderPass(WGPUCommandEncoder encoder, const(WGPURenderPassDescriptor)* descriptor);
WGPUCommandBuffer wgpuCommandEncoderFinish(WGPUCommandEncoder encoder, const(WGPUCommandBufferDescriptor)* descriptor);
void wgpuCommandEncoderAddRef(WGPUCommandEncoder encoder);
void wgpuCommandEncoderRelease(WGPUCommandEncoder encoder);

// RenderPassEncoder
void wgpuRenderPassEncoderSetPipeline(WGPURenderPassEncoder encoder, WGPURenderPipeline pipeline);
void wgpuRenderPassEncoderSetVertexBuffer(WGPURenderPassEncoder encoder, uint slot, WGPUBuffer buffer, ulong offset, ulong size);
void wgpuRenderPassEncoderSetIndexBuffer(WGPURenderPassEncoder encoder, WGPUBuffer buffer, WGPUIndexFormat format, ulong offset, ulong size);
void wgpuRenderPassEncoderSetBindGroup(WGPURenderPassEncoder encoder, uint groupIndex, WGPUBindGroup group, size_t dynamicOffsetCount, const(uint)* dynamicOffsets);
void wgpuRenderPassEncoderDraw(WGPURenderPassEncoder encoder, uint vertexCount, uint instanceCount, uint firstVertex, uint firstInstance);
void wgpuRenderPassEncoderDrawIndexed(WGPURenderPassEncoder encoder, uint indexCount, uint instanceCount, uint firstIndex, int baseVertex, uint firstInstance);
void wgpuRenderPassEncoderEnd(WGPURenderPassEncoder encoder);
void wgpuRenderPassEncoderAddRef(WGPURenderPassEncoder encoder);
void wgpuRenderPassEncoderRelease(WGPURenderPassEncoder encoder);

// Buffer
void* wgpuBufferGetMappedRange(WGPUBuffer buffer, size_t offset, size_t size);
void wgpuBufferUnmap(WGPUBuffer buffer);
void wgpuBufferDestroy(WGPUBuffer buffer);
void wgpuBufferAddRef(WGPUBuffer buffer);
void wgpuBufferRelease(WGPUBuffer buffer);

// ShaderModule
void wgpuShaderModuleAddRef(WGPUShaderModule module_);
void wgpuShaderModuleRelease(WGPUShaderModule module_);

// RenderPipeline
void wgpuRenderPipelineAddRef(WGPURenderPipeline pipeline);
void wgpuRenderPipelineRelease(WGPURenderPipeline pipeline);

// PipelineLayout
void wgpuPipelineLayoutAddRef(WGPUPipelineLayout layout);
void wgpuPipelineLayoutRelease(WGPUPipelineLayout layout);

// CommandBuffer
void wgpuCommandBufferAddRef(WGPUCommandBuffer buffer);
void wgpuCommandBufferRelease(WGPUCommandBuffer buffer);

// Sampler
void wgpuSamplerAddRef(WGPUSampler sampler);
void wgpuSamplerRelease(WGPUSampler sampler);

// BindGroup
void wgpuBindGroupAddRef(WGPUBindGroup group);
void wgpuBindGroupRelease(WGPUBindGroup group);

// BindGroupLayout
void wgpuBindGroupLayoutAddRef(WGPUBindGroupLayout layout);
void wgpuBindGroupLayoutRelease(WGPUBindGroupLayout layout);
