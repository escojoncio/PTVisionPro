# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad`
(submódulo; pinea `pt-pc` 5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de
visionOS sobre `build/port-src` (+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK
(con `patches/moltenvk/0001-rasterization-rate-map.patch` y `0002-metal-encode-command.patch`).

## Estado (última build: 48, sonda TBDR, `releases/download/build-48/PTVisionPro-48.ipa`; pendiente el log del usuario)

- Juego completo jugable de principio a fin (log pt (27), build 42). Sin cierres desde la build 14.
- Ajustes de referencia del usuario (por debajo "se ve borroso"): imagen 50 %, zona nítida 70° al 100 % (1158x1158/ojo),
  altura -10°, periferia 10 %, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps. Rendimiento con ellos
  (build 42): 45 fps al inicio, 25–35 en el pasillo (GPU 30–40 ms, picos 48). Coste: inset lighting 3,2–3,6 ms/ojo,
  inset gbuffer 1,4–2,1, inset compose 1,9, bloom ancho 1,4 (antes de compartirlo), sombras hasta 3,5–6 ms/frame.
- **Build 44 (log pt (28)): imágenes fantasma** muy molestas. MetalFX temporal funciona (encontrado en tiempo de ejecución;
  1044→1392, 2,7 ms/inset) y la profundidad al compositor está activa (composición 1,2 → 3,2 ms). Sin aislar cuál causa los
  fantasmas: pedido al usuario probar en el menú "Profundidad para la reproyección" off y luego AA = FXAA.
  Esa partida iba con M2 al 60 % (zona 1392), no comparable en fps.
- El usuario siempre elige el preajuste M2 esperando sus ajustes → hecho en el commit 12bd8f9 (sin build aún).

## Pendiente (en orden)

1. **Build 45: opción «Alineación de MetalFX»** (`HeadsetSettings::aa_jitter`, menú VR → Foveado y nitidez, `kVpAaJitter`;
   Swift `aaJitter`/`metalFXAlignment`, env `PT_VP_AA_JITTER`): 0 Apple (jitter negado al scaler, por defecto), 1 como DLSS/FSR
   (lo de la build 44), 2 sin jitter (`SceneRenderer::SetVrNoJitter`, `scene_upscale.cpp`). Cambiar reinicia las historias
   (`restart_` en `metalfx_upscaler.mm`). Motivo: log pt (29): con FXAA (profundidad on) no hay fantasmas → la causa es MetalFX,
   no la profundidad; `depthReversed` ya estaba a YES. Pedido al usuario: probar 0, 1 y 2 con MetalFX y decir cuál quita la sombra.
   Si ninguno: revisar vectores de movimiento (signo/`motion_scale`) y la colocación del inset en la composición.
   **Resultado build 45 (log pt (30)):** los 3 modos de jitter igual de mal → no es el jitter.
   **Build 46 (log pt (32)):** «Sin separar la linterna» quita el fantasma → causa: `handy_demod_` (factor de la linterna a
   resolución de render remultiplicado sobre la imagen de MetalFX a tamaño completo = halos en bordes). Queda otro fallo:
   con MetalFX (también al 100 %, sin reescalar) la estereoscopia se ve «más separada» que con FXAA.
   **Build 47:** `handy_demod_` desactivado siempre en VR (`scene_upscale.cpp`, `!VrView()`). «Prueba de MetalFX» opción 3 ahora
   «Mismo camino, sin MetalFX» (`SetVrUpscaleBypass`: el resolve estira el render en vez de usar la salida de MetalFX).
   Si con ella sigue la separación → fallo en el camino del upscaler (post_view_, resolve, depth/offset); si no → en MetalFX.
   **Resultado build 47 (log pt (33)):** fantasma resuelto. «Mismo camino, sin MetalFX» quita la separación estéreo → la causa
   está en la propia salida de MetalFX (no en nuestro camino). Sin ganancia de fps. **Decisión:** MetalFX aparcado (usar FXAA);
   siguiente paso = build sonda TBDR (punto 3). Pendiente menor: poner FXAA por defecto en el preset M2 y en `PTSettings`.
   Después de la sonda, dentro de la reestructuración del posproceso (orden acordado con el usuario):
   (1) **SMAA** en la zona nítida en lugar de FXAA (más nítido, <1 ms/inset, sin historial → sin riesgo estéreo; 1 build).
   (2) **TAA propio** con afilado final (tipo CAS) en el camino del resolve (ya alineado en estéreo; reutiliza jitter y
   vectores de movimiento; rechazo de historial por vecindad/profundidad, cuidado con la linterna), como opción de menú
   «Antialiasing: FXAA / SMAA / TAA» para comparar en el visor. Prever 2–3 builds de ajuste (estelas/borrosidad).
   Con MetalFX 67 % (776→1158): 40 fps, GPU 21 ms; `inset/upscale` 2,2 ms/inset.
2. (Incluido en la build 45 el preajuste M2 del commit 12bd8f9.)
3. **Build 48: sonda TBDR** (`visionos/core/tbdr_probe.mm`, nuevo; shaders `shaders/tbdr_probe*.{vert,frag,glsl}` en el parche;
   `prepare_source.py` lo añade a `pt_visionos`; llamada `pt::visionos::RunTbdrProbe` al final de `Host::StartSession`, con el
   keeper ya presentando; `PT_VP_TBDR_PROBE=0` la apaga). 1384², G-buffer del motor (+ profundidad R32F), 3 capas de overdraw,
   16 luces aditivas, composición; 8 frames por command buffer, 5 rondas + calentamiento. Orden: A (Vulkan pasadas separadas),
   M1 (Metal encoders separados), M2 (Metal un encoder + memoryless + `[[color(n)]]`) intercalados → log; después B (Vulkan
   1 render pass, 3 subpasadas, input attachments, adjuntos TRANSIENT + LAZILY_ALLOCATED) intercalada con A' (B al final por
   riesgo de fallo de MoltenVK). Tiempos: reloj GPU del MTLCommandBuffer (Vulkan vía `vkCmdEncodeMetalMVK` + completed handler),
   timestamps Vulkan y wall. Log: líneas `tbdr:` (storageMode de los adjuntos de B, ms/frame, 4 píxeles por variante,
   `verdict ...`). Leer: si B ≈ A o píxeles distintos → MoltenVK no sirve para TBDR; si M2 ≪ A → la vía es Metal nativo
   (en PTVisionPro vía `vkCmdEncodeMetalMVK` o en el traductor de VPEngine); si M2 ≈ A → el cuello no es ancho de banda.
   Comprobado en local: glslang (shaders), clang -fsyntax-only con Metal simulado (.mm); MSL solo revisado a mano.
   **Plan TBDR (contexto de la sonda).** Diagnóstico: 11 draws por vista y 28–37 ms de GPU
   → coste en pasadas de pantalla completa y ancho de banda (G-buffer escrito/leído de memoria en cada pasada, ×4 vistas).
   Plan: (a) build sonda: microbenchmark al arrancar a 1384² con el formato del G-buffer del motor, 3 variantes con
   timestamps GPU: pasadas separadas (actual) / una render pass Vulkan con subpasadas + input attachments + adjuntos
   transitorios (LAZILY_ALLOCATED) / Metal nativo en un solo `MTLRenderCommandEncoder` con texturas `memoryless` y
   programmable blending vía `vkCmdEncodeMetalMVK`. Loguear ms de cada una y `storageMode` real de los adjuntos
   (`vkGetMTLTextureMVK`) y si MoltenVK abre un encoder por subpasada. (b) Según el resultado: G-buffer+luz+compose
   en memoria de teselas, posproceso en una pasada (bloom corto), multiview. Estimación: −9–12 ms GPU (30–40 %).
   Si ni Vulkan ni Metal nativo ganan, el usuario plantea pasar a VPEngine.
4. MetalFX no da fps aún (2,7 ms/inset ≈ lo ahorrado): medir con 67 %, o TAA propio más barato.
5. Comprobar en el visor: X como zoom (mirilla, reloj), X en la marca del cuadro, subtítulos (tamaño/altura).
6. Rendimiento: bloom con menos pasadas (41 pasadas casi de coste fijo), sombras (3,5–6 ms/frame en el pasillo),
   inset lighting (luces por teselas).
7. 45→90 de verdad (spacewarp propio con vectores de movimiento) si la reproyección con profundidad convence.

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
- **AA de la zona nítida** (`HeadsetSettings.aa`, def. 3): 0 FXAA; 1–4 MetalFX temporal 100/85/75/67 % (`AaScale`).
  `metalfx_upscaler.mm`: `UpscalerKind::MetalFx`, clase por `NSClassFromString` + `objc_msgSend` (el SDK de visionOS la
  marca no disponible), un scaler por vista, encode dentro del command buffer de Vulkan con `vkCmdEncodeMetalMVK`
  (parche MoltenVK 0002). Motor: historia por vista (`vr_last_camera_[4]`, `vr_jitter_index_[4]`, `vr_reset_[4]`,
  objetos avanzan en la vista 0), anchas sin reescalado (`VrSkipsUpscale`), SSR/espejo temporal off en VR.
  Si falla: `aa = 0` en la sesión (main.cpp).
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

