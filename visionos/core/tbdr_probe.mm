// TBDR probe: does keeping a deferred renderer's G-buffer in tile memory pay on the Vision Pro,
// and can MoltenVK do it?
//
// Run once at the start of the session (Host::StartSession, after the frame keeper started; off
// with PT_VP_TBDR_PROBE=0). The same deferred frame — G-buffer (3 layers of overdraw, the engine's
// formats), 16 additive lights reading it, composition — is drawn at 1384x1384 four ways:
//   A  Vulkan, separate render passes, G-buffer stored to memory and sampled (what the game does)
//   B  Vulkan, one render pass with 3 subpasses, input attachments, transient (lazily allocated)
//      attachments: what MoltenVK should turn into tile memory — the risk being measured
//   M1 Metal, separate encoders, stored textures (A without MoltenVK: its own overhead)
//   M2 Metal, one encoder, memoryless G-buffer read with programmable blending (the best case)
// A, M1 and M2 run first with their rounds interleaved (A, M1, M2, A, ...: same thermal state and
// background load); B, the risky one, runs last beside a second A, so a MoltenVK failure on it leaves
// the other numbers in the log already. Each is timed with the GPU clock of its Metal command buffer (Vulkan ones through
// vkCmdEncodeMetalMVK), Vulkan timestamps and wall time; a few output pixels are read back so a
// variant that is fast because it is wrong shows. The Metal storage mode of B's attachments says
// whether MoltenVK made them memoryless.

#include "engine/core/log.h"
#include "engine/render/vk.h"
#include "engine/render/vk_context.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

extern "C" void vkCmdEncodeMetalMVK(VkCommandBuffer commandBuffer, void (*callback)(void* data, void* mtlCommandBuffer), const void* data,
                                    uint32_t dataSize);

namespace pt::visionos {
namespace {

constexpr uint32_t kSize = 1384;
constexpr uint32_t kLayers = 3;
constexpr uint32_t kLights = 16;
constexpr uint32_t kIters = 8;   // frames per command buffer
constexpr uint32_t kRounds = 6;  // command buffers per variant (the first is a warm-up)

enum Att : uint32_t { kAlbedo, kNormal, kMaterial, kDepthCol, kLight, kOut, kDepth, kAttCount };
constexpr VkFormat kFormats[kAttCount] = {VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R16G16B16A16_SFLOAT, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R32_SFLOAT,
                                          VK_FORMAT_R16G16B16A16_SFLOAT, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_D32_SFLOAT};
constexpr MTLPixelFormat kMtlFormats[kAttCount] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA8Unorm,
                                                   MTLPixelFormatR32Float,  MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA8Unorm,
                                                   MTLPixelFormatDepth32Float};
// Pixels read back to compare the variants.
constexpr std::array<std::array<uint32_t, 2>, 4> kPixels{{{692, 692}, {200, 300}, {1100, 900}, {1300, 100}}};

struct Push {
    int32_t mode = 0;
    int32_t pad = 0;
};

struct Times {
    double gpu_ms = -1.0;    // per frame, Metal command buffer GPU time
    double stamp_ms = -1.0;  // per frame, Vulkan timestamps
    double wall_ms = -1.0;   // per frame, submit to fence
};

const char* StorageName(MTLStorageMode m) {
    switch (m) {
        case MTLStorageModeShared: return "shared";
        case MTLStorageModePrivate: return "private";
        case MTLStorageModeMemoryless: return "memoryless";
        default: return "other";
    }
}

double Median(std::vector<double> v) {
    if (v.empty()) return -1.0;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

// The Metal command buffer's GPU time, from inside a Vulkan command buffer.
struct GpuClock {
    std::atomic<double> seconds{-1.0};
};
struct ClockData {
    GpuClock* clock;
};
void AttachClock(void* data, void* mtl_command_buffer) {
    GpuClock* clock = static_cast<ClockData*>(data)->clock;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)mtl_command_buffer;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
      clock->seconds.store(done.GPUEndTime > done.GPUStartTime ? done.GPUEndTime - done.GPUStartTime : 0.0);
    }];
}

const char* kMetalSource = R"(
#include <metal_stdlib>
using namespace metal;
struct VO { float4 pos [[position]]; int inst [[flat]]; };
vertex VO probe_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant int2& pc [[buffer(0)]]) {
    float2 v = float2((vid << 1) & 2, vid & 2);
    float2 p = v * 2.0 - 1.0;
    float z = 0.5;
    if (pc.x == 0) z = 0.9 - 0.2 * float(iid);
    else if (pc.x == 1) { float a = float(iid) * 2.399; p = 0.45 * float2(cos(a), sin(a)) + (v * 2.0 - 1.0) * 0.55; }
    VO o; o.pos = float4(p.x, -p.y, z, 1.0); o.inst = int(iid); return o;
}
static float probe_hash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }
static float3 probe_shade(float4 a, float4 nrm, float4 m, float d, int inst, float2 fc) {
    float ang = float(inst) * 2.399;
    float3 lp = float3(0.45 * cos(ang), 0.45 * sin(ang), 0.3);
    float3 pos = float3(fc * 0.00144 - 1.0, d);
    float3 l = lp - pos; float dist = length(l); l /= max(dist, 1e-4);
    float3 n = normalize(nrm.xyz);
    float ndl = max(dot(n, l), 0.0);
    float spec = pow(max(dot(reflect(-l, n), float3(0, 0, 1)), 0.0), 8.0 + m.y * 32.0);
    return (a.rgb * ndl + spec * m.x) / (1.0 + dist * dist * 4.0) * float3(1.0, 0.9, 0.8);
}
static float4 probe_compose(float4 a, float4 light) { float3 c = light.rgb + a.rgb * 0.03; return float4(c / (1.0 + c), 1.0); }
struct G { float4 albedo [[color(0)]]; half4 normal [[color(1)]]; float4 material [[color(2)]]; float depth [[color(3)]]; };
fragment G probe_gbuf(VO in [[stage_in]]) {
    float2 p = in.pos.xy * 0.01 + float(in.inst);
    float n = 0.0;
    for (int i = 0; i < 8; ++i) n += probe_hash(floor(p * float(i + 1))) / float(i + 1);
    G g;
    g.albedo = float4(fract(n), fract(n * 1.7), fract(n * 2.3), 1.0);
    g.normal = half4(float4(normalize(float3(sin(p.x), cos(p.y), 1.0)), n));
    g.material = float4(0.5, fract(n * 3.1), 0.2, 1.0);
    g.depth = in.pos.z;
    return g;
}
// One encoder: the G-buffer read straight from tile memory.
struct LightOut { half4 light [[color(4)]]; };
fragment LightOut probe_light_tile(VO in [[stage_in]], float4 a [[color(0)]], half4 n [[color(1)]], float4 m [[color(2)]], float d [[color(3)]]) {
    LightOut o; o.light = half4(float4(probe_shade(a, float4(n), m, d, in.inst, in.pos.xy), 1.0)); return o;
}
struct CompOut { float4 colour [[color(5)]]; };
fragment CompOut probe_comp_tile(VO in [[stage_in]], float4 a [[color(0)]], half4 light [[color(4)]]) {
    CompOut o; o.colour = probe_compose(a, float4(light)); return o;
}
// Separate encoders: the G-buffer read from memory.
fragment half4 probe_light_tex(VO in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> n [[texture(1)]],
                               texture2d<float> m [[texture(2)]], texture2d<float> d [[texture(3)]]) {
    uint2 c = uint2(in.pos.xy);
    return half4(float4(probe_shade(a.read(c), n.read(c), m.read(c), d.read(c).r, in.inst, in.pos.xy), 1.0));
}
fragment float4 probe_comp_tex(VO in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> light [[texture(1)]]) {
    uint2 c = uint2(in.pos.xy);
    return probe_compose(a.read(c), light.read(c));
}
)";

