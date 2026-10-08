// SPDX-License-Identifier: MIT
//
// The headset of an Apple Vision Pro, as far as the game's VR mode is concerned.
//
// engine/xr/xr_host.h is the game's view of an OpenXR runtime: wait for a frame, locate the
// eyes, draw into swapchain images, hand back layers. visionOS has no OpenXR, so this file is
// that same class on top of what visionOS offers instead:
//   - Compositor Services (cp_layer_renderer) paces the frames and gives the drawables that are
//     shown in the headset;
//   - ARKit's world tracking gives the device anchor (where the head is at the moment a frame
//     will be shown);
//   - the app (Swift) gives the controller through pt_visionos.h.
// The game draws, through MoltenVK, into images this host creates itself. Those images are
// Metal textures as well (VK_EXT_metal_objects), so at the end of the frame one Metal pass of
// our own composes them (the two eyes, the HUD quad and the virtual screen quad) into the
// drawable's textures and presents it. That pass is committed on the very Metal command queue
// MoltenVK uses, so it runs after the game's rendering without any CPU wait.

#include "engine/xr/xr_host.h"

#include <glm/gtc/matrix_transform.hpp>

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <format>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "engine/core/log.h"
#include "engine/platform/settings.h"
#include "pt_visionos.h"
#include "pt_visionos_settings.h"

namespace pt::xr {

namespace {

// ---------------------------------------------------------------------------------------------
// What the app hands us and what we hand back (pt_visionos.h).

// A look and pinch (or a direct touch) from the app: where the selection ray points.
struct SpatialTouch {
    int phase = 0;  // 0 began or moved, 1 ended, 2 cancelled
    glm::vec3 origin{0.0f};
    glm::vec3 direction{0.0f, 0.0f, -1.0f};
};

struct Bridge {
    std::mutex mutex;
    cp_layer_renderer_t layer = nil;
    pt_vp_controller controller{};
    void (*haptics)(int, float, float) = nullptr;
    void (*setting_changed)(const char*, const char*) = nullptr;
    std::vector<SpatialTouch> touches;
    pt_vp_hand hands[2]{};
    std::atomic<bool> running{false};
    std::atomic<bool> quit{false};
    std::atomic<bool> foreground{true};
    pt_vp_stats stats{};
    std::string log_path;
    bool started = false;
};

Bridge& bridge() {
    static Bridge* const b = new Bridge;
    return *b;
}

simd_float4x4 Inverse(const simd_float4x4& m) { return simd_inverse(m); }

glm::quat QuatOf(const simd_float4x4& m) {
    glm::mat3 r;
    for (int c = 0; c < 3; ++c) {
        for (int k = 0; k < 3; ++k) r[c][k] = m.columns[c][k];
    }
    // Strip any scale.
    for (int c = 0; c < 3; ++c) r[c] = glm::normalize(r[c]);
    return glm::normalize(glm::quat_cast(r));
}

glm::vec3 PositionOf(const simd_float4x4& m) { return {m.columns[3][0], m.columns[3][1], m.columns[3][2]}; }

// Where a ray meets a panel (a quad of size `size` metres, facing +Z in its own frame), as 0..1
// across it, left to right and top to bottom like its texture.
bool PanelHit(const glm::vec3& origin, const glm::vec3& direction, const glm::quat& rotation, const glm::vec3& centre,
              const glm::vec2& size, glm::vec2& uv, float* distance = nullptr) {
    const glm::vec3 normal = rotation * glm::vec3(0.0f, 0.0f, 1.0f);
    const float facing = glm::dot(direction, normal);
    if (std::fabs(facing) < 1.0e-4f) return false;
    const float t = glm::dot(centre - origin, normal) / facing;
    if (t <= 0.0f) return false;
    if (distance) *distance = t;
    const glm::vec3 local = glm::inverse(rotation) * (origin + direction * t - centre);
    uv = glm::vec2(local.x / size.x + 0.5f, 0.5f - local.y / size.y);
    return uv.x >= 0.0f && uv.x <= 1.0f && uv.y >= 0.0f && uv.y <= 1.0f;
}

simd_float4x4 ModelMatrix(const glm::quat& orientation, const glm::vec3& position, const glm::vec2& size) {
    const glm::mat4 m = glm::translate(glm::mat4(1.0f), position) * glm::mat4_cast(orientation) * glm::scale(glm::mat4(1.0f), glm::vec3(size.x, size.y, 1.0f));
    simd_float4x4 out;
    for (int c = 0; c < 4; ++c) out.columns[c] = simd_make_float4(m[c][0], m[c][1], m[c][2], m[c][3]);
    return out;
}

const char* kCompositeShader = R"(
#include <metal_stdlib>
using namespace metal;
struct Uniforms {
    float4x4 mvp;
    float4 rect;     // eye: the part of the image shown; laser: the eye's position (xyz)
    float alpha;
    float opaque;
    float2 pad;
    float4 cursor;   // on a panel: u, v, width / height, 0 none | 1 aiming | 2 pinching
    float4 p0;       // laser: start (xyz), half width (w)
    float4 p1;       // laser: end (xyz)
    float4 color;    // laser
};
struct Varyings { float4 position [[position]]; float2 uv; };
// A full-view triangle: the eye image covers the whole view.
vertex Varyings eye_vertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2((id == 1) ? 3.0 : -1.0, (id == 2) ? 3.0 : -1.0);
    Varyings v;
    v.position = float4(p, 0.0, 1.0);
    float2 uv = p * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    v.uv = u.rect.xy + uv * u.rect.zw;
    return v;
}
// A quad in the world (the HUD, the virtual screen): size is in the model matrix.
vertex Varyings quad_vertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
    float2 c = corners[id];
    Varyings v;
    v.position = u.mvp * float4(c, 0.0, 1.0);
    v.uv = float2(c.x + 0.5, 0.5 - c.y);
    return v;
}
fragment float4 composite_fragment(Varyings in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);
    c.a = mix(c.a, 1.0, u.opaque) * u.alpha;
    float3 rgb = c.rgb * c.a;
    float a = c.a;
    if (u.cursor.w > 0.0) {
        // The hand's cursor: a ring (filled while pinching), dark edged so it shows on any colour.
        float2 d = (in.uv - u.cursor.xy) * float2(u.cursor.z, 1.0);
        float r = length(d);
        float pinch = step(1.5, u.cursor.w);
        float outer = 1.0 - smoothstep(0.0105, 0.0125, r);
        float ring = mix(outer * smoothstep(0.0065, 0.0085, r), outer, pinch);
        float edge = (1.0 - smoothstep(0.0128, 0.0150, r)) * (1.0 - ring);
        rgb = mix(rgb, float3(0.0), edge * 0.6);
        a = max(a, edge * 0.6);
        rgb = mix(rgb, float3(0.95), ring);
        a = max(a, ring);
    }
    return float4(rgb, a);
}
// A laser from the hand: a thin strip from p0 to p1 that faces the eye.
vertex Varyings laser_vertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float3 a = u.p0.xyz;
    float3 b = u.p1.xyz;
    float3 end = (id >> 1) != 0 ? b : a;
    float3 side = normalize(cross(b - a, end - u.rect.xyz));
    float3 p = end + side * u.p0.w * ((id & 1) != 0 ? 1.0 : -1.0);
    Varyings v;
    v.position = u.mvp * float4(p, 1.0);
    v.uv = float2((id >> 1) != 0 ? 1.0 : 0.0, 0.0);
    return v;
}
fragment float4 laser_fragment(Varyings in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    // Fades in from the hand.
    float a = u.color.a * smoothstep(0.0, 0.15, in.uv.x);
    return float4(u.color.rgb * a, a);
}
)";

