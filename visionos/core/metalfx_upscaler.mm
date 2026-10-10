// SPDX-License-Identifier: MIT
//
// Apple's MetalFX temporal scaler as one of the game's upscalers (UpscalerKind::MetalFx).
//
// The game's upscalers (engine/render/upscale) all take the same inputs: the scene's HDR colour
// drawn with a sub-pixel jitter, its depth, motion vectors (camera and objects, current to
// previous, in UV units), a reactive mask (particles and the flashlight, which must not leave
// trails), and give back the picture at the output size before bloom, tonemapping and the rest of
// post. This backend hands those same textures to MTLFXTemporalScaler.
//
// MetalFX needs a Metal command buffer, and the game records Vulkan. MoltenVK (with our patch
// patches/moltenvk/0002-metal-encode-command.patch) encodes a callback at that point of the
// Vulkan command buffer: its Metal encoders end, the callback encodes MetalFX on the very Metal
// command buffer, and the game's next passes follow in new encoders. MoltenVK's textures are
// hazard-tracked, so Metal orders the reads and writes on its own.
//
// One scaler (one history) per picture: a headset frame has up to four views (UpscaleDispatch
// .history), and each keeps its own past, otherwise an eye would accumulate the other eye's.

#include "engine/render/upscale/upscale.h"

#include "engine/core/log.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>

// MoltenVK's private command (our patch): Metal work inside a Vulkan command buffer.
extern "C" void vkCmdEncodeMetalMVK(VkCommandBuffer commandBuffer, void (*callback)(void* data, void* mtlCommandBuffer), const void* data,
                                    uint32_t dataSize);

