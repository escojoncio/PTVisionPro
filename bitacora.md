# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad`
(submódulo; a su vez pinea `pt-pc` 5c63078 + 18 parches) → `tools/prepare_source.py` aplica los
cambios de visionOS sobre `build/port-src`. Sin emulación ni JIT: C++ nativo + MoltenVK.

## Estado

- Repo `escojoncio/PTVisionPro` (rama `main`). Sin Mac en la sesión: C++ comprobado con
  `clang++ -fsyntax-only` en Linux (ver "Comprobación local"); `.mm` y Swift solo compilan en CI.
- Build 3 (run 37790180042): MoltenVK visionOS, **todo el juego C++ y `xr_host_visionos.mm`
  compilaron y enlazaron en `libpt_visionos.a`**. Falló solo Swift: `LayerRenderer.Configuration.maxRenderQuality`
  no existe en el SDK de visionOS 2 (Xcode 16) → quitado (también el deslizador de calidad de
  renderizado, MetalFX y resolución dinámica del launcher: no implementados aún).
- Build 4: lanzada con commit `[build]` tras los menús/manos (abajo). Pendiente de leer.
- Logs de CI: `gh api "repos/escojoncio/PTVisionPro/contents/latest.log?ref=ci-logs" --jq .content | base64 -d`
  (los logs de jobs están en Azure, bloqueado). Lanzar: `gh api -X POST repos/escojoncio/PTVisionPro/actions/workflows/visionos.yml/dispatches -f ref=main`.

## Menús del juego en el visor (patches/0001-visionos-menus.patch + .mm + Swift)

- Página "PC Settings" → "VISION PRO" (`PcSettings::HeadsetSections`, `main.cpp`): preajuste
  M2/M5/Personalizado, 90/45 fps (en vivo), tamaño de imagen 50–150 % y foveado (al reiniciar),
  enlaces a Gráficos y VR; Sonido (volumen, prueba de micro); Controles (vibración, zona muerta);
  Progreso. Fuera: modo de pantalla, resolución, v-sync, upscalers, frame gen, ray tracing,
  texturas mejoradas, ratón, inclinación de cámara, tercera persona, LiveSplit, "VR mode".
  Efectos: solo bloom y claridad. Página VR: linterna cabeza/mano izq/mano der, giro, grados del
  paso (15–90), velocidad de giro (45–180). Textos en/es en `pc_settings.cpp` (bloque `#if PT_VISIONOS`
  al principio de `kTexts`, que tiene prioridad sobre las entradas originales).
- Sincronía: cambios en el menú → `pt::visionos::SettingChanged` → callback
  `pt_vp_settings_callback` → `GameRunner.settingFromGame` → `PTSettings` (UserDefaults). Claves en
  `pt_visionos.h`. Tabla de preajustes duplicada en `xr_host_visionos.mm` (`kPresets`) y
  `PTSettings.swift` (`defaults(for:)`): mantener iguales.
- `visionos/core/pt_visionos_settings.h`: `HeadsetSettings` + funciones compartidas main.cpp/.mm.
- Mandos: cualquier `GCExtendedGamepad` (DualSense, DS4, Xbox, Switch…) + Sense. Cruceta y L1/R1
  añadidos a `pt_vp_controller`/`xr::ControllerState`/`VrPlay::ApplyControls`. Glifos según mando
  (`prompt_style`: 0 Xbox, 1 PlayStation, 2 Nintendo).
- Manos (seguimiento de manos): `HandTracking.swift` (ARKit `HandTrackingProvider`, pide permiso)
  → `pt_vp_set_hand` (nudillo índice, puntas pulgar/índice, muñeca). En `Host::SyncActions`, con
  menú abierto (`Host::SetPointerWanted`, desde `VrPlay`): rayo desde el nudillo, dirección
  hombro estimado→nudillo (suavizado 0.35), pellizco <1.5 cm (suelta >3 cm) = clic en el panel
  donde apunta. Puntero en píxeles del HUD (1920×1080) → `InputState.pointer/click` → menús.
  Dibujo en `ComposeFrame`: láser (tira orientada a cámara, `laser_vertex/laser_fragment`) y
  cursor anillo (relleno al pellizcar) en el panel (HUD o pantalla virtual).
  Respaldo sin permiso de manos: mirada+pellizco del sistema (`layerRenderer.onSpatialEvent` →
  `pt_vp_spatial_event`); se ignora cuando hay rayos de mano o no hay menú abierto.
- 45 fps: `Host::SetFrameDivisor(2)` → en `WaitFrame`, `RepeatLastFrame` presenta el fotograma
  anterior con el `ar_device_anchor` con el que se dibujó (el compositor reproyecta).
- `main.cpp`: puntero sin `MapDisplayPoint` en visionOS; `input.EnableTouch(PT_IOS && !PT_VISIONOS)`
  (sin superposición táctil del iPad).

## Comprobación local (sin Mac)

```
python3 tools/prepare_source.py          # o --edit para editar el parche
# cabeceras en /root/deps: glm volk vma imgui stb sdl vkh(Vulkan-Headers) lua51 (clones superficiales)
clang++ -std=c++23 -fsyntax-only -w -DPT_APPLE=1 -DPT_IOS=1 -DPT_VISIONOS=1 -DVOLK_NAMESPACE -DVK_NO_PROTOTYPES \
  -include src/engine/platform/apple_host.h -DVK_USE_PLATFORM_METAL_EXT -DSDL_MAIN_HANDLED=1 ... src/main.cpp
```
Editar el parche: `prepare_source.py --edit`, tocar `build/port-src`, `git -C build/port-src diff > patches/0001-visionos-menus.patch`.

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

1. Leer el log de la build 4 y corregir errores (Swift/.mm nuevos sin compilar; riesgos: ggml/whisper con `CMAKE_SYSTEM_NAME=visionOS`; SDL3 sin
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