struct Uniforms {
    simd_float4x4 mvp;
    simd_float4 rect;
    float alpha;
    float opaque;
    float pad[2];
    simd_float4 cursor;
    simd_float4 p0;
    simd_float4 p1;
    simd_float4 color;
};

PFN_vkExportMetalObjectsEXT ExportMetalObjects(VkDevice device) {
    return reinterpret_cast<PFN_vkExportMetalObjectsEXT>(vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT"));
}

}  // namespace

bool Available() { return true; }

static void RepeatLastFrame(Host& host, Host::Impl& x);

// ---------------------------------------------------------------------------------------------

struct Host::Impl {
    vk::Context* ctx = nullptr;
    cp_layer_renderer_t layer = nil;
    cp_layer_renderer_configuration_t configuration = nil;
    cp_layer_renderer_layout layout = cp_layer_renderer_layout_dedicated;
    bool foveated = false;
    ar_session_t ar_session = nil;
    ar_world_tracking_provider_t world_tracking = nil;
    ar_device_anchor_t anchor = nil;

    // Metal: the queue MoltenVK submits to (so our pass is ordered after the game's work).
    id<MTLDevice> mtl_device = nil;
    id<MTLCommandQueue> mtl_queue = nil;
    id<MTLRenderPipelineState> eye_pipeline = nil;
    id<MTLRenderPipelineState> quad_pipeline = nil;
    id<MTLRenderPipelineState> laser_pipeline = nil;
    id<MTLDepthStencilState> depth_write = nil;
    std::vector<id<MTLTexture>> textures[4];  // per swapchain: eye 0, eye 1, HUD, screen

    // The frame in flight.
    cp_frame_t frame = nil;
    cp_drawable_t drawable = nil;
    bool submitting = false;
    simd_float4x4 origin_from_device = matrix_identity_float4x4;
    bool anchor_valid = false;
    bool running = false;
    bool exit_requested = false;
    bool was_focused = false;
    bool focus_lost_edge = false;
    std::chrono::steady_clock::time_point last_stats;
    uint64_t stats_frames = 0;
    double loop_ms = 0.0;
    std::chrono::steady_clock::time_point frame_start;
    float snap_turn_haptic = 0.0f;

    // The panel the UI was last shown on (the HUD, else the virtual screen), for pointing at it.
    bool panel_shown = false;
    glm::quat panel_rotation{1.0f, 0.0f, 0.0f, 0.0f};
    glm::vec3 panel_centre{0.0f};
    glm::vec2 panel_size{1.0f};
    // A look and pinch in progress, and a click to hand to the game.
    bool touch_down = false;
    bool touch_hit = false;
    glm::vec2 touch_uv{0.0f};
    bool click_pending = false;
    glm::vec2 click_uv{0.0f};

    // Pointing with the hands (hand tracking): a ray from each tracked hand while a menu is open,
    // a pinch of thumb and index finger clicks where it points.
    struct HandRay {
        bool active = false;
        bool hit = false;
        bool pinched = false;
        bool smoothed = false;
        glm::vec3 origin{0.0f};
        glm::vec3 direction{0.0f, 0.0f, -1.0f};
        glm::vec3 end{0.0f};
        glm::vec2 uv{0.0f};
    };
    HandRay rays[2];
    bool pointer_wanted = false;
    int primary_hand = 1;

    // 45 frames a second: every other display frame shows the previous picture again, at the head
    // pose it was drawn for, and the compositor reprojects it to where the head is by then.
    int divisor = 1;
    bool repeat_next = false;
    bool have_last = false;
    FrameLayers last_layers;
    ar_device_anchor_t last_anchor = nil;
    simd_float4x4 last_origin_from_device = matrix_identity_float4x4;

    uint32_t eye_width = 0;
    uint32_t eye_height = 0;
    float scale = 1.0f;
    uint32_t next_image[4] = {0, 0, 0, 0};