namespace pt {
namespace {

constexpr uint32_t kHistories = 4;

PFN_vkExportMetalObjectsEXT ExportFn(VkDevice device) {
    return reinterpret_cast<PFN_vkExportMetalObjectsEXT>(vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT"));
}

id<MTLTexture> TextureOf(VkDevice device, VkImage image) {
    if (image == VK_NULL_HANDLE) return nil;
    PFN_vkExportMetalObjectsEXT fn = ExportFn(device);
    if (!fn) return nil;
    VkExportMetalTextureInfoEXT info{VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT};
    info.image = image;
    info.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
    VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
    objects.pNext = &info;
    fn(device, &objects);
    return info.mtlTexture;
}

// What the callback needs, copied into the Vulkan command (plain data: the textures and the
// scaler are kept alive by their owners until the command buffer has run).
struct EncodeData {
    void* scaler;    // id<MTLFXTemporalScaler>
    void* color;     // id<MTLTexture> ...
    void* depth;
    void* motion;
    void* reactive;  // may be null
    void* output;
    float jitter_x, jitter_y;
    float motion_x, motion_y;
    float pre_exposure;
    uint32_t reset;
};

void Encode(void* data, void* command_buffer) {
    const EncodeData& d = *static_cast<const EncodeData*>(data);
    id<MTLFXTemporalScaler> scaler = (__bridge id<MTLFXTemporalScaler>)d.scaler;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    if (!scaler || !cb) return;
    scaler.colorTexture = (__bridge id<MTLTexture>)d.color;
    scaler.depthTexture = (__bridge id<MTLTexture>)d.depth;
    scaler.motionTexture = (__bridge id<MTLTexture>)d.motion;
    scaler.outputTexture = (__bridge id<MTLTexture>)d.output;
    if (d.reactive && [scaler respondsToSelector:@selector(setReactiveMaskTexture:)]) {
        scaler.reactiveMaskTexture = (__bridge id<MTLTexture>)d.reactive;
    }
    scaler.jitterOffsetX = d.jitter_x;
    scaler.jitterOffsetY = d.jitter_y;
    scaler.motionVectorScaleX = d.motion_x;
    scaler.motionVectorScaleY = d.motion_y;
    scaler.preExposure = d.pre_exposure;
    scaler.depthReversed = YES;  // the game's depth is reversed (1 near, 0 far)
    scaler.reset = d.reset != 0;
    [scaler encodeToCommandBuffer:cb];
}

bool Covers(MTLTextureUsage have, MTLTextureUsage need) {
    return (have & need) == need;
}

class MetalFxBackend final : public UpscaleBackend {
public:
    explicit MetalFxBackend(vk::Context& ctx) : ctx_(ctx) {}
    ~MetalFxBackend() override { Release(); }

    UpscalerKind Kind() const override { return UpscalerKind::MetalFx; }

    bool Available(std::string& reason) override {
        reason.clear();
        PFN_vkExportMetalObjectsEXT fn = ExportFn(ctx_.device);
        if (!fn) {
            reason = "MoltenVK has no vkExportMetalObjectsEXT";
            return false;
        }
        VkExportMetalDeviceInfoEXT device_info{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
        VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
        objects.pNext = &device_info;
        fn(ctx_.device, &objects);
        device_ = device_info.mtlDevice;
        if (!device_) {
            reason = "no Metal device";
            return false;
        }
        if (![MTLFXTemporalScalerDescriptor supportsDevice:device_]) {
            reason = "this GPU has no MetalFX temporal scaling";
            return false;
        }
        return true;
    }

    // The scalers are made at the first dispatch of each picture, from the real textures' formats.
    bool Create(VkCommandBuffer, const UpscaleCreate& create) override {
        Release();
        render_ = create.render;
        display_ = create.display;
        if (render_.width == 0 || render_.height == 0 || render_.width > display_.width || render_.height > display_.height) {
            LogError("upscale: MetalFX cannot go from {}x{} to {}x{}", render_.width, render_.height, display_.width, display_.height);
            return false;
        }
        const float scale = static_cast<float>(display_.width) / static_cast<float>(render_.width);
        if ([MTLFXTemporalScalerDescriptor respondsToSelector:@selector(supportedInputContentMinScaleForDevice:)]) {
            const float lo = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device_];
            const float hi = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device_];
            if (scale < lo - 0.001f || scale > hi + 0.001f) {
                LogError("upscale: MetalFX takes scales {:.2f} to {:.2f}, not {:.2f}", lo, hi, scale);
                return false;
            }
        }
        static const char* sign = std::getenv("PT_METALFX_JITTER_SIGN");
        jitter_sign_ = sign && std::atof(sign) < 0.0 ? -1.0f : 1.0f;
        return true;
    }

    bool Dispatch(const UpscaleDispatch& d) override {
        const uint32_t h = std::min(d.history, kHistories - 1);
        const VkDevice device = ctx_.device;
        id<MTLTexture> color = TextureOf(device, d.color.image);
        id<MTLTexture> depth = TextureOf(device, d.depth.image);
        id<MTLTexture> motion = TextureOf(device, d.motion.image);
        id<MTLTexture> output = TextureOf(device, d.output.image);
        id<MTLTexture> reactive = d.reactive.Valid() ? TextureOf(device, d.reactive.image) : nil;
        if (!color || !depth || !motion || !output) {
            Fail("MoltenVK gave no Metal texture for an input");
            return false;
        }
        bool fresh = false;
        if (!scalers_[h] || color.pixelFormat != formats_[h][0] || output.pixelFormat != formats_[h][1]) {
            MTLFXTemporalScalerDescriptor* desc = [MTLFXTemporalScalerDescriptor new];
            desc.colorTextureFormat = color.pixelFormat;
            desc.depthTextureFormat = depth.pixelFormat;
            desc.motionTextureFormat = motion.pixelFormat;
            desc.outputTextureFormat = output.pixelFormat;
            desc.inputWidth = d.render.width;
            desc.inputHeight = d.render.height;
            desc.outputWidth = d.display.width;
            desc.outputHeight = d.display.height;
            desc.autoExposureEnabled = YES;
            const bool use_reactive = reactive != nil && [desc respondsToSelector:@selector(setReactiveMaskTextureEnabled:)];
            if (use_reactive) {
                desc.reactiveMaskTextureEnabled = YES;
                desc.reactiveMaskTextureFormat = reactive.pixelFormat;
            }
            id<MTLFXTemporalScaler> scaler = [desc newTemporalScalerWithDevice:device_];
            if (!scaler) {
                Fail("MTLFXTemporalScaler could not be created");
                return false;
            }
            const char* missing = !Covers(color.usage, scaler.colorTextureUsage)    ? "colour"
                                  : !Covers(depth.usage, scaler.depthTextureUsage)  ? "depth"
                                  : !Covers(motion.usage, scaler.motionTextureUsage) ? "motion"
                                  : !Covers(output.usage, scaler.outputTextureUsage) ? "output"
                                                                                      : nullptr;
            if (missing) {
                Fail(std::string("the ") + missing + " texture lacks a usage MetalFX needs");
                return false;
            }
            scalers_[h] = scaler;
            reactive_[h] = use_reactive;
            formats_[h][0] = color.pixelFormat;
            formats_[h][1] = output.pixelFormat;
            fresh = true;
            LogInfo("upscale: MetalFX temporal {}x{} -> {}x{} for picture {} (reactive mask {})", d.render.width, d.render.height, d.display.width,
                    d.display.height, h, use_reactive ? "on" : "off");
        }
        EncodeData e{};
        e.scaler = (__bridge void*)scalers_[h];
        e.color = (__bridge void*)color;
        e.depth = (__bridge void*)depth;
        e.motion = (__bridge void*)motion;
        e.reactive = reactive_[h] ? (__bridge void*)reactive : nullptr;
        e.output = (__bridge void*)output;
        // The jitter in the colour's pixels, in the direction the picture moved (as FSR takes it).
        e.jitter_x = d.jitter.x * jitter_sign_;
        e.jitter_y = d.jitter.y * jitter_sign_;
        // The game's motion vectors are in UV units (current to previous): times the input size.
        e.motion_x = d.motion_scale.x;
        e.motion_y = d.motion_scale.y;
        e.pre_exposure = 1.0f;
        e.reset = (d.reset || fresh) ? 1u : 0u;
        if (logged_ < 8) {
            ++logged_;
            LogInfo("upscale: MetalFX picture {} jitter ({:.3f} {:.3f}) px, motion scale ({:.0f} {:.0f}), reset {}", h, e.jitter_x, e.jitter_y, e.motion_x,
                    e.motion_y, e.reset);
        }
        vkCmdEncodeMetalMVK(d.cmd, &Encode, &e, sizeof(e));
        return true;
    }

    void Release() override {
        for (uint32_t i = 0; i < kHistories; ++i) {
            scalers_[i] = nil;
            reactive_[i] = false;
            formats_[i][0] = formats_[i][1] = MTLPixelFormatInvalid;
        }
    }

private:
    void Fail(const std::string& why) {
        if (why != last_failure_) {
            LogError("upscale: MetalFX: {}", why);
            last_failure_ = why;
        }
    }

    vk::Context& ctx_;
    id<MTLDevice> device_ = nil;
    VkExtent2D render_{};
    VkExtent2D display_{};
    id<MTLFXTemporalScaler> scalers_[kHistories];
    bool reactive_[kHistories] = {};
    MTLPixelFormat formats_[kHistories][2] = {};
    float jitter_sign_ = 1.0f;
    int logged_ = 0;
    std::string last_failure_;
};

std::unique_ptr<UpscaleBackend> CreateMetalFx(vk::Context& ctx) {
    return std::make_unique<MetalFxBackend>(ctx);
}

}  // namespace

// Called by the host before the game makes its device (pt::visionos::ApplySettings). An explicit
// call, not a static initialiser: the linker leaves out a static library's object nobody calls.
void RegisterMetalFxUpscaler() {
    SetPlatformUpscaler(UpscalerKind::MetalFx, &CreateMetalFx);
}

}  // namespace pt
