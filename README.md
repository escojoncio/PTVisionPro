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
your computer as the pt-ipad and pt-pc projects describe.

The data and the saves live outside the app, in a `VPS4` folder shared with the other Vision Pro
ports, so they survive deleting or replacing the app:

1. In the Files app, under "On My Apple Vision Pro", make a folder called `VPS4`.
2. In the launcher, press **Choose VPS4** and pick it. The app makes `Juegos` (games) and
   `Partidas` (saves) inside.
3. Copy the `CUSA01127` folder (it has `chunk1.psarc` and `texture.qar`) to `VPS4/Juegos`, for
   example from a shared folder on your computer (Files › Connect to Server), and press **Find**.

The launcher checks the release by the files' exact sizes. Saves go to
`VPS4/Partidas/CUSA01127`.

P.T. and its content belong to their rights holders. This project is not affiliated with
Konami or Kojima Productions.

## Playing

- **Controllers**: any controller visionOS knows (DualSense, DualShock 4, Xbox, Switch Pro), or
  a pair of PlayStation VR2 Sense controllers, tracked in space: with them the flashlight can be
  held in your hand (Settings › VR › Flashlight).
- **Menus with your hands**: while a menu is open a ray comes out of each hand; pinch thumb and
  index finger to choose. Without a controller, a long pinch of the left hand opens the pause
  menu. With Sense controllers, point and pull the trigger.
- **Leaving and coming back**: closing the game's space (the Digital Crown) pauses the game;
  **Continue in VR** in the launcher goes back where you were. Settings › VR › Recentre view puts
  you back in the corridor where you stand (also done by itself after recentring with a long
  press of the Digital Crown).
- **Settings**: everything is in the launcher and in the game's own menu (its PC page becomes a
  Vision Pro page): presets for the Vision Pro M2 and M5 or custom, 90 or 45 frames a second,
  image size with MetalFX upscaling, field of view, foveation, graphics, turning and comfort.
  Both places stay in step.

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

On a Mac with Xcode 26 (visionOS 26 SDK), `cmake`, `ninja`, `glslc` (`brew install shaderc`) and
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