    bool CreateImages(vk::Context& c, VkFormat format, uint32_t width, uint32_t height, uint32_t count, Swapchain& out,
                      std::vector<id<MTLTexture>>& textures, const char* name) {
        out.format = format;
        out.extent = {width, height};
        for (uint32_t i = 0; i < count; ++i) {
            VkExportMetalObjectCreateInfoEXT export_info{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT};
            export_info.exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT;
            VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
            info.pNext = &export_info;
            info.imageType = VK_IMAGE_TYPE_2D;
            info.format = format;
            info.extent = {width, height, 1};
            info.mipLevels = 1;
            info.arrayLayers = 1;
            info.samples = VK_SAMPLE_COUNT_1_BIT;
            info.tiling = VK_IMAGE_TILING_OPTIMAL;
            info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
            info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            VkImage image = VK_NULL_HANDLE;
            if (vkCreateImage(c.device, &info, nullptr, &image) != VK_SUCCESS) {
                LogError("vr: cannot create the {} image {}", name, i);
                return false;
            }
            VkMemoryRequirements req{};
            vkGetImageMemoryRequirements(c.device, image, &req);
            VkPhysicalDeviceMemoryProperties props{};
            vkGetPhysicalDeviceMemoryProperties(c.physical, &props);
            uint32_t type = props.memoryTypeCount;
            for (uint32_t t = 0; t < props.memoryTypeCount; ++t) {
                if ((req.memoryTypeBits & (1u << t)) && (props.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                    type = t;
                    break;
                }
            }
            if (type == props.memoryTypeCount) {
                LogError("vr: no device-local memory for the {} image", name);
                return false;
            }
            VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
            alloc.allocationSize = req.size;
            alloc.memoryTypeIndex = type;
            VkDeviceMemory memory = VK_NULL_HANDLE;
            if (vkAllocateMemory(c.device, &alloc, nullptr, &memory) != VK_SUCCESS || vkBindImageMemory(c.device, image, memory, 0) != VK_SUCCESS) {
                LogError("vr: cannot allocate the {} image {}", name, i);
                return false;
            }
            VkImageViewCreateInfo view_info{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
            view_info.image = image;
            view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = format;
            view_info.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
            VkImageView view = VK_NULL_HANDLE;
            vkCreateImageView(c.device, &view_info, nullptr, &view);
            VkExportMetalTextureInfoEXT texture_info{VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT};
            texture_info.image = image;
            texture_info.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
            VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
            objects.pNext = &texture_info;
            if (PFN_vkExportMetalObjectsEXT fn = ExportMetalObjects(c.device)) fn(c.device, &objects);
            if (texture_info.mtlTexture == nil) {
                LogError("vr: MoltenVK gave no Metal texture for the {} image", name);
                return false;
            }
            out.images.push_back(image);
            out.views.push_back(view);
            textures.push_back(texture_info.mtlTexture);
        }
        LogInfo("vr: {} images {}x{}, format {}, {} of them", name, width, height, static_cast<int>(format), count);
        return true;
    }

    bool InitMetal(vk::Context& c) {
        VkExportMetalDeviceInfoEXT device_info{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
        VkExportMetalCommandQueueInfoEXT queue_info{VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT};
        queue_info.queue = c.queue;
        device_info.pNext = &queue_info;
        VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
        objects.pNext = &device_info;
        PFN_vkExportMetalObjectsEXT fn = ExportMetalObjects(c.device);
        if (!fn) {
            LogError("vr: MoltenVK has no vkExportMetalObjectsEXT (VK_EXT_metal_objects)");
            return false;
        }
        fn(c.device, &objects);
        mtl_device = device_info.mtlDevice;
        mtl_queue = queue_info.mtlCommandQueue;
        if (!mtl_device || !mtl_queue) {
            LogError("vr: MoltenVK gave no Metal device or command queue");
            return false;
        }
        NSError* error = nil;
        MTLCompileOptions* options = [MTLCompileOptions new];
        id<MTLLibrary> library = [mtl_device newLibraryWithSource:[NSString stringWithUTF8String:kCompositeShader] options:options error:&error];
        if (!library) {
            LogError("vr: composite shader: {}", error ? error.localizedDescription.UTF8String : "unknown error");
            return false;
        }
        const MTLPixelFormat color = cp_layer_renderer_configuration_get_color_format(configuration);
        const MTLPixelFormat depth = cp_layer_renderer_configuration_get_depth_format(configuration);
        auto make = [&](NSString* vertex, bool blend, NSString* fragment = @"composite_fragment") -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:vertex];
            d.fragmentFunction = [library newFunctionWithName:fragment];
            d.colorAttachments[0].pixelFormat = color;
            d.colorAttachments[0].blendingEnabled = blend;
            d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            d.depthAttachmentPixelFormat = depth;
            id<MTLRenderPipelineState> p = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
            if (!p) LogError("vr: pipeline {}: {}", vertex.UTF8String, error ? error.localizedDescription.UTF8String : "unknown error");
            return p;
        };
        eye_pipeline = make(@"eye_vertex", false);
        quad_pipeline = make(@"quad_vertex", true);
        laser_pipeline = make(@"laser_vertex", true, @"laser_fragment");
        MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
        ds.depthWriteEnabled = NO;
        ds.depthCompareFunction = MTLCompareFunctionAlways;
        depth_write = [mtl_device newDepthStencilStateWithDescriptor:ds];
        return eye_pipeline && quad_pipeline && laser_pipeline;
    }

    void PublishStats(uint32_t width, uint32_t height, const char* phase) {
        Bridge& b = bridge();
        const auto now = std::chrono::steady_clock::now();
        ++stats_frames;
        const double elapsed = std::chrono::duration<double>(now - last_stats).count();
        std::lock_guard<std::mutex> lock(b.mutex);
        b.stats.eye_width = width;
        b.stats.eye_height = height;
        b.stats.phase = phase;
        b.stats.frames += 1;
        b.stats.frame_ms = loop_ms;
        if (elapsed >= 1.0) {
            b.stats.fps = stats_frames / elapsed;
            stats_frames = 0;
            last_stats = now;
        }
    }
};

Host::Host() : impl_(std::make_unique<Impl>()) {}
Host::~Host() { Shutdown(); }

bool Host::Ready() const { return impl_->layer != nil; }

bool Host::Init(const std::string&) {
    Bridge& b = bridge();
    {
        std::lock_guard<std::mutex> lock(b.mutex);
        impl_->layer = b.layer;
    }
    if (!impl_->layer) {
        error_ = "the app gave no CompositorLayer";
        return false;
    }
    runtime_name_ = "Apple Vision Pro (Compositor Services)";
    impl_->configuration = cp_layer_renderer_get_configuration(impl_->layer);
    impl_->layout = cp_layer_renderer_configuration_get_layout(impl_->configuration);
    impl_->foveated = cp_layer_renderer_configuration_get_foveation_enabled(impl_->configuration);
    LogInfo("vr: {}: layout {}, foveation {}", runtime_name_,
            impl_->layout == cp_layer_renderer_layout_layered ? "layered" : impl_->layout == cp_layer_renderer_layout_shared ? "shared" : "dedicated",
            impl_->foveated ? "on" : "off");
    // ARKit: the head.
    impl_->ar_session = ar_session_create();
    ar_world_tracking_configuration_t config = ar_world_tracking_configuration_create();
    impl_->world_tracking = ar_world_tracking_provider_create(config);
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(impl_->world_tracking, nil);
    ar_session_run(impl_->ar_session, providers);
    impl_->anchor = ar_device_anchor_create();
    impl_->last_anchor = ar_device_anchor_create();
    return true;
}

VkResult Host::CreateInstance(const VkInstanceCreateInfo& info, VkInstance& instance) {
    // As the engine asks for it (it already adds VK_KHR_portability_enumeration when MoltenVK
    // offers it). VK_EXT_metal_objects is a device extension: CreateDevice adds it.
    return vkCreateInstance(&info, nullptr, &instance);
}

VkPhysicalDevice Host::PhysicalDevice(VkInstance instance) {
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(instance, &count, nullptr);
    if (!count) return VK_NULL_HANDLE;
    std::vector<VkPhysicalDevice> devices(count);
    vkEnumeratePhysicalDevices(instance, &count, devices.data());
    return devices[0];
}

VkResult Host::CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo& info, VkDevice& device) {
    std::vector<const char*> extensions(info.ppEnabledExtensionNames, info.ppEnabledExtensionNames + info.enabledExtensionCount);
    if (std::none_of(extensions.begin(), extensions.end(), [](const char* e) { return std::strcmp(e, "VK_EXT_metal_objects") == 0; })) {
        extensions.push_back("VK_EXT_metal_objects");
    }
    VkDeviceCreateInfo copy = info;
    copy.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
    copy.ppEnabledExtensionNames = extensions.data();
    return vkCreateDevice(physical, &copy, nullptr, &device);
}

