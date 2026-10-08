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
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "engine/core/log.h"
#include "engine/platform/settings.h"
#include "pt_visionos.h"

namespace pt::xr {

namespace {

// ---------------------------------------------------------------------------------------------
// What the app hands us and what we hand back (pt_visionos.h).

struct Bridge {
    std::mutex mutex;
    cp_layer_renderer_t layer = nil;
    pt_vp_controller controller{};
    void (*haptics)(int, float, float) = nullptr;
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

simd_float4x4 ModelMatrix(const glm::quat& orientation, const glm::vec3& position, const glm::vec2& size) {
    const glm::mat4 m = glm::translate(glm::mat4(1.0f), position) * glm::mat4_cast(orientation) * glm::scale(glm::mat4(1.0f), glm::vec3(size.x, size.y, 1.0f));
    simd_float4x4 out;
    for (int c = 0; c < 4; ++c) out.columns[c] = simd_make_float4(m[c][0], m[c][1], m[c][2], m[c][3]);
    return out;
}

const char* kCompositeShader = R"(
#include <metal_stdlib>
using namespace metal;
struct Uniforms { float4x4 mvp; float4 rect; float alpha; float opaque; float2 pad; };
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
    return float4(c.rgb * c.a, c.a);
}
)";

struct Uniforms {
    simd_float4x4 mvp;
    simd_float4 rect;
    float alpha;
    float opaque;
    float pad[2];
};

PFN_vkExportMetalObjectsEXT ExportMetalObjects(VkDevice device) {
    return reinterpret_cast<PFN_vkExportMetalObjectsEXT>(vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT"));
}

}  // namespace

bool Available() { return true; }

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
        auto make = [&](NSString* vertex, bool blend) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:vertex];
            d.fragmentFunction = [library newFunctionWithName:@"composite_fragment"];
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
        MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
        ds.depthWriteEnabled = NO;
        ds.depthCompareFunction = MTLCompareFunctionAlways;
        depth_write = [mtl_device newDepthStencilStateWithDescriptor:ds];
        return eye_pipeline && quad_pipeline;
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
    return true;
}

