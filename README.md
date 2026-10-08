# PTVisionPro

P.T. on Apple Vision Pro, played in full immersive VR.

A native ARM64 build of the reconstructed P.T. engine for visionOS: the game's own C++ code
(no emulation, no JIT), Vulkan translated to Metal by MoltenVK, both eyes drawn by the engine's
VR mode and composed straight into the headset's Compositor Services drawables. The launcher
is a visionOS app with every setting inside it, including whole presets for the Vision Pro M2,
the Vision Pro M5 or a custom one.

**Status: in development, first builds.** See `bitacora.md` for the exact state.

## What it is built on

- [buberlo/pt-ipad](https://github.com/buberlo/pt-ipad): the iPad port this one starts from
  (Apple packaging, MoltenVK renderer, asset installation, touch host), used as a submodule and
  patched for visionOS.
- [LoreanXavier/pt-pc](https://github.com/LoreanXavier/pt-pc): the reconstructed C++ engine and
  game, with its experimental OpenXR VR mode, whose design this port keeps (the head replaces
  the look stick, cutscenes on a virtual screen, the UI on a floating panel).
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK), [SDL3](https://github.com/libsdl-org/SDL)
  and [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

Written by Claude, building on the great work of those projects; the repository owner
contributed ideas on how some things could be adapted.

## Game data

**No game data is included and none is distributed.** You need your own, legally obtained copy
of P.T. (the US release `CUSA01127` v01.00 is the one the port is verified with), extracted on
your computer as the pt-ipad and pt-pc projects describe. Copy the `CUSA01127` folder (it has
`chunk1.psarc` and `texture.qar`) into the app's folder in the Files app on the Vision Pro.
The launcher checks the folder before starting.

P.T. and its content belong to their rights holders. This project is not affiliated with
Konami or Kojima Productions.

## Layout

| Path | What |
| --- | --- |
| `upstream/pt-ipad` | The iPad port, pinned (it pins `pt-pc` in turn) |
| `tools/prepare_source.py` | pt-ipad's reconstructed source plus the visionOS changes → `build/port-src` |
| `visionos/core/` | The engine's VR host for visionOS (Compositor Services, ARKit, Metal composition) and the C API the app uses |
| `visionos/App/` | The launcher (SwiftUI) |
| `tools/build_visionos.sh` | MoltenVK for visionOS, the game as static libraries, the app as an IPA |
| `.github/workflows/visionos.yml` | The same, on GitHub Actions (manual runs or commits with `[build]`) |

## Building

On a Mac with Xcode 16 (visionOS SDK), `cmake`, `ninja`, `glslc` (`brew install shaderc`) and
`xcodegen`:

```
git clone --recurse-submodules <this repository>
cd PTVisionPro
tools/build_visionos.sh
```

The unsigned IPA lands in `build/visionos/ipa/`. Sign and install it with your sideloading
tool of choice.

## License

MIT (`LICENSE`), like pt-ipad and pt-pc. Dependency licenses ship inside the app under
`licenses/`.