bool Host::StartSession(vk::Context& ctx, float scale) {
    Impl& x = *impl_;
    x.ctx = &ctx;
    x.scale = std::clamp(scale, 0.5f, 2.0f);
    if (!x.InitMetal(ctx)) {
        error_ = "cannot set up the Metal composition";
        return false;
    }
    // The eye size: the drawable's, which is only known from a frame. Wait for the layer to run
    // and take one frame to read it.
    cp_layer_renderer_wait_until_running(x.layer);
    uint32_t width = 0;
    uint32_t height = 0;
    for (int attempt = 0; attempt < 30 && !width; ++attempt) {
        cp_frame_t frame = cp_layer_renderer_query_next_frame(x.layer);
        if (!frame) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        cp_frame_timing_t timing = cp_frame_predict_timing(frame);
        cp_frame_start_update(frame);
        cp_frame_end_update(frame);
        cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
        cp_frame_start_submission(frame);
        cp_drawable_t drawable = cp_frame_query_drawable(frame);
        if (drawable) {
            cp_view_t view = cp_drawable_get_view(drawable, 0);
            cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
            const MTLViewport vp = cp_view_texture_map_get_viewport(map);
            width = static_cast<uint32_t>(vp.width);
            height = static_cast<uint32_t>(vp.height);
            // Present nothing: an empty black frame.
            id<MTLCommandBuffer> cb = [x.mtl_queue commandBuffer];
            cp_drawable_encode_present(drawable, cb);
            [cb commit];
        }
        cp_frame_end_submission(frame);
    }
    if (!width || !height) {
        error_ = "Compositor Services gave no drawable";
        return false;
    }
    x.eye_width = std::max(16u, static_cast<uint32_t>(std::lround(width * x.scale)));
    x.eye_height = std::max(16u, static_cast<uint32_t>(std::lround(height * x.scale)));
    LogInfo("vr: drawable view {}x{}, eyes drawn at {}x{} (scale {:.2f})", width, height, x.eye_width, x.eye_height, x.scale);
    constexpr uint32_t kImages = 3;
    const VkFormat format = VK_FORMAT_R8G8B8A8_SRGB;
    if (!x.CreateImages(ctx, format, x.eye_width, x.eye_height, kImages, eye_swapchains_[0], x.textures[0], "left eye") ||
        !x.CreateImages(ctx, format, x.eye_width, x.eye_height, kImages, eye_swapchains_[1], x.textures[1], "right eye") ||
        !x.CreateImages(ctx, format, 1920, 1080, kImages, hud_swapchain_, x.textures[2], "HUD") ||
        !x.CreateImages(ctx, format, 1920, 1080, kImages, screen_swapchain_, x.textures[3], "virtual screen")) {
        error_ = "cannot create the eye images";
        return false;
    }
    x.running = true;
    x.divisor = pt::visionos::Headset().target_fps == 45 ? 2 : 1;
    x.last_stats = std::chrono::steady_clock::now();
    LogInfo("vr: session created");
    return true;
}

void Host::Shutdown() {
    Impl& x = *impl_;
    if (x.frame) {
        if (x.drawable) {
            id<MTLCommandBuffer> cb = [x.mtl_queue commandBuffer];
            cp_drawable_encode_present(x.drawable, cb);
            [cb commit];
        }
        if (x.submitting) cp_frame_end_submission(x.frame);
        x.submitting = false;
        x.frame = nil;
        x.drawable = nil;
        frame_open_ = false;
    }
    if (x.ctx && x.ctx->device) {
        vkDeviceWaitIdle(x.ctx->device);
        Swapchain* chains[4] = {&eye_swapchains_[0], &eye_swapchains_[1], &hud_swapchain_, &screen_swapchain_};
        for (int i = 0; i < 4; ++i) {
            for (VkImageView v : chains[i]->views) vkDestroyImageView(x.ctx->device, v, nullptr);
            for (VkImage im : chains[i]->images) vkDestroyImage(x.ctx->device, im, nullptr);
            chains[i]->views.clear();
            chains[i]->images.clear();
            x.textures[i].clear();
        }
        x.ctx = nullptr;
    }
    if (x.ar_session) {
        ar_session_stop(x.ar_session);
        x.ar_session = nil;
    }
    x.running = false;
}

void Host::PollEvents() {
    Impl& x = *impl_;
    if (!x.layer) return;
    const cp_layer_renderer_state state = cp_layer_renderer_get_state(x.layer);
    Bridge& b = bridge();
    if (state == cp_layer_renderer_state_invalidated || b.quit.load()) {
        if (!x.exit_requested) LogInfo("vr: the immersive space closed, ending");
        x.exit_requested = true;
        x.running = false;
    }
    const bool focused = state == cp_layer_renderer_state_running && b.foreground.load();
    x.focus_lost_edge = x.was_focused && !focused;
    x.was_focused = focused;
}

bool Host::SessionRunning() const { return impl_->running; }
bool Host::ExitRequested() const { return impl_->exit_requested; }
bool Host::Focused() const { return impl_->was_focused; }
bool Host::FocusLost() const { return impl_->focus_lost_edge; }
bool Host::ShouldRender() const { return should_render_; }

bool Host::WaitFrame() {
    Impl& x = *impl_;
    if (!x.running) return false;
    if (x.frame) {
        // A frame left open by a loop iteration that drew nothing.
        if (x.submitting) {
            if (x.drawable) {
                id<MTLCommandBuffer> cb = [x.mtl_queue commandBuffer];
                cp_drawable_encode_present(x.drawable, cb);
                [cb commit];
            }
            cp_frame_end_submission(x.frame);
        }
        x.frame = nil;
        x.drawable = nil;
        x.submitting = false;
    }
    const cp_layer_renderer_state state = cp_layer_renderer_get_state(x.layer);
    if (state == cp_layer_renderer_state_paused) {
        // The player looked away or the space is hidden: nothing to draw, keep the loop alive.
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        should_render_ = false;
        return false;
    }
    if (state != cp_layer_renderer_state_running) {
        should_render_ = false;
        return false;
    }
    if (x.repeat_next) RepeatLastFrame(*this, x);
    cp_frame_t frame = cp_layer_renderer_query_next_frame(x.layer);
    if (!frame) {
        should_render_ = false;
        return false;
    }
    cp_frame_timing_t timing = cp_frame_predict_timing(frame);
    cp_frame_start_update(frame);
    // (Game logic between update and submission would be the ideal; the game ticks after
    // WaitFrame, which is what OpenXR runtimes get as well.)
    cp_frame_end_update(frame);
    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
    x.frame = frame;
    x.frame_start = std::chrono::steady_clock::now();
    const cp_time_t presentation = cp_frame_timing_get_presentation_time(timing);
    const cp_time_t rendering_deadline = cp_frame_timing_get_rendering_deadline(timing);
    display_time_ = static_cast<int64_t>(cp_time_to_cf_time_interval(presentation) * 1.0e9);
    const double period = cp_time_to_cf_time_interval(rendering_deadline) - cp_time_to_cf_time_interval(cp_frame_timing_get_optimal_input_time(timing));
    if (period > 0.0) display_period_ = std::clamp(period, 1.0 / 240.0, 1.0 / 30.0);
    should_render_ = true;
    return true;
}

bool Host::BeginFrame() {
    Impl& x = *impl_;
    if (!x.frame) return false;
    cp_frame_start_submission(x.frame);
    x.submitting = true;
    x.drawable = cp_frame_query_drawable(x.frame);
    if (!x.drawable) {
        cp_frame_end_submission(x.frame);
        x.submitting = false;
        x.frame = nil;
        frame_open_ = false;
        should_render_ = false;
        return false;
    }
    cp_frame_timing_t timing = cp_drawable_get_frame_timing(x.drawable);
    const CFTimeInterval when = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(timing));
    x.anchor_valid = ar_world_tracking_provider_query_device_anchor_at_timestamp(x.world_tracking, when, x.anchor) == ar_device_anchor_query_status_success;
    if (x.anchor_valid) {
        cp_drawable_set_device_anchor(x.drawable, x.anchor);
        x.origin_from_device = ar_anchor_get_origin_from_anchor_transform(x.anchor);
    }
    frame_open_ = true;
    return true;
}

