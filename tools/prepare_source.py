#!/usr/bin/env python3
"""Builds the visionOS source tree: pt-ipad's reconstructed Apple source (upstream pt-pc plus its
18 patches) with the Vision Pro changes applied on top.

    python3 tools/prepare_source.py            -> build/port-src
    python3 tools/prepare_source.py --edit     -> the same, with the edits below committed and
                                                  patches/*.patch applied on top as uncommitted
                                                  changes: edit, then `git add -N <new files>`
                                                  (e.g. shaders/light_all.frag) and `git diff > patches/<n>.patch`:
                                                  plain `git diff` leaves out new files

Every change is an exact text replacement; a missing anchor is an error, never a silent skip,
so an upstream bump shows up here first.
"""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PT_IPAD = ROOT / 'upstream/pt-ipad'
OUT = ROOT / 'build/port-src'


def replace(path: pathlib.Path, old: str, new: str, count: int = 1) -> None:
    text = path.read_text()
    found = text.count(old)
    if found != count:
        sys.exit(f'{path.relative_to(OUT)}: anchor found {found} times, expected {count}:\n{old}')
    path.write_text(text.replace(old, new))


def main() -> int:
    if not (PT_IPAD / 'tools/prepare_source.py').is_file():
        sys.exit('upstream/pt-ipad is missing: git submodule update --init --recursive')
    if OUT.exists():
        shutil.rmtree(OUT)
    subprocess.run([sys.executable, str(PT_IPAD / 'tools/prepare_source.py'), '--output', str(OUT)], check=True)
    src = OUT / 'src'

    # --- The OpenXR host steps aside: visionos/core/xr_host_visionos.mm is the host. ----------
    xr_host = src / 'engine/xr/xr_host.cpp'
    xr_host.write_text('#if !PT_VISIONOS\n' + xr_host.read_text() + '\n#endif  // !PT_VISIONOS\n')

    # --- renderer: no window and no capture image means no final image to transition. --------
    replace(src / 'engine/render/renderer.cpp',
            '    } else if (!window_) {\n        output_ready_ = true;\n',
            '    } else if (!window_ && target_image) {\n        output_ready_ = true;\n')

    main_cpp = src / 'main.cpp'
    # --- VR on, SDL without its video and without its main. ----------------------------------
    replace(main_cpp,
            '#if PT_IOS\n    app.options.no_update_check = true;\n    app.options.no_vr = true;\n',
            '#if PT_IOS\n    app.options.no_update_check = true;\n#if PT_VISIONOS\n    app.options.vr = true;\n#else\n    app.options.no_vr = true;\n#endif\n')
    replace(main_cpp,
            '#if PT_IOS\n    if (!SDL_Init(options.headless ? SDL_INIT_EVENTS : (SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_AUDIO))) {\n',
            '#if PT_IOS\n#if PT_VISIONOS\n    SDL_SetMainReady();\n    if (!SDL_Init(SDL_INIT_EVENTS | SDL_INIT_AUDIO)) {\n#else\n'
            '    if (!SDL_Init(options.headless ? SDL_INIT_EVENTS : (SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_AUDIO))) {\n#endif\n')
    # --- The app's settings replace the iPad's forced ones. ----------------------------------
    replace(main_cpp,
            '        app.settings.graphics.enhanced_textures = false;\n        app.settings.vr.enabled = false;\n#endif\n',
            '        app.settings.graphics.enhanced_textures = false;\n        app.settings.vr.enabled = false;\n#if PT_VISIONOS\n'
            '        pt::visionos::ApplySettings(app.settings);\n#endif\n#endif\n')
    # --- No window: the headset is the display. ----------------------------------------------
    replace(main_cpp,
            '        app.window = SDL_CreateWindow("P.T.", app.settings.display.width, app.settings.display.height,\n',
            '#if PT_VISIONOS\n        app.window = nullptr;\n#else\n'
            '        app.window = SDL_CreateWindow("P.T.", app.settings.display.width, app.settings.display.height,\n')
    replace(main_cpp,
            '        ApplyFullscreen(app);\n    }\n    MountMods(app);\n',
            '        ApplyFullscreen(app);\n#endif\n    }\n    MountMods(app);\n')
    replace(main_cpp,
            'int main(int argc, char** argv) {\n',
            '#if PT_VISIONOS\nint pt_game_main(int argc, char** argv) {  // the app calls it (visionos/core)\n#else\nint main(int argc, char** argv) {\n#endif\n')
    replace(main_cpp,
            '#include "engine/xr/xr_host.h"\n',
            '#include "engine/xr/xr_host.h"\n#if PT_VISIONOS\nnamespace pt::visionos { void ApplySettings(pt::AppSettings& settings); }\n#endif\n')

    # --- CMake: visionOS is iOS to the Apple build; the game as a static library. -------------
    replace(OUT / 'cmake/Apple.cmake',
            'if(CMAKE_SYSTEM_NAME STREQUAL "iOS")\n  set(PT_IOS ON)\n',
            'if(CMAKE_SYSTEM_NAME STREQUAL "iOS" OR CMAKE_SYSTEM_NAME STREQUAL "visionOS")\n  set(PT_IOS ON)\n')
    cmake = OUT / 'CMakeLists.txt'
    cmake.write_text(cmake.read_text() + '''
# --- Apple Vision Pro (PTVisionPro): the game as a static library the visionOS app links. ---
option(PT_VISIONOS "Build the game as libpt_visionos.a for the visionOS app" OFF)
set(PT_VISIONOS_DIR "" CACHE PATH "PTVisionPro's visionos/ folder (core sources and the C header)")
if(PT_VISIONOS)
  enable_language(OBJCXX)
  target_compile_definitions(pt_engine PUBLIC PT_VISIONOS=1)
  add_library(pt_visionos STATIC src/main.cpp "${PT_VISIONOS_DIR}/core/xr_host_visionos.mm" "${PT_VISIONOS_DIR}/core/metalfx_upscaler.mm")
  target_compile_definitions(pt_visionos PRIVATE SDL_MAIN_HANDLED=1 PT_NATIVE_BUILD="${PT_APP_BUILD}")
  target_include_directories(pt_visionos PRIVATE "${PT_VISIONOS_DIR}/App/Bridge" "${PT_VISIONOS_DIR}/core" "${CMAKE_BINARY_DIR}/generated")
  set_source_files_properties("${PT_VISIONOS_DIR}/core/xr_host_visionos.mm" "${PT_VISIONOS_DIR}/core/metalfx_upscaler.mm" PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(pt_visionos PUBLIC pt_engine)
  add_dependencies(pt_visionos pt_shaders pt_build_id)
endif()
''')
    # --- Larger changes as ordinary patches, on top of the edits above (patches/*.patch). -------
    if '--edit' in sys.argv:
        git = ['git', '-c', 'user.name=prepare', '-c', 'user.email=prepare@localhost']
        subprocess.run(git + ['add', '-A'], cwd=OUT, check=True)
        subprocess.run(git + ['commit', '-qm', 'visionos edits (prepare_source.py)'], cwd=OUT, check=True)
    for patch in sorted((ROOT / 'patches').glob('*.patch')):
        subprocess.run(['git', 'apply', '--whitespace=nowarn', str(patch)], cwd=OUT, check=True)
        print(f'Applied {patch.name}')

    print(f'Prepared {OUT}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
