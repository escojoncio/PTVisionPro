# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad`
(submódulo; pinea `pt-pc` 5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de
visionOS sobre `build/port-src` (+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK
(con `patches/moltenvk/0001-rasterization-rate-map.patch` y `0002-metal-encode-command.patch`).

## Estado (última build lanzada: 53; última probada: 51)

- Juego completo jugable de principio a fin (build 42). Sin cierres desde la build 14.
- Ajustes del usuario = preset M2: imagen 50 %, centro 60° al 100 %, altura -10°, periferia 10 %, VPKTAA 80 %, nitidez 100,
  VPKTAA en periferia, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps.
- Referencia build 50 (pasillo, 765→956): GPU total ~6,6–7,5 ms; inset/lighting/lights 1,4–1,7; wide/shadows 1,4–1,8.
- AA: MetalFX, SMAA, TBDR descartados y borrados; FXAA solo para comparar.

## Build 51 (probada, log pt (38)) → build 52

- Se quedan: destellos de lámparas en estéreo (`vfx::SetFlareStereo`, `vfx_particle.vert`), sombras con caché de esqueletos
  quietos + profundidad estática por tesela (`shadow_static_[4]`; wide/shadows bajó a ~1,0 ms), recorte CPU de luces por
  cono de tesela (`RecordLighting`), bloom de una pasada por ronda (`kawase_sum.frag`, `PT_BLOOM_PASSES`), post fusionado
  (`PT_POST_FUSE=0` lo separa).
- **Regresión de la 51**: luces ×2 (inset/lighting/lights 2,9–3,3 ms; total 8–9 ms). Causa: `lighting.glsl` con lecturas
  campo a campo + `PT_LIGHT_SURFACE_CONSTANTS` (globales y `g_pcf_taps[4]` en `light_all.frag`: presión de registros en
  Metal). Build 52: `lighting.glsl`, `light_main.glsl`, `light_all.frag`, `upscale_demod.frag` devueltos a los de la 50
  (Light por valor). NO repetir ese enfoque.
- Usuario notó más aliasing en la 51 con mismos ajustes: único cambio de AA = gathers de profundidad → build 52
  `DEPTH_GATHER 0` en `vpktaa.frag` (9 fetches, como la 50).

## Build 53: icono y arte del launcher

- Icono: `visionos/App/Assets.xcassets/AppIcon.solidimagestack` (Back = captura del pasillo con la puerta, 1024 opaca;
  Front = puerta + lámpara con máscara suave, paralaje); `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` en project.yml.
- Launcher (`LauncherBackground.swift`): busca `sce_sys` sin distinguir mayúsculas, carga `icon0` (junto al título en
  `HomeView`) y `pic1/pic0` de fondo; registra en `Registros/app.txt` qué hay en sce_sys. Sin nada: `LauncherArt`
  (la misma captura, en el bundle). La 51 mostraba el launcher vacío: ver en app.txt por qué no cargó sce_sys.

## Rama `pt-1.0.5` (sin build todavía): juego de pt-pc 1.0.5 sobre el port

- `patches/0002-pt-1.0.5-update.patch` (binario: `git diff --binary`, os.cpp lleva NUL) va tras 0001. Regenerar: árbol de
  `prepare_source.py` sin 0002 → commit → copiar el árbol final → `git diff --cached --binary HEAD`.
- Traído de upstream (5c63078→v1.0.5): lógica de juego, audio, voz, fs, core, anim; nuevos sound_captions, gyro,
  controller_feedback, spatial_output, json, device_start, boot_timing, sdl_diag, gltf_model, mod_level, parallel_for,
  game_plus_intercom*, lisa_date/* (compila; Backdrop/SetDateResolve son no-ops en `scene_renderer.h`).
- Revertidos a los nuestros (dependen de gpu::/UI nueva): game_ui, options_menu, pc_settings_page, uif_view, demo_ui,
  photo_panel, archive*, museum_layout, ui_assets (+`FontCovering` inline), ui_icons, model_cache (+StageScope/AddStageRef
  no-op), ftex, enhanced_textures, texture_cache.cpp, input_script.cpp. game.cpp: `ReleaseUnusedAssets` y
  `VideoMemoryTight` no liberan (memoria unificada), `BackfillArchive` vacío.
- Portado a mano: decals ordenadas por capa y sin depth bias (`PT_DECAL_LAYERS=0`, `PT_DECAL_BIAS=1` revierten),
  `SubMesh::layer`; NaN fuera de `luminance.comp`.
- Voz: whisper estático conservado (`PT_STATIC_WHISPER` en LoadRuntime); `OpenAsync` en main.cpp; L2+R2 = Jack
  (`xr::ControllerState::l2/r2`, `.mm` SyncActions copia l2/r2, `vr_play` flanco `voice_chord_previous_`). Segundo modelo
  ggml-small.en (rescue=4) no incluido: degrada con un LogWarn.
- HDR: `shaders/vr_hdr.glsl` `VrHdrAlpha` (ganancia por canal máx, hombro Hermite, sin realce si se ve oscuro) en
  tonemap/screen_fx; `xr_copy.frag` `DecodeOut` gamma 2.2 con HDR (`params.w` en `CopyToXr`): sombras más oscuras.
- Launcher: pestaña `Views/HowToPlayView.swift` (Cómo jugar), en `LauncherView.swift`.
- Fuera: corte a negro del falso crash (para presentar, imposible en VR), DoF de la sangre de la nevera, path tracing,
  crash AMD de vfx gpu::, FilePrefetch, Museo/modo foto nuevos.
- Comprobado sin Mac: todos los .cpp compilan a objeto y enlazan (nm), todos los shaders compilan.

- Builds 54–56 fallidas (CI): 54 `posix_spawn_file_actions_addchdir_np`/fork no existen en visionOS → `os.cpp`
  `StartDetached` y `ChildProcess::Start` devuelven false con `PT_IOS`; 55 `ggml-backend-impl.h` → incluido solo sin
  `PT_STATIC_WHISPER`; 56 link: `texture_cache.h` 1.0.5 con `.cpp` antiguo → `texture_cache.cpp` de 1.0.5 + `rgbcx.cpp` en
  `pt_bc7enc` (Dependencies.cmake). Lección: los símbolos "esperados" sin definir hay que comprobarlos uno a uno.
- Idioma del juego: `PTSettings.gameLanguage` → `PT_VP_SUBTITLE_LANGUAGE` (0–13 | off); `Game::ApplyLauncherLanguage`
  tras `RequestLoad` (una vez por proceso) pisa el idioma del guardado; `UiTextLanguage` en main.cpp (cs/pl → menús en inglés).
- 1.0.6 (up/main, tag local `v105-merged` = 1.0.5): mirilla (look con roll, centro en `PeepholeTransform`), demo
  `gc_p00_010`, pausa del paso 7 con `LoopReloadPending`, `BrowseLoop` desde el primer menú, `outro_input.h`. Fuera:
  sonda de CPU de voz, altavoz DS4, RT/gpu::, UI/actualizador.
- Museo nuevo: DESCARTADO por el usuario. Estudio: lógica (archive*, museum_music) compila; requeriría ~12 ficheros y
  ~600 líneas de main.cpp. Fallo latente: el teatro del museo en VR usa la cámara de la cabeza (`ScreenMode` usa el juego
  principal, no `theater->Sandbox()`); arreglo barato = forzar pantalla virtual con teatro activo.

## Pendiente (en orden)

1. Log build 52: confirmar luces ≈ build 50 y sombras ≈ build 51; si sigue el aliasing, mirar destellos/post fusionado
   (`PT_POST_FUSE=0`) y pesos separables del VPKTAA.
2. Afinar constantes de `vpktaa.frag` (KEEP_*, SIGMA_*, DISOCCLUSION, afilado) con lo que vea el usuario.
3. Conocido menor: `taa_valid_` no caduca si una vista se salta frames con otra vista en la misma columna (raro).
4. Comprobar en el visor: X como zoom, X en la marca del cuadro, subtítulos, destellos de apliques.
5. 45→90 de verdad (spacewarp propio) si la reproyección con profundidad convence.

## Funciones vigentes (dónde está cada cosa)

- **Host** `visionos/core/xr_host_visionos.mm`: `pt::xr::Host` sobre Compositor Services + ARKit. Composición Metal propia
  en la cola de MoltenVK; HDR nativo (EDR, P3, ganancia en el alfa); keeper de fotogramas durante cargas (visionOS mata la
  app a los 2 s sin frames); recentrado; manos (rayo + pellizco) y mirada+pellizco; panel de rendimiento; vigilante de
  memoria/bucle y manejadores de crash al log; medición de Hz (`vr: the display refreshes at N Hz`).
- **Foveado del juego (quad views)**: 4 vistas por frame (ancha izq., inset izq., ancha der., inset der.; `kInsetOrder`).
  Anchas a `periphery` % (`SetVrLowDetail`: sin SSR/SSS), insets = círculo de `center_deg` grados a `center_up`,
  densidad `center_res` (`VrPlay::PrepareInsets`, `Host::InsetWanted`), dos juegos de objetivos (`UseTargetSet`).
  Compartido: sombras (atlas estable + caché de teselas), exposición (vista 0), partículas (ancha → inset),
  bloom (uno por frame: `SetVrBloomShare`, `Stereo::bloom_place`; `PT_BLOOM_PER_EYE=1` lo desactiva).
  Composición: `inset_fragment` (círculo con fundido 15 %, aro rojo opcional).
- **AA del visor** (`HeadsetSettings.aa`, def. 5): 5 VPKTAA (`vpktaa.frag`, ver build 50), 0 FXAA (post, sin upscaler).
  Motor: historia por vista (`vr_last_camera_[4]`, `vr_jitter_index_[4]`, `vr_reset_[4]`, objetos avanzan en la vista 0),
  SSR/espejo temporal off en VR. Sin pipeline VPKTAA: `aa = 0` en la sesión (main.cpp).
- **Profundidad al compositor** (`scene_depth`, def. sí): imágenes R32F gemelas de ojos/insets (`CreateDepthImages`),
  `xr_depth.frag` (`RecordVrDepth`) escribe distancias; composición `[[depth(any)]]` vía `SceneDepth`.
- **45 fps**: `SetFrameDivisor(2)` + `cp_layer_renderer_set_minimum_frame_repeat_count`; la app no puede elegir los Hz.
- **Controles VR**: cualquier `GCExtendedGamepad`; X también es R3 (zoom) salvo con menú; marca del cuadro acepta X
  (`kGougeButtons`); `InViewNdc` área ×1,5 (máx 0,95). Linterna solo en la cabeza (Sense eliminado).
- **Subtítulos**: `GameUi::subtitle_scale/subtitle_lift` (main.cpp por HUD estéreo), `subtitle_size` 100–250 (def. 175),
  `subtitle_height` 0–40 % (def. 20).
- **Escenas** inmersivas desde la cámara de la escena (`cutscene_`), mirilla en pantalla virtual.
- **Ajustes y menús**: página VISION PRO (preajuste, 90 reales / 45 reproyectados a 90, profundidad, imagen, campo de visión,
  resolución dinámica, HDR, enlaces); página VR (giro, recentrar, subtítulos | sección "Foveado y nitidez": foveado Apple,
  foveado del juego, ancho, altura, nitidez zona, periferia, borde, AA). Textos en `pc_settings.cpp`. Sincronía menú →
  `SettingChanged` → `GameRunner.settingFromGame` → `PTSettings` (UserDefaults). Presets duplicados en `kPresets` (.mm) y
  `PTSettings.defaults(for:)`: mantener iguales (incluyen foveado). M5 solo seleccionable en un M5.
  Las filas del foveado llaman `HeadsetCustom()`.
- Diagnóstico en el log: `vr pace` (cada 10 s), `gpu labels` (`PT_GPU_LABELS`), `cull`, `shadows`, `alive`, `where:`.

## Descartado (no repetir)

- Resolución dinámica como solución (borrón inaceptable). Bajar la resolución base por debajo de los ajustes de referencia.
- VRR de Metal (rate map en las pasadas de MoltenVK, builds 31–34): sin ganancia, cuadrados al girar; código apagado
  (`PT_VP_VRR=1`). Luces en una pasada (`light_all`, `PT_LIGHT_ONE_PASS=1`): peor en el pasillo.
- MetalFX espacial sobre el ojo entero (6,7 ms de composición, −10 fps). Máscara del centro en las vistas anchas.
- Quitar reflejos o bajar sombras (el usuario no lo acepta). Ritmo fijo como sustituto de rendimiento real.
- Historial detallado de builds 3–42: en el historial de git (`git log -- bitacora.md`).

## Datos y partidas: carpeta VPS4 (compartida con AstroVisionPro)

- `visionos/App/Core/VPS4Folder.swift`: carpeta `VPS4` creada por el usuario en la raíz de
  "En mi Apple Vision Pro". `.fileImporter` de carpeta (`HomeView`, botón «Elegir VPS4»; rechaza
  otro nombre) → `startAccessingSecurityScopedResource` + bookmark en UserDefaults
  (`vps4FolderBookmark`) y llavero (servicio `astroquest.vps4`, cuenta `folder-bookmark`):
  **las de AstroVisionPro** (`visionos/App/Core/GameFolder.swift` allí, commit 5f23d03); mismo bundle
  ID `com.kdt.livecontainer` → mismo contenedor/llavero → una sola elección sirve a las dos apps.
  También crea `Cachés` (de AstroVisionPro). `Partidas/` raíz es el home de shadPS4; P.T. usa
  `Partidas/CUSA01127`. Si el
  bookmark no resuelve (p. ej. tras reinstalar) se vuelve a pedir. Crea `Juegos` y `Partidas`.
- Juego: `GameData.find` busca `VPS4/Juegos/CUSA01127`, otras carpetas de `VPS4/Juegos`,
  `VPS4/CUSA01127`, y después Documents (respaldo). Versión por tamaño exacto (`knownSizes`:
  chunk1.psarc 421978112, texture.qar 892291044 = US v01.00); otro tamaño → aviso, se puede jugar.
- Partidas: `GameRunner` pasa `--save-dir VPS4/Partidas/CUSA01127` (el juego guarda
  `PT_Save_Data*` ahí). Sin VPS4: dentro de la app (por defecto del port).
- `main.cpp` (`#if PT_VISIONOS`): sin la instalación verificada por manifiesto del iPad
  (`pt::assets::VerifyInstallation` exigía `pt-ipad-assets-v1` y rechazaba ficheros extra como
  `sce_sys`); exige `--game` válido (`LooksLikeGameDir`).
- Log del juego: `pt_vp_start` añade `--log Documents/pt.log` (antes iba a Application
  Support y la pestaña Registro no lo veía).

## CI: cachés

- `actions/cache/restore` + `actions/cache/save` manuales: MoltenVK se guarda nada más
  compilarse (`tools/build_visionos.sh --moltenvk-only`), deps+voz con `if: always()`. Antes
  `actions/cache` solo guardaba si todo el job salía bien (builds 3 y 4 recompilaron MoltenVK).

## Comprobación local (sin Mac)

```
python3 tools/prepare_source.py --edit   # árbol editable en build/port-src (cambios del parche sin commitear)
# cabeceras en /root/deps: glm volk vma imgui stb sdl vkh(Vulkan-Headers) lua51 (LuaDist, luaconf.h desde .orig)
# /tmp/claude-0/gen/build_id.h con #define PT_BUILD_ID "local"
clang++ -std=c++23 -fsyntax-only -w -DPT_APPLE=1 -DPT_IOS=1 -DPT_VISIONOS=1 -DPT_GAMEPLUS=0 -DVOLK_NAMESPACE \
  -DVK_NO_PROTOTYPES -DVK_USE_PLATFORM_METAL_EXT -DSDL_MAIN_HANDLED=1 -DPT_NATIVE_BUILD='"x"' -DPT_VOICE_MODEL_DIR='"v"' \
  -include src/engine/platform/apple_host.h -Isrc -I<repo>/visionos/core -I<repo>/visionos/App/Bridge \
  -I/tmp/claude-0/gen -I/root/deps/glm -I/root/deps/volk -I/root/deps/vma/include -I/root/deps/imgui \
  -I/root/deps/imgui/backends -I/root/deps/stb -I/root/deps/sdl/include -I/root/deps/vkh/include -I/root/deps/lua51/src FILE
```
- Shaders: glslang compilado desde fuente (`glslang -V --target-env vulkan1.2 -I. --P "#extension GL_GOOGLE_include_directive : require"`).
- `.mm`: `clang++ -x objective-c++ -fobjc-runtime=macosx-14.0 -fobjc-arc` con cabeceras de Foundation/Metal/objc simuladas.
- Regenerar el parche SIEMPRE desde el árbol `--edit`: `git add -N shaders/light_all.frag shaders/xr_depth.frag && git diff >
  patches/0001-visionos-menus.patch` (sin `add -N` se pierden los ficheros nuevos). Comprobar con `prepare_source.py`.
- CI: solo con `[build]` o dispatch; logs en la rama `ci-logs` (`gh api "repos/escojoncio/PTVisionPro/contents/latest.log?ref=ci-logs"
  --jq .content | base64 -d`); releases por REST (`gh api repos/escojoncio/PTVisionPro/releases?per_page=1`); GraphQL bloqueado.

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
- `tools/build_visionos.sh`: MoltenVK `./fetchDependencies --visionos && make visionos` (commit de `source-lock.json`), modelos de voz
  (sha256 del dependency-lock), cmake `-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros`,
  recoge `*.a` en `build/visionos/lib`, recursos en `visionos/Resources/{shaders,voice,fonts,
  licenses}`, `PT_LINK_FLAGS` = lista de archivos .a (dos veces), xcodegen + xcodebuild sin
  firma → `build/visionos/ipa/PTVisionPro-N.ipa`.
- `.github/workflows/visionos.yml`: macos-26 (Xcode 26.6), solo `workflow_dispatch` o commit con `[build]`;
  cachés MoltenVK (clave: source-lock) y deps+voz (clave: dependency-lock); artefacto IPA +
  pre-release `build-N`.
- `visionos/App/*`: launcher SwiftUI (presets M2/M5/Personalizado en `PTSettings.swift`,
  detección por `hw.machine` RealityDevice14 → M2), `GameRunner.swift`, `PlayStationController.swift`,
  vistas Inicio/Ajustes/Rendimiento/Registro, `pt_visionos.h` (API C). Bundle id
  `com.kdt.livecontainer`. Recursos del juego como carpetas en la raíz del bundle
  (`ExecutableDir()/shaders` etc.).