void Host::LocateViews() {
    Impl& x = *impl_;
    views_valid_ = false;
    if (!x.drawable || !x.anchor_valid) return;
    const size_t count = cp_drawable_get_view_count(x.drawable);
    if (count < 2) return;
    for (int i = 0; i < 2; ++i) {
        cp_view_t view = cp_drawable_get_view(x.drawable, i);
        const simd_float4x4 world = simd_mul(x.origin_from_device, cp_view_get_transform(view));
        const simd_float4 t = cp_view_get_tangents(view);  // left, right, top, bottom, positive
        eyes_[i].orientation = QuatOf(world);
        eyes_[i].position = PositionOf(world);
        eyes_[i].tangents = glm::vec4(-t.x, t.y, t.z, -t.w);
        eyes_[i].angles = glm::vec4(-std::atan(t.x), std::atan(t.y), std::atan(t.z), -std::atan(t.w));
    }
    head_.orientation = QuatOf(x.origin_from_device);
    head_.position = PositionOf(x.origin_from_device);
    views_valid_ = true;
}

void Host::SyncActions() {
    Bridge& b = bridge();
    pt_vp_controller c;
    {
        std::lock_guard<std::mutex> lock(b.mutex);
        c = b.controller;
    }
    controllers_.active = c.active;
    controllers_.move = glm::vec2(c.move_x, c.move_y);
    controllers_.turn = glm::vec2(c.turn_x, c.turn_y);
    controllers_.interact = c.interact;
    controllers_.back = c.back;
    controllers_.menu = c.menu;
    controllers_.zoom = c.zoom;
    controllers_.gouge = c.gouge;
    controllers_.triangle = c.triangle;
    controllers_.settings = c.settings;
    controllers_.dpad_up = c.dpad_up;
    controllers_.dpad_down = c.dpad_down;
    controllers_.dpad_left = c.dpad_left;
    controllers_.dpad_right = c.dpad_right;
    controllers_.l1 = c.l1;
    controllers_.r1 = c.r1;
    controllers_.prompt_style = c.prompt_style;

    Impl& x = *impl_;
    std::vector<SpatialTouch> touches;
    pt_vp_hand hands[2];
    {
        std::lock_guard<std::mutex> lock(b.mutex);
        touches.swap(b.touches);
        hands[0] = b.hands[0];
        hands[1] = b.hands[1];
    }

    // Pointing with the hands: while a menu is open, a ray from each tracked hand. The ray starts
    // at the index finger's knuckle and points away from an estimated shoulder, which keeps it
    // steady while the fingers move (the way other headsets aim with hands). A pinch (thumb and
    // index tips together) clicks where it points; opening the fingers again releases it.
    bool any_ray = false;
    bool hand_click = false;
    glm::vec2 hand_click_uv{0.0f};
    const glm::vec3 forward = head_.orientation * glm::vec3(0.0f, 0.0f, -1.0f);
    const glm::vec3 flat = glm::length(glm::vec2(forward.x, forward.z)) > 1.0e-3f ? glm::normalize(glm::vec3(forward.x, 0.0f, forward.z))
                                                                                 : glm::vec3(0.0f, 0.0f, -1.0f);
    const glm::vec3 right(-flat.z, 0.0f, flat.x);
    for (int h = 0; h < 2; ++h) {
        Impl::HandRay& r = x.rays[h];
        const pt_vp_hand& hand = hands[h];
        r.active = x.pointer_wanted && x.panel_shown && views_valid_ && hand.tracked;
        if (!r.active) {
            r.hit = false;
            r.pinched = false;
            r.smoothed = false;
            continue;
        }
        any_ray = true;
        const glm::vec3 knuckle(hand.index_knuckle[0], hand.index_knuckle[1], hand.index_knuckle[2]);
        const glm::vec3 thumb(hand.thumb_tip[0], hand.thumb_tip[1], hand.thumb_tip[2]);
        const glm::vec3 index(hand.index_tip[0], hand.index_tip[1], hand.index_tip[2]);
        const glm::vec3 shoulder = head_.position + glm::vec3(0.0f, -0.20f, 0.0f) + right * (h == 0 ? -0.17f : 0.17f) - flat * 0.05f;
        glm::vec3 direction = knuckle - shoulder;
        direction = glm::length(direction) > 1.0e-3f ? glm::normalize(direction) : forward;
        r.direction = r.smoothed ? glm::normalize(glm::mix(r.direction, direction, 0.35f)) : direction;
        r.smoothed = true;
        r.origin = knuckle;
        float distance = 1.5f;
        r.hit = PanelHit(r.origin, r.direction, x.panel_rotation, x.panel_centre, x.panel_size, r.uv, &distance);
        r.end = r.origin + r.direction * (r.hit ? distance : 1.5f);
        const float gap = glm::distance(thumb, index);
        if (!r.pinched && gap < 0.015f) {
            r.pinched = true;
            if (r.hit) {
                hand_click = true;
                hand_click_uv = r.uv;
                x.primary_hand = h;
            }
        } else if (r.pinched && gap > 0.03f) {
            r.pinched = false;
        }
    }
    if (!x.pointer_wanted) {
        // No menu open: pinches are not clicks.
        touches.clear();
        x.touch_down = false;
        x.touch_hit = false;
    }
    if (any_ray) {
        // The hands point: the system's look and pinch would click a second time.
        touches.clear();
        x.touch_down = false;
        x.touch_hit = false;
        const Impl::HandRay& first = x.rays[x.primary_hand].hit ? x.rays[x.primary_hand] : x.rays[1 - x.primary_hand];
        controllers_.click = hand_click;
        controllers_.pointer_valid = hand_click || first.hit;
        controllers_.pointer = hand_click ? hand_click_uv : first.uv;
    }

    // Without tracked hands (hand tracking not allowed), the system's look and pinch: a pinch
    // that starts on the panel the UI is on and ends there is a click where it started.
    for (const SpatialTouch& t : touches) {
        if (t.phase == 0) {
            if (!x.touch_down) {
                x.touch_down = true;
                x.touch_hit = x.panel_shown && PanelHit(t.origin, t.direction, x.panel_rotation, x.panel_centre, x.panel_size, x.touch_uv);
            }
        } else {
            if (t.phase == 1 && x.touch_down && x.touch_hit) {
                x.click_pending = true;
                x.click_uv = x.touch_uv;
            }
            x.touch_down = false;
            x.touch_hit = false;
        }
    }
    if (!any_ray) {
        controllers_.click = x.click_pending;
        controllers_.pointer_valid = x.click_pending || (x.touch_down && x.touch_hit);
        controllers_.pointer = x.click_pending ? x.click_uv : x.touch_uv;
    }
    x.click_pending = false;
    for (int hand = 0; hand < 2; ++hand) {
        HandPose& p = controllers_.aim[hand];
        p.valid = c.hand_valid[hand];
        p.position = glm::vec3(c.hand_pos[hand][0], c.hand_pos[hand][1], c.hand_pos[hand][2]);
        p.orientation = glm::normalize(glm::quat(c.hand_rot[hand][3], c.hand_rot[hand][0], c.hand_rot[hand][1], c.hand_rot[hand][2]));
    }
}