class Probe {
public:
    Probe(vk::Context& c, id<MTLDevice> device, id<MTLCommandQueue> queue) : c_(c), d_(c.device), mtl_device_(device), mtl_queue_(queue) {}
    ~Probe() { Destroy(); }

    void Run() {
        LogInfo("tbdr: probe at {}x{}: G-buffer {} layers (albedo RGBA8, normal RGBA16F, material RGBA8, depth R32F), {} lights, compose; "
                "{} frames x {} rounds per variant, rounds interleaved",
                kSize, kSize, kLayers, kLights, kIters, kRounds - 1);
        // First the safe ones: Vulkan as the game draws (A) and both Metal variants.
        Samples a, m1, m2;
        const bool vulkan = SetupShared();
        a.ok = vulkan && SetupA();
        m1.ok = m2.ok = SetupMetal();
        if (!a.ok) LogError("tbdr: variant A not set up");
        if (!m1.ok) LogError("tbdr: Metal variants not set up");
        for (uint32_t round = 0; round < kRounds; ++round) {
            const bool warm = round == 0;
            if (a.ok) a.ok = RunVulkanRound(false, a, warm);
            if (m1.ok) m1.ok = RunMetalRound(false, m1, warm);
            if (m2.ok) m2.ok = RunMetalRound(true, m2, warm);
        }
        const Times ta = a.Result(), tm1 = m1.Result(), tm2 = m2.Result();
        Line("A  vulkan, separate passes      ", a, ta);
        Line("M1 metal, separate encoders     ", m1, tm1);
        Line("M2 metal, one encoder+memoryless", m2, tm2);
        if (a.ok && m1.ok && m2.ok) {
            const char* metric = nullptr;
            const std::array<double, 3> v = Pick({ta, tm1, tm2}, metric);
            if (metric)
                LogInfo("tbdr: verdict Metal one encoder: {:+.0f} % vs Vulkan separate passes ({:.2f} -> {:.2f} ms, {}); "
                        "MoltenVK overhead (M1 vs A) {:+.0f} %",
                        (v[2] / v[0] - 1.0) * 100.0, v[0], v[2], metric, (v[1] / v[0] - 1.0) * 100.0);
        }
        // Then B, the risk being measured: MoltenVK may reject it or fail on it. A runs again beside it
        // (same conditions).
        LogInfo("tbdr: now B (if the log stops here, MoltenVK could not run subpasses with transient attachments)");
        Samples a2, b;
        b.ok = a.ok && SetupB();
        a2.ok = b.ok;
        if (!b.ok) LogError("tbdr: variant B not set up");
        for (uint32_t round = 0; round < kRounds && b.ok && a2.ok; ++round) {
            const bool warm = round == 0;
            a2.ok = RunVulkanRound(false, a2, warm);
            if (a2.ok) b.ok = RunVulkanRound(true, b, warm);
        }
        const Times ta2 = a2.Result(), tb = b.Result();
        Line("A' vulkan, separate passes (again)", a2, ta2);
        Line("B  vulkan, subpasses+transient   ", b, tb);
        if (a2.ok && b.ok) {
            const char* metric = nullptr;
            const std::array<double, 3> v = Pick({ta2, tb, tb}, metric);
            if (metric)
                LogInfo("tbdr: verdict MoltenVK subpasses: {:+.0f} % vs separate passes ({:.2f} -> {:.2f} ms, {}){}", (v[1] / v[0] - 1.0) * 100.0,
                        v[0], v[1], metric, b.px == a2.px ? "" : " [pixels differ from A: B may have lost tile contents]");
        }
    }

private:
    struct Samples {
        std::vector<double> gpu, stamp, wall;
        std::array<uint32_t, 4> px{};
        bool ok = false;
        Times Result() const { return {Median(gpu), Median(stamp), Median(wall)}; }
    };

    static void Line(const char* name, const Samples& s, const Times& t) {
        if (!s.ok) {
            LogInfo("tbdr: {} failed", name);
            return;
        }
        LogInfo("tbdr: {} gpu {:.2f} ms/frame (timestamps {:.2f}, wall {:.2f}); pixels {:08x} {:08x} {:08x} {:08x}", name, t.gpu_ms, t.stamp_ms,
                t.wall_ms, s.px[0], s.px[1], s.px[2], s.px[3]);
    }

    // One metric for the whole comparison: the GPU clock if every variant has it, else wall time.
    static std::array<double, 3> Pick(const std::array<Times, 3>& t, const char*& metric) {
        if (t[0].gpu_ms > 0.0 && t[1].gpu_ms > 0.0 && t[2].gpu_ms > 0.0) {
            metric = "GPU clock";
            return {t[0].gpu_ms, t[1].gpu_ms, t[2].gpu_ms};
        }
        if (t[0].wall_ms > 0.0 && t[1].wall_ms > 0.0 && t[2].wall_ms > 0.0) {
            metric = "wall time";
            return {t[0].wall_ms, t[1].wall_ms, t[2].wall_ms};
        }
        metric = nullptr;
        LogWarn("tbdr: no common timing to compare");
        return {};
    }
    struct Img {
        VkImage image = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
    };

    // ---------------------------------------------------------------- Vulkan
    uint32_t MemoryType(uint32_t bits, VkMemoryPropertyFlags want) {
        VkPhysicalDeviceMemoryProperties props{};
        vkGetPhysicalDeviceMemoryProperties(c_.physical, &props);
        for (uint32_t t = 0; t < props.memoryTypeCount; ++t)
            if ((bits & (1u << t)) && (props.memoryTypes[t].propertyFlags & want) == want) return t;
        return UINT32_MAX;
    }