VkResult Host::CreateInstance(const VkInstanceCreateInfo& info, VkInstance& instance) {
    std::vector<const char*> extensions(info.ppEnabledExtensionNames, info.ppEnabledExtensionNames + info.enabledExtensionCount);
    const auto add = [&](const char* name) {
        if (std::none_of(extensions.begin(), extensions.end(), [&](const char* e) { return std::strcmp(e, name) == 0; })) extensions.push_back(name);
    };
    add("VK_EXT_metal_objects");
    add("VK_KHR_portability_enumeration");
    VkInstanceCreateInfo copy = info;
    copy.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    copy.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
    copy.ppEnabledExtensionNames = extensions.data();
    return vkCreateInstance(&copy, nullptr, &instance);
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
    // What "far" is in the drawable's depth convention: a distant point through its projection.
    float far_depth = 0.0f;
    {
        const simd_float4x4 p = cp_drawable_compute_projection(x.drawable, cp_axis_direction_convention_right_up_back, 0);
        const simd_float4 clip = simd_mul(p, simd_make_float4(0.0f, 0.0f, -1000.0f, 1.0f));
        if (std::fabs(clip.w) > 1.0e-6f) far_depth = std::clamp(clip.z / clip.w, 0.0f, 1.0f);
    }
    const size_t view_count = std::min<size_t>(2, cp_drawable_get_view_count(x.drawable));
    for (size_t v = 0; v < view_count; ++v) {
        cp_view_t view = cp_drawable_get_view(x.drawable, v);
        cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
        const size_t texture_index = cp_view_texture_map_get_texture_index(map);
        const size_t slice = cp_view_texture_map_get_slice_index(map);
        const MTLViewport viewport = cp_view_texture_map_get_viewport(map);
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = cp_drawable_get_color_texture(x.drawable, texture_index);
        pass.colorAttachments[0].slice = slice;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLTexture> depth = cp_drawable_get_depth_texture(x.drawable, texture_index);
        if (depth) {
            pass.depthAttachment.texture = depth;
            pass.depthAttachment.slice = slice;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            // Everything distant until the game hands real depth (the compositor reprojects with it).
            pass.depthAttachment.clearDepth = far_depth;
        }
        id<MTLRasterizationRateMap> rate = cp_drawable_get_rasterization_rate_map(x.drawable, texture_index);
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
                [enc setFragmentTexture:x.textures[v][eye_swapchains_[v].index] atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            if (layers.screen || layers.hud) {
                const simd_float4x4 projection = cp_drawable_compute_projection(x.drawable, cp_axis_direction_convention_right_up_back, v);
                const simd_float4x4 world_from_view = simd_mul(x.origin_from_device, cp_view_get_transform(view));
                const simd_float4x4 view_from_world = Inverse(world_from_view);
                const simd_float4x4 view_projection = simd_mul(projection, view_from_world);
                [enc setRenderPipelineState:x.quad_pipeline];
                auto quad = [&](int which, const Swapchain& sc, const glm::quat& orientation, const glm::vec3& position, const glm::vec2& size, bool alpha) {
                    Uniforms q{};
                    q.mvp = simd_mul(view_projection, ModelMatrix(orientation, position, size));
                    q.rect = simd_make_float4(0.0f, 0.0f, 1.0f, 1.0f);
                    q.alpha = 1.0f;
                    q.opaque = alpha ? 0.0f : 1.0f;
                    [enc setVertexBytes:&q length:sizeof(q) atIndex:0];
                    [enc setFragmentBytes:&q length:sizeof(q) atIndex:0];
                    [enc setFragmentTexture:x.textures[which][sc.index] atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                };
                if (layers.screen) quad(3, screen_swapchain_, layers.screen_orientation, layers.screen_position, layers.screen_size, false);
                if (layers.hud) quad(2, hud_swapchain_, layers.hud_orientation, layers.hud_position, layers.hud_size, true);
            }
        }
        [enc endEncoding];
    }
    cp_drawable_encode_present(x.drawable, cb);
    [cb commit];
    cp_frame_end_submission(x.frame);
    x.submitting = false;
    x.loop_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - x.frame_start).count();
    if (anything) {
        ++frames_submitted_;
        x.PublishStats(x.eye_width, x.eye_height, layers.projection ? "stereo" : layers.screen ? "screen" : "menu");
    }
    x.frame = nil;
    x.drawable = nil;
    frame_open_ = false;
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
}  // namespace

void ApplySettings(AppSettings& s) {
    s.vr.enabled = true;
    s.vr.resolution_scale = std::clamp(Number("PT_VP_RESOLUTION_SCALE", 0.6f), 0.5f, 2.0f);
    s.vr.turn = static_cast<int>(Number("PT_VP_TURN", 0.0f));
    s.vr.snap_degrees = std::clamp(Number("PT_VP_SNAP_DEGREES", 30.0f), 10.0f, 90.0f);
    s.vr.smooth_speed = std::clamp(Number("PT_VP_SMOOTH_SPEED", 90.0f), 20.0f, 360.0f);
    const int hand = static_cast<int>(Number("PT_VP_FLASHLIGHT_HAND", -1.0f));
    s.vr.flashlight = hand >= 0 ? 1 : 0;
    s.vr.flashlight_hand = hand == 1 ? 1 : 0;
    const int fps = static_cast<int>(Number("PT_VP_TARGET_FPS", 90.0f));
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
    // Never in the eyes (the VR mode turns them off as well; kept off here for the virtual screen).
    s.graphics.motion_blur = false;
    s.graphics.depth_of_field = false;
    s.graphics.lens_distortion = false;
    s.graphics.lens_ghosts = false;
    s.graphics.film_grain = 0.0f;
    s.ray_tracing = {};
    (void)fps;
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
        b.log_path = std::string([documents[0] UTF8String]) + "/pt.log";
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

const char* pt_vp_log_path(void) {
    pt::xr::Bridge& b = pt::xr::bridge();
    std::lock_guard<std::mutex> lock(b.mutex);
    return b.log_path.empty() ? nullptr : b.log_path.c_str();
}

}  // extern "C"
