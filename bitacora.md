# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad`
(submódulo; a su vez pinea `pt-pc` 5c63078 + 18 parches) → `tools/prepare_source.py` aplica los
cambios de visionOS sobre `build/port-src`. Sin emulación ni JIT: C++ nativo + MoltenVK.

## Estado

- Repo en GitHub (`escojoncio/PTVisionPro`, rama `main`). Código escrito sin compilar en local
  (no hay Mac en la sesión); las builds de CI van corrigiendo errores de compilación.
- Builds: 1 y 2 fallaron en `fetchDependencies --xros` (la opción de MoltenVK es
  `--visionos`, target `make visionos`; corregido). **Build 3 (run 37790180042) lanzada**:
  primera compilación de MoltenVK para visionOS (30–40 min, luego en caché). Pendiente de leer.
- Logs de CI: los logs de los jobs están en Azure y no se pueden leer desde la sesión; el
  workflow publica el log completo en la rama `ci-logs` (`latest.log` y `run-N.log`):
  `gh api "repos/escojoncio/PTVisionPro/contents/latest.log?ref=ci-logs" --jq .content | base64 -d`.
- Lanzar build: `gh api -X POST repos/escojoncio/PTVisionPro/actions/workflows/visionos.yml/dispatches -f ref=main`
  (GraphQL de `gh workflow run` no está disponible).

## Arquitectura (decidida, no cambiar sin motivo)

- El modo VR de upstream (`src/engine/xr/`, `src/game/vr_play.cpp`) se reutiliza entero. Solo se
  sustituye el backend OpenXR por `visionos/core/xr_host_visionos.mm`, que implementa
  `pt::xr::Host` sobre Compositor Services (C API `cp_*`) + ARKit (C API `ar_*`).
  - `xr_host.cpp` original queda envuelto en `#if !PT_VISIONOS`.
  - Imágenes de ojo/HUD/pantalla virtual: `VkImage` propias (3 por swapchain, round-robin)
    exportadas a `MTLTexture` con `VK_EXT_metal_objects` (`vkExportMetalObjectsEXT` vía
    `vkGetDeviceProcAddr`). Formato `VK_FORMAT_R8G8B8A8_SRGB`.
  - Composición: una pasada Metal propia por vista (ojo fullscreen + quad pantalla + quad HUD con
    alpha) sobre el drawable (`rgba16Float`, `depth32Float`, foveación con el
    `rasterizationRateMap` del drawable), en la **misma `MTLCommandQueue` que MoltenVK**
    (exportada con `VkExportMetalCommandQueueInfoEXT`) → orden GPU garantizado sin esperas CPU.
  - Ritmo: `cp_layer_renderer_query_next_frame` → `predict_timing` → `start/end_update` →
    `cp_time_wait_until(optimal_input_time)` (WaitFrame) → `start_submission` + `query_drawable`
    + `ar_world_tracking_provider_query_device_anchor_at_timestamp` (BeginFrame) → `LocateViews`
    desde `cp_view_get_transform`/`cp_view_get_tangents` → `encode_present` + `end_submission`
    (EndFrame). Profundidad limpiada al valor "lejos" calculado con `cp_drawable_compute_projection`.
  - Shaders Metal compilados en runtime (`newLibraryWithSource`), sin .metallib.
- `main.cpp` compilado como librería estática `libpt_visionos.a` con `main` renombrado a `pt_game_main` (edición de prepare_source) y
  `SDL_MAIN_HANDLED`; la app Swift llama `pt_vp_start` (hilo del juego). SDL solo
  `EVENTS|AUDIO` (sin vídeo, sin ventana: `app.window = nullptr`; el bucle VR ya lo soporta).
- Mando: GameController en Swift (`PlayStationController.swift`) → `pt_vp_set_controller` →
  `Host::SyncActions`. No se usa el gamepad de SDL.
- Ajustes: la app exporta `PT_VP_*` como entorno; `pt::visionos::ApplySettings` (en el .mm)
  los vuelca en `AppSettings` tras cargar `pt.ini` (vr.enabled=1, resolution_scale, giro,
  linterna, sombras, SSAO, bloom, reflejos; fps_limit=0, vsync=0, sin upscalers).

## Cambios por fichero (todos nuevos salvo los que aplica `prepare_source.py`)

- `tools/prepare_source.py`: ediciones exactas sobre `build/port-src`: `xr_host.cpp` (guard),
  `renderer.cpp` (barrera final solo si `target_image`), `main.cpp` (vr=true en visionOS,
  `SDL_SetMainReady` + `SDL_INIT_EVENTS|AUDIO`, `ApplySettings`, sin `SDL_CreateWindow`,
  forward decl), `cmake/Apple.cmake` (visionOS cuenta como PT_IOS), `CMakeLists.txt` (opción
  `PT_VISIONOS`, target `pt_visionos`, deps `pt_shaders pt_build_id`).
- `tools/build_visionos.sh`: MoltenVK `make xros` (commit de `source-lock.json`), modelos de voz
  (sha256 del dependency-lock), cmake `-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros`,
  recoge `*.a` en `build/visionos/lib`, recursos en `visionos/Resources/{shaders,voice,fonts,
  licenses}`, `PT_LINK_FLAGS` = lista de archivos .a (dos veces), xcodegen + xcodebuild sin
  firma → `build/visionos/ipa/PTVisionPro-N.ipa`.
- `.github/workflows/visionos.yml`: macos-15, solo `workflow_dispatch` o commit con `[build]`;
  cachés MoltenVK (clave: source-lock) y deps+voz (clave: dependency-lock); artefacto IPA +
  pre-release `build-N`.
- `visionos/App/*`: launcher SwiftUI (presets M2/M5/Personalizado en `PTSettings.swift`,
  detección por `hw.machine` RealityDevice14 → M2), `GameRunner.swift`, `PlayStationController.swift`,
  vistas Inicio/Ajustes/Rendimiento/Registro, `pt_visionos.h` (API C). Bundle id
  `com.kdt.livecontainer`. Recursos del juego como carpetas en la raíz del bundle
  (`ExecutableDir()/shaders` etc.).

## Pendiente (siguiente sesión, en orden)

1. Leer el log de la build 3 y corregir errores de compilación (riesgos conocidos: ggml/whisper con `CMAKE_SYSTEM_NAME=visionOS`; SDL3 sin
   vídeo en visionOS; nombres exactos de la C API de Compositor Services; `GCProductCategory`
   de los Sense; `IOKit` en visionOS).
2. Primera prueba en el visor: ver estéreo. Comprobar orientación de los ejes (ARKit es Y arriba,
   -Z adelante, igual que OpenXR; si la imagen sale girada revisar `QuatOf`/tangentes) y la
   altura (ARKit origen en el suelo; `VrPlay` recentra en la cabeza).
3. Profundidad real al drawable (hoy constante "lejos") para que la reproyección del sistema no
   deforme en cerca; `MetalFX` opcional en la pasada de composición; resolución dinámica.
4. Sombras/culling compartidos entre ojos; sync GPU sin `vkQueueWaitIdle` ya está resuelto por
   cola compartida, verificar que MoltenVK no difiere los commits (`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS`).
5. PS VR2 Sense 6DoF (pose) cuando la API lo exponga; hoy `hand_valid=false`.
6. Comprobación de datos en el launcher: hecha (chunk1.psarc, texture.qar); probar con los datos reales.