    bool MakeImage(Img& out, Att att, bool transient, const char* what) {
        const bool depth = att == kDepth;
        VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        info.imageType = VK_IMAGE_TYPE_2D;
        info.format = kFormats[att];
        info.extent = {kSize, kSize, 1};
        info.mipLevels = 1;
        info.arrayLayers = 1;
        info.samples = VK_SAMPLE_COUNT_1_BIT;
        info.tiling = VK_IMAGE_TILING_OPTIMAL;
        if (depth) {
            info.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        } else if (att == kOut) {
            info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        } else {
            info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | (transient ? VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT : VK_IMAGE_USAGE_SAMPLED_BIT);
        }
        if (transient && att != kOut) info.usage |= VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (vkCreateImage(d_, &info, nullptr, &out.image) != VK_SUCCESS) {
            LogError("tbdr: cannot create the {} image {}", what, static_cast<int>(att));
            return false;
        }
        VkMemoryRequirements req{};
        vkGetImageMemoryRequirements(d_, out.image, &req);
        uint32_t type = UINT32_MAX;
        if (transient && att != kOut) {
            type = MemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT);
            if (type == UINT32_MAX && !lazy_warned_) {
                LogWarn("tbdr: MoltenVK offers no lazily allocated memory for transient attachments (device-local instead)");
                lazy_warned_ = true;
            }
        }
        if (type == UINT32_MAX) type = MemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (type == UINT32_MAX) type = MemoryType(req.memoryTypeBits, 0);
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        alloc.allocationSize = req.size;
        alloc.memoryTypeIndex = type;
        if (type == UINT32_MAX || vkAllocateMemory(d_, &alloc, nullptr, &out.memory) != VK_SUCCESS ||
            vkBindImageMemory(d_, out.image, out.memory, 0) != VK_SUCCESS) {
            LogError("tbdr: cannot allocate the {} image {}", what, static_cast<int>(att));
            return false;
        }
        VkImageViewCreateInfo view{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        view.image = out.image;
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = kFormats[att];
        view.subresourceRange = {static_cast<VkImageAspectFlags>(depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT), 0, 1, 0, 1};
        return vkCreateImageView(d_, &view, nullptr, &out.view) == VK_SUCCESS;
    }

    MTLStorageMode Storage(VkImage image) {
        auto fn = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(vkGetDeviceProcAddr(d_, "vkExportMetalObjectsEXT"));
        if (!fn) return MTLStorageModeShared;
        VkExportMetalTextureInfoEXT texture{VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT};
        texture.image = image;
        texture.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
        VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
        objects.pNext = &texture;
        fn(d_, &objects);
        return texture.mtlTexture ? texture.mtlTexture.storageMode : MTLStorageModeShared;
    }

    VkAttachmentDescription Attachment(Att att, VkAttachmentStoreOp store, VkImageLayout final_layout) {
        VkAttachmentDescription a{};
        a.format = kFormats[att];
        a.samples = VK_SAMPLE_COUNT_1_BIT;
        a.loadOp = att == kOut ? VK_ATTACHMENT_LOAD_OP_DONT_CARE : VK_ATTACHMENT_LOAD_OP_CLEAR;
        a.storeOp = store;
        a.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        a.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        a.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        a.finalLayout = final_layout;
        return a;
    }