bool Host::Acquire(Swapchain& swapchain) {
    if (swapchain.images.empty()) return false;
    Impl& x = *impl_;
    int which = &swapchain == &eye_swapchains_[0] ? 0 : &swapchain == &eye_swapchains_[1] ? 1 : &swapchain == &hud_swapchain_ ? 2 : 3;
    swapchain.index = x.next_image[which];
    x.next_image[which] = (x.next_image[which] + 1) % static_cast<uint32_t>(swapchain.images.size());
    swapchain.acquired = true;
    return true;
}

void Host::Release(Swapchain& swapchain) { swapchain.acquired = false; }

// One drawable's whole picture: the eye images over the views, then the virtual screen and the
// HUD as quads in the world. `origin_from_device` is the head pose the drawable is set to (the
// one the eye images were drawn for). Encoded into `cb`; the caller presents.
static void ComposeFrame(Host& host, Host::Impl& x, cp_drawable_t drawable, const FrameLayers& layers, const simd_float4x4& origin_from_device,
                         bool render, id<MTLCommandBuffer> cb) {
    const bool anything = render && (layers.projection || layers.screen || layers.hud);
    // What "far" is in the drawable's depth convention: a distant point through its projection.
    float far_depth = 0.0f;
    {
        const simd_float4x4 p = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, 0);
        const simd_float4 clip = simd_mul(p, simd_make_float4(0.0f, 0.0f, -1000.0f, 1.0f));
        if (std::fabs(clip.w) > 1.0e-6f) far_depth = std::clamp(clip.z / clip.w, 0.0f, 1.0f);
    }
    const size_t view_count = std::min<size_t>(2, cp_drawable_get_view_count(drawable));
    for (size_t v = 0; v < view_count; ++v) {
        cp_view_t view = cp_drawable_get_view(drawable, v);
        cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
        const size_t texture_index = cp_view_texture_map_get_texture_index(map);
        const size_t slice = cp_view_texture_map_get_slice_index(map);
        const MTLViewport viewport = cp_view_texture_map_get_viewport(map);
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texture_index);
        pass.colorAttachments[0].slice = slice;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, texture_index);
        if (depth) {
            pass.depthAttachment.texture = depth;
            pass.depthAttachment.slice = slice;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            // Everything distant until the game hands real depth (the compositor reprojects with it).
            pass.depthAttachment.clearDepth = far_depth;
        }
        id<MTLRasterizationRateMap> rate = cp_drawable_get_rasterization_rate_map(drawable, texture_index);
        if (rate) pass.rasterizationRateMap = rate;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        [enc setViewport:viewport];
        [enc setDepthStencilState:x.depth_write];
        if (anything) {
            Uniforms u{};
            u.mvp = matrix_identity_float4x4;
            if (layers.projection) {
                u.rect = simd_make_float4(0.0f, 0.0f, 1.0f, 1.0f);
                u.alpha = 1.0f;
                u.opaque = 1.0f;
                [enc setRenderPipelineState:x.eye_pipeline];
                [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
                [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
                [enc setFragmentTexture:x.textures[v][host.EyeSwapchain(static_cast<int>(v)).index] atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            if (layers.screen || layers.hud) {
                const simd_float4x4 projection = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, v);
                const simd_float4x4 world_from_view = simd_mul(origin_from_device, cp_view_get_transform(view));
                const simd_float4x4 view_projection = simd_mul(projection, Inverse(world_from_view));
                [enc setRenderPipelineState:x.quad_pipeline];
                // The hand's cursor goes on the panel the UI is on (the HUD, else the screen).
                const Host::Impl::HandRay* aimed = x.rays[x.primary_hand].active && x.rays[x.primary_hand].hit ? &x.rays[x.primary_hand]
                                                   : x.rays[1 - x.primary_hand].active && x.rays[1 - x.primary_hand].hit ? &x.rays[1 - x.primary_hand]
                                                                                                                        : nullptr;
                const int cursor_panel = layers.hud ? 2 : 3;
                auto quad = [&](int which, const Swapchain& sc, const glm::quat& orientation, const glm::vec3& position, const glm::vec2& size, bool alpha) {
                    Uniforms q{};
                    q.mvp = simd_mul(view_projection, ModelMatrix(orientation, position, size));
                    q.rect = simd_make_float4(0.0f, 0.0f, 1.0f, 1.0f);
                    q.alpha = 1.0f;
                    q.opaque = alpha ? 0.0f : 1.0f;
                    if (aimed && which == cursor_panel) {
                        q.cursor = simd_make_float4(aimed->uv.x, aimed->uv.y, size.x / std::max(size.y, 1.0e-3f), aimed->pinched ? 2.0f : 1.0f);
                    }
                    [enc setVertexBytes:&q length:sizeof(q) atIndex:0];
                    [enc setFragmentBytes:&q length:sizeof(q) atIndex:0];
                    [enc setFragmentTexture:x.textures[which][sc.index] atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                };
                if (layers.screen) quad(3, host.ScreenSwapchain(), layers.screen_orientation, layers.screen_position, layers.screen_size, false);
                if (layers.hud) quad(2, host.HudSwapchain(), layers.hud_orientation, layers.hud_position, layers.hud_size, true);
                // The lasers from the hands.
                [enc setRenderPipelineState:x.laser_pipeline];
                for (int h = 0; h < 2; ++h) {
                    const Host::Impl::HandRay& r = x.rays[h];
                    if (!r.active) continue;
                    Uniforms l{};
                    l.mvp = view_projection;
                    l.rect = simd_make_float4(world_from_view.columns[3][0], world_from_view.columns[3][1], world_from_view.columns[3][2], 1.0f);
                    l.p0 = simd_make_float4(r.origin.x, r.origin.y, r.origin.z, 0.0015f);
                    l.p1 = simd_make_float4(r.end.x, r.end.y, r.end.z, 0.0f);
                    l.color = r.hit ? simd_make_float4(0.95f, 0.95f, 0.95f, r.pinched ? 0.9f : 0.55f) : simd_make_float4(0.8f, 0.8f, 0.8f, 0.25f);
                    [enc setVertexBytes:&l length:sizeof(l) atIndex:0];
                    [enc setFragmentBytes:&l length:sizeof(l) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
            }
        }
        [enc endEncoding];
    }
}

void Host::EndFrame(const FrameLayers& layers) {
    Impl& x = *impl_;
    if (!frame_open_ || !x.frame) return;
    if (!x.drawable) {
        if (x.submitting) cp_frame_end_submission(x.frame);
        x.submitting = false;
        x.frame = nil;
        frame_open_ = false;
        return;
    }
    const bool anything = should_render_ && (layers.projection || layers.screen || layers.hud);
    id<MTLCommandBuffer> cb = [x.mtl_queue commandBuffer];
    cb.label = @"P.T. composite";
    ComposeFrame(*this, x, x.drawable, layers, x.origin_from_device, should_render_, cb);
    cp_drawable_encode_present(x.drawable, cb);
    [cb commit];
    cp_frame_end_submission(x.frame);
    x.submitting = false;
    x.loop_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - x.frame_start).count();
    if (anything) {
        ++frames_submitted_;
        x.PublishStats(x.eye_width, x.eye_height, layers.projection ? "stereo" : layers.screen ? "screen" : "menu");
        // The panel the UI is on, for pointing at it.
        x.panel_shown = layers.hud || layers.screen;
        if (layers.hud) {
            x.panel_rotation = layers.hud_orientation;
            x.panel_centre = layers.hud_position;
            x.panel_size = layers.hud_size;
        } else if (layers.screen) {
            x.panel_rotation = layers.screen_orientation;
            x.panel_centre = layers.screen_position;
            x.panel_size = layers.screen_size;
        }
        // Kept to be shown again on the next display frame at 45 frames a second.
        if (x.divisor > 1 && x.anchor_valid) {
            x.last_layers = layers;
            x.last_origin_from_device = x.origin_from_device;
            std::swap(x.anchor, x.last_anchor);
            x.have_last = true;
            x.repeat_next = true;
        }
    }
    x.frame = nil;
    x.drawable = nil;
    frame_open_ = false;
}

// The display frame in between at 45 frames a second: the last picture again, with the head pose
// it was drawn for, so the compositor turns it to where the head is now.
static void RepeatLastFrame(Host& host, Host::Impl& x) {
    x.repeat_next = false;
    if (!x.have_last || cp_layer_renderer_get_state(x.layer) != cp_layer_renderer_state_running) return;
    cp_frame_t frame = cp_layer_renderer_query_next_frame(x.layer);
    if (!frame) return;
    cp_frame_timing_t timing = cp_frame_predict_timing(frame);
    cp_frame_start_update(frame);
    cp_frame_end_update(frame);
    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
    cp_frame_start_submission(frame);
    cp_drawable_t drawable = cp_frame_query_drawable(frame);
    if (drawable) {
        cp_drawable_set_device_anchor(drawable, x.last_anchor);
        id<MTLCommandBuffer> cb = [x.mtl_queue commandBuffer];
        cb.label = @"P.T. repeat";
        ComposeFrame(host, x, drawable, x.last_layers, x.last_origin_from_device, true, cb);
        cp_drawable_encode_present(drawable, cb);
        [cb commit];
    }
    cp_frame_end_submission(frame);
}

void Host::SetPointerWanted(bool wanted) { impl_->pointer_wanted = wanted; }

void Host::SetFrameDivisor(int divisor) {
    Impl& x = *impl_;
    x.divisor = std::clamp(divisor, 1, 2);
    if (x.divisor == 1) x.repeat_next = false;
    LogInfo("vr: {} frames a second", x.divisor == 2 ? 45 : 90);
}

void Host::Haptic(int hand, float amplitude, float seconds) {
    Bridge& b = bridge();
    void (*cb)(int, float, float) = nullptr;
    {
        std::lock_guard<std::mutex> lock(b.mutex);
        cb = b.haptics;
    }
    if (cb) cb(hand, amplitude, seconds);
}

}  // namespace pt::xr

// ---------------------------------------------------------------------------------------------
// Settings from the app (PT_VP_* in the environment) into the game's settings.

namespace pt::visionos {

namespace {
const char* Env(const char* name) {
    const char* v = std::getenv(name);
    return v && *v ? v : nullptr;
}
bool Flag(const char* name, bool fallback) {
    const char* v = Env(name);
    return v ? v[0] != '0' : fallback;
}
float Number(const char* name, float fallback) {
    const char* v = Env(name);
    return v ? static_cast<float>(std::atof(v)) : fallback;
}

// The presets as PTSettings.swift defines them (keep both in step).
struct Preset {
    float resolution_scale;
    int shadow_quality;  // 0 off, 1 low, 2 medium, 3 high
    bool ssao;
    bool bloom;
    bool reflections;
};
constexpr Preset kPresets[2] = {
    {0.60f, 1, false, true, false},  // Vision Pro M2
    {0.85f, 2, true, true, true},    // Vision Pro M5
};

const char* ShadowName(int quality) {
    switch (quality) {
        case 0: return "off";
        case 1: return "low";
        case 2: return "medium";
        default: return "high";
    }
}

bool MatchesPreset(int preset, const AppSettings& s, const HeadsetSettings& h) {
    if (preset < 0 || preset > 1) return false;
    const Preset& p = kPresets[preset];
    return std::fabs(h.resolution_scale - p.resolution_scale) < 0.01f && h.target_fps == 90 && h.foveation &&
           s.graphics.shadow_quality == p.shadow_quality && s.graphics.ambient_occlusion == p.ssao && s.graphics.bloom == p.bloom &&
           s.graphics.reflections == p.reflections;
}
}  // namespace

HeadsetSettings& Headset() {
    static HeadsetSettings settings;
    return settings;
}

void SettingChanged(const char* key, const std::string& value) {
    pt::xr::Bridge& b = pt::xr::bridge();
    void (*cb)(const char*, const char*) = nullptr;
    {
        std::lock_guard<std::mutex> lock(b.mutex);
        cb = b.setting_changed;
    }
    LogInfo("visionos: setting {} = {} (from the game's menu)", key, value);
    if (cb) cb(key, value.c_str());
}

void GraphicsChanged(const AppSettings& s) {
    SettingChanged("shadows", ShadowName(s.graphics.shadow_quality));
    SettingChanged("ssao", s.graphics.ambient_occlusion ? "1" : "0");
    SettingChanged("bloom", s.graphics.bloom ? "1" : "0");
    SettingChanged("reflections", s.graphics.reflections ? "1" : "0");
    HeadsetSettings& h = Headset();
    if (h.preset != 2 && !MatchesPreset(h.preset, s, h)) {
        h.preset = 2;
        SettingChanged("preset", "custom");
    }
}

void ApplyPreset(int preset, AppSettings& s) {
    HeadsetSettings& h = Headset();
    h.preset = std::clamp(preset, 0, 2);
    if (h.preset == 2) {
        SettingChanged("preset", "custom");
        return;
    }
    const Preset& p = kPresets[h.preset];
    h.resolution_scale = p.resolution_scale;
    h.target_fps = 90;
    h.foveation = true;
    s.vr.resolution_scale = p.resolution_scale;
    s.graphics.shadow_quality = p.shadow_quality;
    s.graphics.ambient_occlusion = p.ssao;
    s.graphics.bloom = p.bloom;
    s.graphics.reflections = p.reflections;
    SettingChanged("preset", h.preset == 0 ? "m2" : "m5");
    SettingChanged("resolution_scale", std::format("{:.2f}", p.resolution_scale));
    SettingChanged("target_fps", "90");
    SettingChanged("foveation", "1");
    SettingChanged("shadows", ShadowName(p.shadow_quality));
    SettingChanged("ssao", p.ssao ? "1" : "0");
    SettingChanged("bloom", p.bloom ? "1" : "0");
    SettingChanged("reflections", p.reflections ? "1" : "0");
}

void ApplySettings(AppSettings& s) {
    HeadsetSettings& h = Headset();
    if (const char* preset = Env("PT_VP_PRESET")) {
        const std::string v = preset;
        h.preset = v == "m2" ? 0 : v == "m5" ? 1 : 2;
    }
    h.resolution_scale = std::clamp(Number("PT_VP_RESOLUTION_SCALE", 0.6f), 0.5f, 2.0f);
    h.target_fps = static_cast<int>(Number("PT_VP_TARGET_FPS", 90.0f)) == 45 ? 45 : 90;
    h.foveation = Flag("PT_VP_FOVEATION", true);

    s.vr.enabled = true;
    s.vr.resolution_scale = h.resolution_scale;
    s.vr.turn = static_cast<int>(Number("PT_VP_TURN", 0.0f)) == 1 ? 1 : 0;
    s.vr.snap_degrees = std::clamp(Number("PT_VP_SNAP_DEGREES", 30.0f), 10.0f, 90.0f);
    s.vr.smooth_speed = std::clamp(Number("PT_VP_SMOOTH_SPEED", 90.0f), 20.0f, 360.0f);
    const int hand = static_cast<int>(Number("PT_VP_FLASHLIGHT_HAND", -1.0f));
    s.vr.flashlight = hand >= 0 ? 1 : 0;
    s.vr.flashlight_hand = hand == 1 ? 1 : 0;
    s.display.fps_limit = 0;  // the headset paces the frames
    s.display.vsync = false;
    s.display.pause_on_focus_loss = Flag("PT_VP_PAUSE_AWAY", true);
    s.display.mute_in_background = true;
    s.network.check_updates = false;
    s.graphics.enhanced_textures = false;
    s.upscaling.upscaler = "off";
    s.upscaling.frame_generation = "off";
    if (const char* shadows = Env("PT_VP_SHADOWS")) {
        const std::string v = shadows;
        s.graphics.shadow_quality = v == "off" ? 0 : v == "low" ? 1 : v == "medium" ? 2 : 3;
    }
    s.graphics.ambient_occlusion = Flag("PT_VP_SSAO", false);
    s.graphics.bloom = Flag("PT_VP_BLOOM", true);
    s.graphics.reflections = Flag("PT_VP_REFLECTIONS", false);
    // Never in the eyes (docs/vr.md); off for the virtual screen as well.
    s.graphics.motion_blur = false;
    s.graphics.depth_of_field = false;
    s.graphics.lens_distortion = false;
    s.graphics.lens_ghosts = false;
    s.graphics.film_grain = 0.0f;
    s.display.letterbox = 0;
    s.ray_tracing = {};
    s.camera.third_person = false;
    s.extras.livesplit = false;
    LogInfo("visionos: preset {}, image {:.0f} %, {} frames a second, foveation {}, shadows {}, SSAO {}, bloom {}, reflections {}",
            h.preset == 0 ? "M2" : h.preset == 1 ? "M5" : "custom", h.resolution_scale * 100.0f, h.target_fps, h.foveation ? "on" : "off",
            ShadowName(s.graphics.shadow_quality), s.graphics.ambient_occlusion, s.graphics.bloom, s.graphics.reflections);
}

}  // namespace pt::visionos

// ---------------------------------------------------------------------------------------------
// The C API the app calls (pt_visionos.h).

// main.cpp, compiled with main renamed (-Dmain=pt_game_main); C++ linkage.
int pt_game_main(int argc, char** argv);

namespace {

std::vector<std::string> g_args;
std::vector<char*> g_argv;

void GameThread() {
    pt::xr::Bridge& b = pt::xr::bridge();
    b.running = true;
    g_argv.clear();
    for (std::string& a : g_args) g_argv.push_back(a.data());
    g_argv.push_back(nullptr);
    const int code = pt_game_main(static_cast<int>(g_argv.size() - 1), g_argv.data());
    pt::LogInfo("visionos: the game ended with code {}", code);
    b.running = false;
}

}  // namespace

extern "C" {

int pt_vp_start(void* layer_renderer, const char* const* argv, int argc, const char* const* env, int env_count) {
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    if (b.started || !layer_renderer) return 1;
    b.started = true;
    b.layer = (__bridge cp_layer_renderer_t)layer_renderer;
    for (int i = 0; i < env_count; ++i) {
        const std::string pair = env[i];
        const size_t eq = pair.find('=');
        if (eq != std::string::npos) setenv(pair.substr(0, eq).c_str(), pair.substr(eq + 1).c_str(), 1);
    }
    g_args.clear();
    g_args.emplace_back("pt");
    for (int i = 0; i < argc; ++i) g_args.emplace_back(argv[i]);
    NSArray* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (documents.count) {
        // The game's log where the launcher's Log tab reads it.
        b.log_path = std::string([documents[0] UTF8String]) + "/pt.log";
        g_args.emplace_back("--log");
        g_args.emplace_back(b.log_path);
    }
    b.running = true;  // before the thread: the app polls pt_vp_running right away
    std::thread(GameThread).detach();
    return 0;
}

void pt_vp_request_quit(void) { pt::xr::bridge().quit = true; }

bool pt_vp_running(void) { return pt::xr::bridge().running.load(); }

void pt_vp_set_controller(const pt_vp_controller* state) {
    if (!state) return;
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    b.controller = *state;
}

void pt_vp_haptics_callback(void (*cb)(int hand, float amplitude, float seconds)) {
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    b.haptics = cb;
}

void pt_vp_stats_get(pt_vp_stats* out) {
    if (!out) return;
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    *out = b.stats;
    if (!out->phase) out->phase = "loading";
}

void pt_vp_set_foreground(bool active) { pt::xr::bridge().foreground = active; }

void pt_vp_spatial_event(int phase, float ox, float oy, float oz, float dx, float dy, float dz) {
    pt::xr::Bridge& b = pt::xr::bridge();
    pt::xr::SpatialTouch t;
    t.phase = phase;
    t.origin = glm::vec3(ox, oy, oz);
    const glm::vec3 d(dx, dy, dz);
    t.direction = glm::length(d) > 1.0e-6f ? glm::normalize(d) : glm::vec3(0.0f, 0.0f, -1.0f);
    std::lock_guard<std::mutex> lock(b.mutex);
    if (b.touches.size() < 64) b.touches.push_back(t);
}

void pt_vp_set_hand(int hand, const pt_vp_hand* state) {
    if (hand < 0 || hand > 1 || !state) return;
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    b.hands[hand] = *state;
}

void pt_vp_settings_callback(void (*cb)(const char* key, const char* value)) {
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    b.setting_changed = cb;
}

const char* pt_vp_log_path(void) {
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    return b.log_path.empty() ? nullptr : b.log_path.c_str();
}

}  // extern "C"