    VkRenderPass MakeRenderPass(const std::vector<VkAttachmentDescription>& atts, const std::vector<VkSubpassDescription>& subs,
                                std::vector<VkSubpassDependency> deps) {
        // Outside the pass: everything before and after it, heavy-handed (MoltenVK tracks hazards anyway).
        const VkPipelineStageFlags stages = VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
        const VkAccessFlags access = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT |
                                     VK_ACCESS_TRANSFER_READ_BIT;
        deps.push_back({VK_SUBPASS_EXTERNAL, 0, stages, stages, access, access, 0});
        deps.push_back({static_cast<uint32_t>(subs.size() - 1), VK_SUBPASS_EXTERNAL, stages, stages, access, access, 0});
        VkRenderPassCreateInfo info{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        info.attachmentCount = static_cast<uint32_t>(atts.size());
        info.pAttachments = atts.data();
        info.subpassCount = static_cast<uint32_t>(subs.size());
        info.pSubpasses = subs.data();
        info.dependencyCount = static_cast<uint32_t>(deps.size());
        info.pDependencies = deps.data();
        VkRenderPass rp = VK_NULL_HANDLE;
        if (vkCreateRenderPass(d_, &info, nullptr, &rp) != VK_SUCCESS) return VK_NULL_HANDLE;
        render_passes_.push_back(rp);
        return rp;
    }

    VkFramebuffer MakeFramebuffer(VkRenderPass rp, const std::vector<VkImageView>& views) {
        VkFramebufferCreateInfo info{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        info.renderPass = rp;
        info.attachmentCount = static_cast<uint32_t>(views.size());
        info.pAttachments = views.data();
        info.width = kSize;
        info.height = kSize;
        info.layers = 1;
        VkFramebuffer fb = VK_NULL_HANDLE;
        if (vkCreateFramebuffer(d_, &info, nullptr, &fb) != VK_SUCCESS) return VK_NULL_HANDLE;
        framebuffers_.push_back(fb);
        return fb;
    }

    VkDescriptorSetLayout MakeSetLayout(uint32_t count, VkDescriptorType type) {
        std::vector<VkDescriptorSetLayoutBinding> bindings(count);
        for (uint32_t i = 0; i < count; ++i) bindings[i] = {i, type, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
        VkDescriptorSetLayoutCreateInfo info{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        info.bindingCount = count;
        info.pBindings = bindings.data();
        VkDescriptorSetLayout layout = VK_NULL_HANDLE;
        if (vkCreateDescriptorSetLayout(d_, &info, nullptr, &layout) != VK_SUCCESS) return VK_NULL_HANDLE;
        set_layouts_.push_back(layout);
        return layout;
    }

    VkPipelineLayout MakePipelineLayout(VkDescriptorSetLayout set) {
        VkPushConstantRange range{VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(Push)};
        VkPipelineLayoutCreateInfo info{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        info.setLayoutCount = set ? 1 : 0;
        info.pSetLayouts = set ? &set : nullptr;
        info.pushConstantRangeCount = 1;
        info.pPushConstantRanges = &range;
        VkPipelineLayout layout = VK_NULL_HANDLE;
        if (vkCreatePipelineLayout(d_, &info, nullptr, &layout) != VK_SUCCESS) return VK_NULL_HANDLE;
        pipeline_layouts_.push_back(layout);
        return layout;
    }

    VkPipeline MakePipeline(VkRenderPass rp, uint32_t subpass, VkPipelineLayout layout, VkShaderModule frag, uint32_t colours, bool additive,
                            bool depth) {
        VkPipelineShaderStageCreateInfo stages[2]{};
        stages[0] = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0, VK_SHADER_STAGE_VERTEX_BIT, vert_, "main", nullptr};
        stages[1] = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0, VK_SHADER_STAGE_FRAGMENT_BIT, frag, "main", nullptr};
        VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkViewport viewport{0.0f, 0.0f, static_cast<float>(kSize), static_cast<float>(kSize), 0.0f, 1.0f};
        VkRect2D scissor{{0, 0}, {kSize, kSize}};
        VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
        vp.viewportCount = 1;
        vp.pViewports = &viewport;
        vp.scissorCount = 1;
        vp.pScissors = &scissor;
        VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineDepthStencilStateCreateInfo ds{VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
        ds.depthTestEnable = depth;
        ds.depthWriteEnable = depth;
        ds.depthCompareOp = VK_COMPARE_OP_LESS;
        std::vector<VkPipelineColorBlendAttachmentState> blends(colours);
        for (auto& b : blends) {
            b = {};
            b.colorWriteMask = 0xF;
            if (additive) {
                b.blendEnable = VK_TRUE;
                b.srcColorBlendFactor = b.dstColorBlendFactor = VK_BLEND_FACTOR_ONE;
                b.srcAlphaBlendFactor = b.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
                b.colorBlendOp = b.alphaBlendOp = VK_BLEND_OP_ADD;
            }
        }
        VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
        blend.attachmentCount = colours;
        blend.pAttachments = blends.data();
        VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        info.stageCount = 2;
        info.pStages = stages;
        info.pVertexInputState = &vertex;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &vp;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &ms;
        info.pDepthStencilState = &ds;
        info.pColorBlendState = &blend;
        info.layout = layout;
        info.renderPass = rp;
        info.subpass = subpass;
        VkPipeline p = VK_NULL_HANDLE;
        if (vkCreateGraphicsPipelines(d_, VK_NULL_HANDLE, 1, &info, nullptr, &p) != VK_SUCCESS) return VK_NULL_HANDLE;
        pipelines_.push_back(p);
        return p;
    }

    VkShaderModule Shader(const char* name) {
        VkShaderModule m = vk::LoadShaderModule(d_, name);
        if (m) modules_.push_back(m);
        else LogError("tbdr: no shader {}", name);
        return m;
    }

    void WriteSet(VkDescriptorSet set, const std::vector<VkImageView>& views, bool input) {
        std::vector<VkDescriptorImageInfo> infos(views.size());
        std::vector<VkWriteDescriptorSet> writes(views.size());
        for (size_t i = 0; i < views.size(); ++i) {
            infos[i] = {input ? VK_NULL_HANDLE : sampler_, views[i], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
            writes[i] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
            writes[i].dstSet = set;
            writes[i].dstBinding = static_cast<uint32_t>(i);
            writes[i].descriptorCount = 1;
            writes[i].descriptorType = input ? VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT : VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[i].pImageInfo = &infos[i];
        }
        vkUpdateDescriptorSets(d_, static_cast<uint32_t>(writes.size()), writes.data(), 0, nullptr);
    }

    // Shaders, descriptors, layouts, commands, timestamps and read-back: what A and B share.
    bool SetupShared() {
        vert_ = Shader("tbdr_probe.vert");
        frag_gbuf_ = Shader("tbdr_probe_gbuf.frag");
        frag_light_tex_ = Shader("tbdr_probe_light_tex.frag");
        frag_light_in_ = Shader("tbdr_probe_light_in.frag");
        frag_comp_tex_ = Shader("tbdr_probe_comp_tex.frag");
        frag_comp_in_ = Shader("tbdr_probe_comp_in.frag");
        if (!vert_ || !frag_gbuf_ || !frag_light_tex_ || !frag_light_in_ || !frag_comp_tex_ || !frag_comp_in_) return false;

        VkSamplerCreateInfo sampler{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
        sampler.magFilter = sampler.minFilter = VK_FILTER_NEAREST;
        sampler.addressModeU = sampler.addressModeV = sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        if (vkCreateSampler(d_, &sampler, nullptr, &sampler_) != VK_SUCCESS) return false;

        VkDescriptorSetLayout light_tex_set = MakeSetLayout(4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
        VkDescriptorSetLayout comp_tex_set = MakeSetLayout(2, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
        VkDescriptorSetLayout light_in_set = MakeSetLayout(4, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT);
        VkDescriptorSetLayout comp_in_set = MakeSetLayout(2, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT);
        if (!light_tex_set || !comp_tex_set || !light_in_set || !comp_in_set) return false;
        VkDescriptorPoolSize sizes[2] = {{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 6}, {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 6}};
        VkDescriptorPoolCreateInfo pool{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        pool.maxSets = 4;
        pool.poolSizeCount = 2;
        pool.pPoolSizes = sizes;
        if (vkCreateDescriptorPool(d_, &pool, nullptr, &descriptor_pool_) != VK_SUCCESS) return false;
        VkDescriptorSetLayout layouts[4] = {light_tex_set, comp_tex_set, light_in_set, comp_in_set};
        VkDescriptorSet sets[4]{};
        VkDescriptorSetAllocateInfo alloc{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        alloc.descriptorPool = descriptor_pool_;
        alloc.descriptorSetCount = 4;
        alloc.pSetLayouts = layouts;
        if (vkAllocateDescriptorSets(d_, &alloc, sets) != VK_SUCCESS) return false;
        set_light_tex_ = sets[0];
        set_comp_tex_ = sets[1];
        set_light_in_ = sets[2];
        set_comp_in_ = sets[3];
        pl_gbuf_ = MakePipelineLayout(VK_NULL_HANDLE);
        pl_light_tex_ = MakePipelineLayout(light_tex_set);
        pl_comp_tex_ = MakePipelineLayout(comp_tex_set);
        pl_light_in_ = MakePipelineLayout(light_in_set);
        pl_comp_in_ = MakePipelineLayout(comp_in_set);
        if (!pl_gbuf_ || !pl_light_tex_ || !pl_comp_tex_ || !pl_light_in_ || !pl_comp_in_) return false;

        VkCommandPoolCreateInfo cp{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        cp.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        cp.queueFamilyIndex = c_.queue_family;
        if (vkCreateCommandPool(d_, &cp, nullptr, &command_pool_) != VK_SUCCESS) return false;
        VkCommandBufferAllocateInfo cb{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        cb.commandPool = command_pool_;
        cb.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cb.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(d_, &cb, &cmd_) != VK_SUCCESS) return false;
        VkFenceCreateInfo fence{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        if (vkCreateFence(d_, &fence, nullptr, &fence_) != VK_SUCCESS) return false;
        VkQueryPoolCreateInfo qp{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
        qp.queryType = VK_QUERY_TYPE_TIMESTAMP;
        qp.queryCount = 2;
        if (vkCreateQueryPool(d_, &qp, nullptr, &queries_) != VK_SUCCESS) queries_ = VK_NULL_HANDLE;
        VkBufferCreateInfo buf{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        buf.size = 4 * kPixels.size();
        buf.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        if (vkCreateBuffer(d_, &buf, nullptr, &readback_) != VK_SUCCESS) return false;
        VkMemoryRequirements req{};
        vkGetBufferMemoryRequirements(d_, readback_, &req);
        VkMemoryAllocateInfo ma{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        ma.allocationSize = req.size;
        ma.memoryTypeIndex = MemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (ma.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(d_, &ma, nullptr, &readback_memory_) != VK_SUCCESS ||
            vkBindBufferMemory(d_, readback_, readback_memory_, 0) != VK_SUCCESS)
            return false;
        return true;
    }

    // A: three render passes, the G-buffer stored and sampled.
    bool SetupA() {
        for (uint32_t i = 0; i < kAttCount; ++i)
            if (!MakeImage(sep_[i], static_cast<Att>(i), false, "separate")) return false;
        const VkImageLayout read = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        const VkImageLayout colour = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        const VkImageLayout depth = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        const VkAttachmentStoreOp store = VK_ATTACHMENT_STORE_OP_STORE;
        const VkAttachmentStoreOp drop = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        VkAttachmentReference g_refs[4] = {{0, colour}, {1, colour}, {2, colour}, {3, colour}};
        VkAttachmentReference g_depth{4, depth};
        VkSubpassDescription g_sub{};
        g_sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        g_sub.colorAttachmentCount = 4;
        g_sub.pColorAttachments = g_refs;
        g_sub.pDepthStencilAttachment = &g_depth;
        rp_g_ = MakeRenderPass({Attachment(kAlbedo, store, read), Attachment(kNormal, store, read), Attachment(kMaterial, store, read),
                                Attachment(kDepthCol, store, read), Attachment(kDepth, drop, depth)},
                               {g_sub}, {});
        VkAttachmentReference one{0, colour};
        VkSubpassDescription one_sub{};
        one_sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        one_sub.colorAttachmentCount = 1;
        one_sub.pColorAttachments = &one;
        rp_l_ = MakeRenderPass({Attachment(kLight, store, read)}, {one_sub}, {});
        rp_c_ = MakeRenderPass({Attachment(kOut, store, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)}, {one_sub}, {});
        if (!rp_g_ || !rp_l_ || !rp_c_) return false;
        fb_g_ = MakeFramebuffer(rp_g_, {sep_[kAlbedo].view, sep_[kNormal].view, sep_[kMaterial].view, sep_[kDepthCol].view, sep_[kDepth].view});
        fb_l_ = MakeFramebuffer(rp_l_, {sep_[kLight].view});
        fb_c_ = MakeFramebuffer(rp_c_, {sep_[kOut].view});
        if (!fb_g_ || !fb_l_ || !fb_c_) return false;
        WriteSet(set_light_tex_, {sep_[kAlbedo].view, sep_[kNormal].view, sep_[kMaterial].view, sep_[kDepthCol].view}, false);
        WriteSet(set_comp_tex_, {sep_[kAlbedo].view, sep_[kLight].view}, false);
        p_gbuf_a_ = MakePipeline(rp_g_, 0, pl_gbuf_, frag_gbuf_, 4, false, true);
        p_light_a_ = MakePipeline(rp_l_, 0, pl_light_tex_, frag_light_tex_, 1, true, false);
        p_comp_a_ = MakePipeline(rp_c_, 0, pl_comp_tex_, frag_comp_tex_, 1, false, false);
        if (!p_gbuf_a_ || !p_light_a_ || !p_comp_a_) {
            LogError("tbdr: A pipeline creation failed");
            return false;
        }
        return true;
    }

    // B: one render pass, three subpasses, transient attachments read as input attachments
    // (attachment index = Att).
    bool SetupB() {
        for (uint32_t i = 0; i < kAttCount; ++i)
            if (!MakeImage(tile_[i], static_cast<Att>(i), true, "transient")) return false;
        {
            std::string modes;
            for (uint32_t i = 0; i < kAttCount; ++i) {
                if (i == kOut) continue;
                modes += std::string(modes.empty() ? "" : ", ") + StorageName(Storage(tile_[i].image));
            }
            LogInfo("tbdr: B transient attachments in Metal: {} (memoryless = in tile memory only); A's: {}", modes,
                    StorageName(Storage(sep_[kAlbedo].image)));
        }
        const VkImageLayout read = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        const VkImageLayout colour = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        const VkImageLayout depth = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        const VkAttachmentStoreOp store = VK_ATTACHMENT_STORE_OP_STORE;
        const VkAttachmentStoreOp drop = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        VkAttachmentReference b0_col[4] = {{kAlbedo, colour}, {kNormal, colour}, {kMaterial, colour}, {kDepthCol, colour}};
        VkAttachmentReference b0_depth{kDepth, depth};
        VkAttachmentReference b1_in[4] = {{kAlbedo, read}, {kNormal, read}, {kMaterial, read}, {kDepthCol, read}};
        VkAttachmentReference b1_col{kLight, colour};
        VkAttachmentReference b2_in[2] = {{kAlbedo, read}, {kLight, read}};
        VkAttachmentReference b2_col{kOut, colour};
        VkSubpassDescription subs[3]{};
        for (auto& s : subs) s.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subs[0].colorAttachmentCount = 4;
        subs[0].pColorAttachments = b0_col;
        subs[0].pDepthStencilAttachment = &b0_depth;
        subs[1].inputAttachmentCount = 4;
        subs[1].pInputAttachments = b1_in;
        subs[1].colorAttachmentCount = 1;
        subs[1].pColorAttachments = &b1_col;
        subs[2].inputAttachmentCount = 2;
        subs[2].pInputAttachments = b2_in;
        subs[2].colorAttachmentCount = 1;
        subs[2].pColorAttachments = &b2_col;
        const VkSubpassDependency in_tile0{0, 1, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                           VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_INPUT_ATTACHMENT_READ_BIT, VK_DEPENDENCY_BY_REGION_BIT};
        VkSubpassDependency in_tile1 = in_tile0;
        in_tile1.srcSubpass = 1;
        in_tile1.dstSubpass = 2;
        VkSubpassDependency in_tile02 = in_tile0;  // albedo, written in 0, read in 2
        in_tile02.dstSubpass = 2;
        rp_b_ = MakeRenderPass({Attachment(kAlbedo, drop, read), Attachment(kNormal, drop, read), Attachment(kMaterial, drop, read),
                                Attachment(kDepthCol, drop, read), Attachment(kLight, drop, read),
                                Attachment(kOut, store, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL), Attachment(kDepth, drop, depth)},
                               {subs[0], subs[1], subs[2]}, {in_tile0, in_tile1, in_tile02});
        if (!rp_b_) return false;
        std::vector<VkImageView> b_views;
        for (uint32_t i = 0; i < kAttCount; ++i) b_views.push_back(tile_[i].view);
        fb_b_ = MakeFramebuffer(rp_b_, b_views);
        if (!fb_b_) return false;
        WriteSet(set_light_in_, {tile_[kAlbedo].view, tile_[kNormal].view, tile_[kMaterial].view, tile_[kDepthCol].view}, true);
        WriteSet(set_comp_in_, {tile_[kAlbedo].view, tile_[kLight].view}, true);
        p_gbuf_b_ = MakePipeline(rp_b_, 0, pl_gbuf_, frag_gbuf_, 4, false, true);
        p_light_b_ = MakePipeline(rp_b_, 1, pl_light_in_, frag_light_in_, 1, true, false);
        p_comp_b_ = MakePipeline(rp_b_, 2, pl_comp_in_, frag_comp_in_, 1, false, false);
        if (!p_gbuf_b_ || !p_light_b_ || !p_comp_b_) {
            LogError("tbdr: B pipeline creation failed");
            return false;
        }
        return true;
    }

    void Begin(VkRenderPass rp, VkFramebuffer fb, uint32_t clears) {
        std::array<VkClearValue, kAttCount> values{};
        for (auto& v : values) v.color = {{0.0f, 0.0f, 0.0f, 0.0f}};
        if (rp == rp_g_) values[4].depthStencil = {1.0f, 0};
        if (rp == rp_b_) values[kDepth].depthStencil = {1.0f, 0};
        VkRenderPassBeginInfo info{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        info.renderPass = rp;
        info.framebuffer = fb;
        info.renderArea = {{0, 0}, {kSize, kSize}};
        info.clearValueCount = clears;
        info.pClearValues = values.data();
        vkCmdBeginRenderPass(cmd_, &info, VK_SUBPASS_CONTENTS_INLINE);
    }

    void Draw(VkPipeline p, VkPipelineLayout layout, VkDescriptorSet set, int mode, uint32_t instances) {
        vkCmdBindPipeline(cmd_, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
        if (set) vkCmdBindDescriptorSets(cmd_, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, nullptr);
        Push push{mode, 0};
        vkCmdPushConstants(cmd_, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), &push);
        vkCmdDraw(cmd_, 3, instances, 0, 0);
    }

    void RecordFrame(bool tile) {
        if (!tile) {
            Begin(rp_g_, fb_g_, 5);
            Draw(p_gbuf_a_, pl_gbuf_, VK_NULL_HANDLE, 0, kLayers);
            vkCmdEndRenderPass(cmd_);
            Begin(rp_l_, fb_l_, 1);
            Draw(p_light_a_, pl_light_tex_, set_light_tex_, 1, kLights);
            vkCmdEndRenderPass(cmd_);
            Begin(rp_c_, fb_c_, 1);
            Draw(p_comp_a_, pl_comp_tex_, set_comp_tex_, 2, 1);
            vkCmdEndRenderPass(cmd_);
        } else {
            Begin(rp_b_, fb_b_, kAttCount);
            Draw(p_gbuf_b_, pl_gbuf_, VK_NULL_HANDLE, 0, kLayers);
            vkCmdNextSubpass(cmd_, VK_SUBPASS_CONTENTS_INLINE);
            Draw(p_light_b_, pl_light_in_, set_light_in_, 1, kLights);
            vkCmdNextSubpass(cmd_, VK_SUBPASS_CONTENTS_INLINE);
            Draw(p_comp_b_, pl_comp_in_, set_comp_in_, 2, 1);
            vkCmdEndRenderPass(cmd_);
        }
    }

    // One command buffer of kIters frames; its times go into `s` unless it is the warm-up.
    bool RunVulkanRound(bool tile, Samples& s, bool warm) {
        const VkImage output = tile ? tile_[kOut].image : sep_[kOut].image;
        // On the heap and never freed (a few bytes per launch): the completed handler may run late.
        GpuClock& clock = *new GpuClock;
        vkResetCommandBuffer(cmd_, 0);
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (vkBeginCommandBuffer(cmd_, &begin) != VK_SUCCESS) return false;
        ClockData data{&clock};
        vkCmdEncodeMetalMVK(cmd_, &AttachClock, &data, sizeof(data));
        if (queries_) {
            vkCmdResetQueryPool(cmd_, queries_, 0, 2);
            vkCmdWriteTimestamp(cmd_, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, queries_, 0);
        }
        for (uint32_t i = 0; i < kIters; ++i) RecordFrame(tile);
        if (queries_) vkCmdWriteTimestamp(cmd_, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, queries_, 1);
        std::array<VkBufferImageCopy, kPixels.size()> copies{};
        for (size_t i = 0; i < kPixels.size(); ++i) {
            copies[i].bufferOffset = 4 * i;
            copies[i].imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
            copies[i].imageOffset = {static_cast<int32_t>(kPixels[i][0]), static_cast<int32_t>(kPixels[i][1]), 0};
            copies[i].imageExtent = {1, 1, 1};
        }
        vkCmdCopyImageToBuffer(cmd_, output, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback_, static_cast<uint32_t>(copies.size()), copies.data());
        if (vkEndCommandBuffer(cmd_) != VK_SUCCESS) return false;
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd_;
        vkResetFences(d_, 1, &fence_);
        const auto t0 = std::chrono::steady_clock::now();
        if (vkQueueSubmit(c_.queue, 1, &submit, fence_) != VK_SUCCESS) return false;
        if (vkWaitForFences(d_, 1, &fence_, VK_TRUE, 5'000'000'000ull) != VK_SUCCESS) {
            LogError("tbdr: {} timed out", tile ? "B" : "A");
            return false;
        }
        const double wall_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        for (int spin = 0; spin < 200 && clock.seconds.load() < 0.0; ++spin) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        uint64_t ticks[2]{};
        // MoltenVK marks the queries available in its own completion handler: retry briefly, never block.
        VkResult got = VK_NOT_READY;
        for (int tries = 0; queries_ && tries < 50; ++tries) {
            got = vkGetQueryPoolResults(d_, queries_, 0, 2, sizeof(ticks), ticks, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT);
            if (got != VK_NOT_READY) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        const bool stamped = got == VK_SUCCESS && ticks[1] > ticks[0];
        void* mapped = nullptr;
        if (vkMapMemory(d_, readback_memory_, 0, VK_WHOLE_SIZE, 0, &mapped) == VK_SUCCESS) {
            std::memcpy(s.px.data(), mapped, sizeof(uint32_t) * s.px.size());
            vkUnmapMemory(d_, readback_memory_);
        }
        if (warm) return true;
        s.wall.push_back(wall_ms / kIters);
        if (clock.seconds.load() > 0.0) s.gpu.push_back(clock.seconds.load() * 1000.0 / kIters);
        if (stamped) s.stamp.push_back(static_cast<double>(ticks[1] - ticks[0]) * c_.properties.limits.timestampPeriod / 1e6 / kIters);
        return true;
    }

    // ---------------------------------------------------------------- Metal
    bool SetupMetal() {
        NSError* error = nil;
        id<MTLLibrary> lib = [mtl_device_ newLibraryWithSource:[NSString stringWithUTF8String:kMetalSource] options:[MTLCompileOptions new]
                                                         error:&error];
        if (!lib) {
            LogError("tbdr: Metal shaders: {}", error ? error.localizedDescription.UTF8String : "unknown error");
            return false;
        }
        id<MTLFunction> vs = [lib newFunctionWithName:@"probe_vs"];
        // One encoder: every pipeline sees all six colour attachments; each writes only its own.
        auto tile_pipeline = [&](NSString* frag, uint32_t write_mask_of, bool additive) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = vs;
            d.fragmentFunction = [lib newFunctionWithName:frag];
            for (uint32_t i = 0; i < kOut + 1; ++i) {
                d.colorAttachments[i].pixelFormat = kMtlFormats[i];
                d.colorAttachments[i].writeMask = (write_mask_of & (1u << i)) ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
            }
            if (additive) {
                d.colorAttachments[kLight].blendingEnabled = YES;
                d.colorAttachments[kLight].sourceRGBBlendFactor = d.colorAttachments[kLight].destinationRGBBlendFactor = MTLBlendFactorOne;
                d.colorAttachments[kLight].sourceAlphaBlendFactor = d.colorAttachments[kLight].destinationAlphaBlendFactor = MTLBlendFactorOne;
            }
            d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            NSError* e = nil;
            id<MTLRenderPipelineState> p = [mtl_device_ newRenderPipelineStateWithDescriptor:d error:&e];
            if (!p) LogError("tbdr: Metal pipeline {}: {}", frag.UTF8String, e ? e.localizedDescription.UTF8String : "unknown error");
            return p;
        };
        // Separate encoders: each pass with only its own attachments.
        auto sep_pipeline = [&](NSString* frag, std::vector<Att> colours, bool additive, bool depth) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = vs;
            d.fragmentFunction = [lib newFunctionWithName:frag];
            for (size_t i = 0; i < colours.size(); ++i) {
                d.colorAttachments[i].pixelFormat = kMtlFormats[colours[i]];
                if (additive) {
                    d.colorAttachments[i].blendingEnabled = YES;
                    d.colorAttachments[i].sourceRGBBlendFactor = d.colorAttachments[i].destinationRGBBlendFactor = MTLBlendFactorOne;
                    d.colorAttachments[i].sourceAlphaBlendFactor = d.colorAttachments[i].destinationAlphaBlendFactor = MTLBlendFactorOne;
                }
            }
            if (depth) d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            NSError* e = nil;
            id<MTLRenderPipelineState> p = [mtl_device_ newRenderPipelineStateWithDescriptor:d error:&e];
            if (!p) LogError("tbdr: Metal pipeline {}: {}", frag.UTF8String, e ? e.localizedDescription.UTF8String : "unknown error");
            return p;
        };
        m_gbuf_tile_ = tile_pipeline(@"probe_gbuf", 0xF, false);
        m_light_tile_ = tile_pipeline(@"probe_light_tile", 1u << kLight, true);
        m_comp_tile_ = tile_pipeline(@"probe_comp_tile", 1u << kOut, false);
        m_gbuf_sep_ = sep_pipeline(@"probe_gbuf", {kAlbedo, kNormal, kMaterial, kDepthCol}, false, true);
        m_light_sep_ = sep_pipeline(@"probe_light_tex", {kLight}, true, false);
        m_comp_sep_ = sep_pipeline(@"probe_comp_tex", {kOut}, false, false);
        if (!m_gbuf_tile_ || !m_light_tile_ || !m_comp_tile_ || !m_gbuf_sep_ || !m_light_sep_ || !m_comp_sep_) return false;
        MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionLess;
        dd.depthWriteEnabled = YES;
        m_depth_on_ = [mtl_device_ newDepthStencilStateWithDescriptor:dd];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = NO;
        m_depth_off_ = [mtl_device_ newDepthStencilStateWithDescriptor:dd];
        for (uint32_t i = 0; i < kAttCount; ++i) {
            MTLTextureDescriptor* t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kMtlFormats[i] width:kSize height:kSize mipmapped:NO];
            t.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            t.storageMode = MTLStorageModePrivate;
            m_sep_[i] = [mtl_device_ newTextureWithDescriptor:t];
            t.usage = MTLTextureUsageRenderTarget;
            t.storageMode = i == kOut ? MTLStorageModePrivate : MTLStorageModeMemoryless;
            m_tile_[i] = [mtl_device_ newTextureWithDescriptor:t];
            if (!m_sep_[i] || !m_tile_[i]) {
                LogError("tbdr: cannot make Metal texture {}", i);
                return false;
            }
        }
        m_readback_ = [mtl_device_ newBufferWithLength:4 * kPixels.size() options:MTLResourceStorageModeShared];
        return m_readback_ != nil;
    }

    MTLRenderPassDescriptor* Pass(std::vector<std::pair<uint32_t, id<MTLTexture>>> colours, id<MTLTexture> depth, bool store_colours) {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        for (auto& [slot, tex] : colours) {
            rp.colorAttachments[slot].texture = tex;
            const bool is_out = tex == m_sep_[kOut] || tex == m_tile_[kOut];  // as Vulkan: not loaded, every pixel drawn
            rp.colorAttachments[slot].loadAction = is_out ? MTLLoadActionDontCare : MTLLoadActionClear;
            rp.colorAttachments[slot].clearColor = MTLClearColorMake(0, 0, 0, 0);
            const bool output = tex.storageMode != MTLStorageModeMemoryless && (store_colours || tex == m_tile_[kOut]);
            rp.colorAttachments[slot].storeAction = output ? MTLStoreActionStore : MTLStoreActionDontCare;
        }
        if (depth) {
            rp.depthAttachment.texture = depth;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = 1.0;
            rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        }
        return rp;
    }

    void MetalDraw(id<MTLRenderCommandEncoder> e, id<MTLRenderPipelineState> p, int mode, uint32_t instances) {
        [e setRenderPipelineState:p];
        const int32_t push[2] = {mode, 0};
        [e setVertexBytes:push length:sizeof(push) atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:instances];
    }

    void MetalFrame(id<MTLCommandBuffer> cb, bool tile) {
        if (tile) {
            std::vector<std::pair<uint32_t, id<MTLTexture>>> all;
            for (uint32_t i = 0; i <= kOut; ++i) all.push_back({i, m_tile_[i]});
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:Pass(all, m_tile_[kDepth], false)];
            [e setDepthStencilState:m_depth_on_];
            MetalDraw(e, m_gbuf_tile_, 0, kLayers);
            [e setDepthStencilState:m_depth_off_];
            MetalDraw(e, m_light_tile_, 1, kLights);
            MetalDraw(e, m_comp_tile_, 2, 1);
            [e endEncoding];
            return;
        }
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:Pass({{0, m_sep_[kAlbedo]}, {1, m_sep_[kNormal]}, {2, m_sep_[kMaterial]},
                                                                                     {3, m_sep_[kDepthCol]}},
                                                                                    m_sep_[kDepth], true)];
        [e setDepthStencilState:m_depth_on_];
        MetalDraw(e, m_gbuf_sep_, 0, kLayers);
        [e endEncoding];
        e = [cb renderCommandEncoderWithDescriptor:Pass({{0, m_sep_[kLight]}}, nil, true)];
        [e setDepthStencilState:m_depth_off_];
        for (uint32_t i = 0; i < 4; ++i) [e setFragmentTexture:m_sep_[i] atIndex:i];
        MetalDraw(e, m_light_sep_, 1, kLights);
        [e endEncoding];
        e = [cb renderCommandEncoderWithDescriptor:Pass({{0, m_sep_[kOut]}}, nil, true)];
        [e setDepthStencilState:m_depth_off_];
        [e setFragmentTexture:m_sep_[kAlbedo] atIndex:0];
        [e setFragmentTexture:m_sep_[kLight] atIndex:1];
        MetalDraw(e, m_comp_sep_, 2, 1);
        [e endEncoding];
    }

    bool RunMetalRound(bool tile, Samples& s, bool warm) {
        id<MTLCommandBuffer> cb = [mtl_queue_ commandBuffer];
        for (uint32_t i = 0; i < kIters; ++i) MetalFrame(cb, tile);
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        id<MTLTexture> output = tile ? m_tile_[kOut] : m_sep_[kOut];
        for (size_t i = 0; i < kPixels.size(); ++i)
            [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(kPixels[i][0], kPixels[i][1], 0)
                       sourceSize:MTLSizeMake(1, 1, 1) toBuffer:m_readback_ destinationOffset:4 * i destinationBytesPerRow:4
            destinationBytesPerImage:4];
        [blit endEncoding];
        const auto t0 = std::chrono::steady_clock::now();
        [cb commit];
        [cb waitUntilCompleted];
        const double wall_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (cb.status != MTLCommandBufferStatusCompleted) {
            LogError("tbdr: Metal {} failed: {}", tile ? "M2" : "M1", cb.error ? cb.error.localizedDescription.UTF8String : "unknown error");
            return false;
        }
        std::memcpy(s.px.data(), m_readback_.contents, sizeof(uint32_t) * s.px.size());
        if (warm) return true;
        s.wall.push_back(wall_ms / kIters);
        if (cb.GPUEndTime > cb.GPUStartTime) s.gpu.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / kIters);
        return true;
    }

    void Destroy() {
        if (d_) vkDeviceWaitIdle(d_);
        for (VkPipeline p : pipelines_) vkDestroyPipeline(d_, p, nullptr);
        for (VkPipelineLayout l : pipeline_layouts_) vkDestroyPipelineLayout(d_, l, nullptr);
        for (VkDescriptorSetLayout l : set_layouts_) vkDestroyDescriptorSetLayout(d_, l, nullptr);
        for (VkFramebuffer f : framebuffers_) vkDestroyFramebuffer(d_, f, nullptr);
        for (VkRenderPass r : render_passes_) vkDestroyRenderPass(d_, r, nullptr);
        for (VkShaderModule m : modules_) vkDestroyShaderModule(d_, m, nullptr);
        if (descriptor_pool_) vkDestroyDescriptorPool(d_, descriptor_pool_, nullptr);
        if (sampler_) vkDestroySampler(d_, sampler_, nullptr);
        if (queries_) vkDestroyQueryPool(d_, queries_, nullptr);
        if (fence_) vkDestroyFence(d_, fence_, nullptr);
        if (command_pool_) vkDestroyCommandPool(d_, command_pool_, nullptr);
        if (readback_) vkDestroyBuffer(d_, readback_, nullptr);
        if (readback_memory_) vkFreeMemory(d_, readback_memory_, nullptr);
        for (Img* set : {sep_.data(), tile_.data()}) {
            for (uint32_t i = 0; i < kAttCount; ++i) {
                if (set[i].view) vkDestroyImageView(d_, set[i].view, nullptr);
                if (set[i].image) vkDestroyImage(d_, set[i].image, nullptr);
                if (set[i].memory) vkFreeMemory(d_, set[i].memory, nullptr);
            }
        }
    }

    vk::Context& c_;
    VkDevice d_;
    id<MTLDevice> mtl_device_;
    id<MTLCommandQueue> mtl_queue_;
    bool lazy_warned_ = false;

    std::array<Img, kAttCount> sep_{};
    std::array<Img, kAttCount> tile_{};
    VkShaderModule vert_ = VK_NULL_HANDLE;
    VkShaderModule frag_gbuf_ = VK_NULL_HANDLE, frag_light_tex_ = VK_NULL_HANDLE, frag_light_in_ = VK_NULL_HANDLE, frag_comp_tex_ = VK_NULL_HANDLE,
                   frag_comp_in_ = VK_NULL_HANDLE;
    std::vector<VkShaderModule> modules_;
    std::vector<VkRenderPass> render_passes_;
    std::vector<VkFramebuffer> framebuffers_;
    std::vector<VkDescriptorSetLayout> set_layouts_;
    std::vector<VkPipelineLayout> pipeline_layouts_;
    std::vector<VkPipeline> pipelines_;
    VkRenderPass rp_g_ = VK_NULL_HANDLE, rp_l_ = VK_NULL_HANDLE, rp_c_ = VK_NULL_HANDLE, rp_b_ = VK_NULL_HANDLE;
    VkFramebuffer fb_g_ = VK_NULL_HANDLE, fb_l_ = VK_NULL_HANDLE, fb_c_ = VK_NULL_HANDLE, fb_b_ = VK_NULL_HANDLE;
    VkSampler sampler_ = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool_ = VK_NULL_HANDLE;
    VkDescriptorSet set_light_tex_ = VK_NULL_HANDLE, set_comp_tex_ = VK_NULL_HANDLE, set_light_in_ = VK_NULL_HANDLE, set_comp_in_ = VK_NULL_HANDLE;
    VkPipelineLayout pl_gbuf_ = VK_NULL_HANDLE, pl_light_tex_ = VK_NULL_HANDLE, pl_comp_tex_ = VK_NULL_HANDLE, pl_light_in_ = VK_NULL_HANDLE,
                     pl_comp_in_ = VK_NULL_HANDLE;
    VkPipeline p_gbuf_a_ = VK_NULL_HANDLE, p_light_a_ = VK_NULL_HANDLE, p_comp_a_ = VK_NULL_HANDLE, p_gbuf_b_ = VK_NULL_HANDLE,
               p_light_b_ = VK_NULL_HANDLE, p_comp_b_ = VK_NULL_HANDLE;
    VkCommandPool command_pool_ = VK_NULL_HANDLE;
    VkCommandBuffer cmd_ = VK_NULL_HANDLE;
    VkFence fence_ = VK_NULL_HANDLE;
    VkQueryPool queries_ = VK_NULL_HANDLE;
    VkBuffer readback_ = VK_NULL_HANDLE;
    VkDeviceMemory readback_memory_ = VK_NULL_HANDLE;

    id<MTLRenderPipelineState> m_gbuf_tile_, m_light_tile_, m_comp_tile_, m_gbuf_sep_, m_light_sep_, m_comp_sep_;
    id<MTLDepthStencilState> m_depth_on_, m_depth_off_;
    std::array<id<MTLTexture>, kAttCount> m_sep_{};
    std::array<id<MTLTexture>, kAttCount> m_tile_{};
    id<MTLBuffer> m_readback_;
};

}  // namespace

// Called once from Host::StartSession (game thread, the queue is ours; the keeper shows frames).
void RunTbdrProbe(vk::Context& ctx, id<MTLDevice> device, id<MTLCommandQueue> queue) {
    if (const char* env = std::getenv("PT_VP_TBDR_PROBE"); env && env[0] == '0') return;
    @autoreleasepool {
        const auto t0 = std::chrono::steady_clock::now();
        {
            Probe probe(ctx, device, queue);
            probe.Run();
        }
        LogInfo("tbdr: probe done in {:.1f} s", std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
    }
}

}  // namespace pt::visionos
