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
- Build 4 (run 37793895782, run_number 7): **compila todo, incluido Swift**; falla al enlazar:
  faltaban SDL3, zlib, whisper y ggml porque FetchContent los compila en `build/deps/*-build` y
  el paso "collect" solo buscaba en `build/visionos`. Arreglo: `find` también en `build/deps`
  (sin `*-subbuild`, sin bibliotecas de test) + comprobación de `libSDL3.a libz.a libwhisper.a`.
  Además: `-DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF` y frameworks de SDL3 en `project.yml`
  (CoreMotion, CoreBluetooth, UniformTypeIdentifiers débil). Aviso inocuo: MoltenVK compilado
  para visionOS 2.5 y la app para 2.0.
- **Build 5 (run_number 8): primera build completa** → `releases/download/build-8/PTVisionPro-8.ipa`
  (76 MB; 128 shaders, voz, fuentes en la raíz del bundle; bundle `com.kdt.livecontainer`).
  Fallo detectado en revisión: `Host::CreateInstance` añadía `VK_EXT_metal_objects` (extensión
  de DISPOSITIVO) a la instancia → `vkCreateInstance` fallaría. Corregido en build 6
  (la instancia se crea tal cual la pide el motor; la extensión solo en `CreateDevice`).
- **Build 7 (run_number 10): OK** con Xcode 26.6 / SDK XROS 26.5 → `releases/download/build-10/PTVisionPro-10.ipa`.
  Avisos: `cp_frame_query_drawable` obsoleta en visionOS 26 (usar `cp_frame_query_drawables`;
  sigue funcionando).
- **Build 8 (run_number 11): OK** → `releases/download/build-11/PTVisionPro-11.ipa` (75,8 MB).
  Claves VPS4 de AstroVisionPro (`vps4FolderBookmark`, llavero `astroquest.vps4`/`folder-bookmark`)
  + `withLock` en `SenseTracking` (sin avisos de Swift). Solo quedan avisos de terceros y
  `cp_frame_query_drawable` obsoleta. Es la build recomendada para la primera prueba.
- **Build 9 (run_number 12): OK** → `releases/download/build-12/PTVisionPro-12.ipa`. Sin probar en el visor.
  - `cp_frame_query_drawables` (visionOS 26): `QueryDrawables` → `drawable` (`cp_drawable_target_built_in`)
    + `capture` (grabación de alta calidad de Reality Composer Pro); array vacío = frame cancelado,
    NO se toca (ni `end_submission`). La captura se compone igual (MetalFX reutilizado,
    `ComposeFrame(..., enlarge=false)`), con los ojos colocados por `eye_tangents` (tangentes ×k
    del ojo guardadas en `LocateViews`, válidas para cualquier proyección). Frames sin dibujo:
    `PresentBlank` (limpia a negro/lejos; antes se presentaba contenido indefinido).
  - 45 fps nativo: `cp_layer_renderer_set_minimum_frame_repeat_count(layer, divisor-1)` (visionOS
    1+): el compositor da el doble de tiempo por frame y reproyecta. Eliminado el
    `RepeatLastFrame` manual (competía con el juego en la cola de Metal).
  - Continuar tras cerrar el espacio (Digital Crown): el núcleo ya no termina al invalidarse la
    capa; espera en pausa (`space_gone`, sleep 50 ms). La app detecta `LayerRenderer.state ==
    .invalidated` en `tick` → `immersiveEnded` (mensaje + botón «Continuar en VR»). Al reabrir:
    `GameRunner.start` ve `model.running` → `pt_vp_attach_layer` → `Bridge::next_layer` →
    `PollEvents` cambia `x.layer`, `StartTracking` (sesión ARKit nueva), recentrado, repeat count.
    HandTracking se reinicia; Sense se reinicia en el siguiente tick.
  - Recentrado: `Host::TakeRecenter()` (nuevo en `xr_host.h`; OpenXR/stub → false) consumido en
    `VrPlay::ApplyControls` (`centered_ = false`). Fuentes: capa nueva, menú VR «Recentrar vista»
    (`kVpRecenter` → `pt::visionos::RequestRecenter`), salto de cabeza entre frames (>0,3 m a >4 m/s
    o >30° a >1500°/s en <150 ms: recentrado del sistema con la Digital Crown).
  - Fin con error: `pt_vp_exit_code()`; el launcher muestra la última línea `] error ` de pt.log.
    Tras terminar: botón «Cerrar la app» (`exit(0)`; el núcleo arranca una vez por proceso).
    `launcherVisible` evita abrir dos ventanas del launcher.
  - Calidad del visor (`compositorQuality`, 0 = la del sistema; 60–100 %): con foveado,
    `configuration.maxRenderQuality` y `layerRenderer.renderQuality` (visionOS 26). Se registran
    los valores por defecto del sistema ("Layer: ... system default") para calibrar. Sustituye a
    `renderQuality` (clave antigua ignorada). Selector de 60° en giro por pasos del launcher.
- **Primera prueba en el visor (build 10): cierre silencioso al cargar el pasillo.** `pt.log` llega hasta
  `stage .../pt14_hallway.fpk: 143 models...` (justo antes de cargar sus modelos), sin error, sin
  `abort`, sin `exit:` (el log se vacía línea a línea: no falta nada) → jetsam por memoria (SIGKILL)
  o fallo de acceso (SIGSEGV/SIGBUS: solo SIGABRT tenía manejador). Antes de eso todo bien: VPS4,
  datos US, layout `layered`, foveado, drawable 4493x3604, ojos 2696x2162 (0,60), MetalFX,
  sala inicial cargada, primer frame estéreo, sonido, subtítulos en español.
  Nota: `StereoRenderSize` (upstream) dibuja 3419x2353 (frustum simétrico que cubre los dos ojos,
  campos L -60 R 45 U 45 D -50) para imágenes 2696x2162: +38 % de píxeles. Candidato a optimizar
  con proyección asimétrica por ojo.
- Usuario: la app entera se cierra (no se queda colgada) y no aparece informe en Datos de análisis.
  Hipótesis principal: memoria. Objetivos de escena a 3419x2353 (~25 RGBA16F/LDR a tamaño completo en
  `scene_renderer.cpp:620-654`, ≈1 GB+, 4x lo del iPad a 1080p) + texturas del pasillo.
- **Build 11 (run_number 15): OK** → `releases/download/build-15/PTVisionPro-15.ipa`. Build 12 (run_number 16, en curso):
  solo quita la asignación de memoria con el hilo del juego suspendido en `DumpGameThread` (array fijo).
  Build 11: diagnóstico, sin cambio de comportamiento del juego:
  - Vigilante: `pt::visionos::LoopTick()` en `Host::PollEvents`/`WaitFrame`; `g_game_thread` =
    `mach_thread_self()` en `GameThread`. En `WatchMemory`: línea `alive:` cada 10 s (footprint,
    disponible, pico, segundos desde el último bucle); si el bucle lleva >10 s parado,
    `DumpGameThread` (thread_suspend + `ARM_THREAD_STATE64` + recorrido de fp con
    `vm_read_overwrite`, `dladdr` tras reanudar) → líneas `watchdog:   #i imagen +0xoff símbolo+0xoff`.
  - `InstallCrashSignals` (en `pt_vp_start`): SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP → escribe en
    `pt.log` (fd propio `O_APPEND`) "`[  crash  ] error crash: <señal> at address, pc, lr, app image at,
    thread`" + `backtrace_symbols_fd`; pila alternativa por hilo (`UseAlternateStack`, también en
    `GameThread`); luego `SIG_DFL` + `raise` (informe del sistema intacto).
  - `WatchMemory` (hilo propio, 250 ms): al empezar "memory: limit about N MB" (footprint +
    `os_proc_available_memory`; dice si la firma dio el límite ampliado); línea cada vez que el
    footprint cambia 256 MB o si quedan <600 MB; `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` → warning/CRITICAL.
  - Launcher: fondo del menú (`Core/LauncherBackground.swift`): imagen elegida por el usuario
    (Fotos o Archivos) guardada en Application Support/`launcher-background.jpg` (≤2400 px, JPEG
    0,85); si no hay, `sce_sys/pic1.png`/`pic0.png` de su copia del juego; si no, degradado.
    Sección «Fondo del menú» en Ajustes (`BackgroundSection`). Con imagen se oculta el título
    "P.T." de Inicio. **No se sube arte del juego al repo** (público, releases públicas).
  - Icono: pendiente de respuesta (propuesta: icono original, sin el logo).
- **Build 10 (run_number 13): OK** → `releases/download/build-13/PTVisionPro-13.ipa` (75,8 MB). Sin probar en el visor. Panel de rendimiento en el visor
  (`PT_VP_OVERLAY`, interruptor «Panel de rendimiento dentro del juego» que antes no hacía nada):
  línea "FPS · GPU · LOOP · ojo · térmico" con fuente 5x7 (`kGlyphs`, `RasteriseOverlay`) en dos
  texturas RGBA8 sRGB compartidas (ping-pong, cada 500 ms), quad fijo a la cabeza 0,3 m bajo el
  centro a 1 m → cambiado a 0,18 m (≈10°, nítido con foveado), textura 800×28 (65 caracteres;
  con 640 la línea más larga se cortaba), 0,75 m de ancho; no se dibuja en el drawable de captura.
- Build 7: Xcode 26 / visionOS 26 (runner `macos-26`, deployment 26.0 en
  `project.yml` y CMake). Cambios (todo sin probar en el visor):
  - Correcciones "sin ventana" en `main.cpp` (parche): sonido (`sound.Init` exigía ventana),
    juego al reloj real (`paced` y `dt` reales; antes 1 tick/bucle → velocidad ligada a los fps),
    voz (`hearing`/recognizer exigían ventana; `PT_VP_VOICE=0` la apaga), iconos de botones en
    segundo plano. Idioma de partida nueva: `PT_SYSTEM_LANGUAGE` desde `PT_VP_LANGUAGE` o
    `[NSLocale preferredLanguages]` (en Apple el juego usaba siempre en-US → sin subtítulos).
  - `Host::FocusLost()` = estado (como OpenXR), no flanco: pausa real al quitarse el visor.
  - Sombras: el ojo derecho reutiliza el atlas del izquierdo si todas las `ShadowView` son
    idénticas (`scene_frame.cpp`, `vr_shadow_views_`; log "vr: the right eye uses...").
  - MetalFX espacial por ojo (`MTLFXSpatialScaler`, perceptual, salida = píxeles cubiertos de la
    vista) si `PT_VP_METALFX` y el ojo es menor; si falla, estirado normal. Framework MetalFX.
  - Campo de visión `PT_VP_FOV` 70–100 %: tangentes ×k al juego, ojos de `vista×k×escala`, quad
    del ojo en su rectángulo NDC (resto negro). Nitidez `PT_VP_SHARPEN`: `eye_fragment` (4 vecinos,
    limitado a su rango). Tangentes de cada vista desde `cp_drawable_compute_projection`
    (`R=(1+m20)/m00`, `L=(m20-1)/m00`), sin `cp_view_get_tangents` (obsoleta).
  - Preset gráfico del juego `PT_VP_GRAPHICS` (`ApplyGraphicsPreset`) antes de sombras/SSAO/...
  - HUD premultiplicado en la composición (antes se multiplicaba dos veces por alfa).
  - `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1` y `PT_STATUS_LOG=1` en `pt_vp_start`; log
    `vr pace:` cada 10 s (GPU ambos ojos y por pasada, CPU, térmico) vía
    `pt::visionos::ReportEye`; `gpu_ms` en el panel Rendimiento.
  - PS VR2 Sense 6DoF: `Tracking/SenseTracking.swift` (`AccessoryTrackingProvider`) →
    `pt_vp_set_aim` → `controllers_.aim` (linterna en la mano) y rayo de menú (gatillo = clic,
    `l2/r2` nuevos). `NSAccessoryTrackingUsageDescription` en Info.plist.
  - Pausa con las manos: pellizco izquierdo mantenido 0,8 s sin menú y sin mando
    (`VrPlay`: `!c.active && c.menu` → Start). Un pellizco/gatillo ya mantenido al aparecer el
    rayo no hace clic.
  - Menú del juego: filas MetalFX y Campo de visión (claves `metalfx`, `fov`); presets con
    `metalfx` (M2 sí, M5 no) y `fov` 100 en `kPresets` y `PTSettings.defaults`.
  - Launcher: vuelve el interruptor MetalFX; quitados "Resolución dinámica" (no implementada).
- **Build 6 (run_number 9): OK** → `releases/download/build-9/PTVisionPro-9.ipa`. Primera prueba
  real en el visor pendiente (VPS4, detección, arranque VR, menú Vision Pro, rayo de mano, mandos).
- (Build 5:) VPS4 + arreglo de enlazado. Log completo: `git show origin/ci-logs:run-N.log`
  (`latest.log` por la API se trunca a ~900 KB).
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
python3 tools/prepare_source.py          # o --edit para editar el parche
# cabeceras en /root/deps: glm volk vma imgui stb sdl vkh(Vulkan-Headers) lua51 (clones superficiales)
# (en build/port-src; /tmp/claude-0/gen/build_id.h con #define PT_BUILD_ID "local")
clang++ -std=c++23 -fsyntax-only -w -DPT_APPLE=1 -DPT_IOS=1 -DPT_VISIONOS=1 -DVOLK_NAMESPACE -DVK_NO_PROTOTYPES \
  -DVK_USE_PLATFORM_METAL_EXT -DSDL_MAIN_HANDLED=1 -DPT_NATIVE_BUILD='"x"' -DPT_VOICE_MODEL_DIR='"v"' \
  -include src/engine/platform/apple_host.h -Isrc -I/root/PTVisionPro/visionos/core \
  -I/root/PTVisionPro/visionos/App/Bridge -I/tmp/claude-0/gen -I/root/deps/glm -I/root/deps/volk \
  -I/root/deps/vma/include -I/root/deps/imgui -I/root/deps/imgui/backends -I/root/deps/stb \
  -I/root/deps/sdl/include -I/root/deps/vkh/include -I/root/deps/lua51 src/main.cpp
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

## Pendiente (siguiente sesión, en orden)

1. Primera prueba en el visor (build 8): ver estéreo. Comprobar orientación de los ejes (ARKit es Y arriba,
   -Z adelante, igual que OpenXR; si la imagen sale girada revisar `QuatOf`/tangentes) y la
   altura (ARKit origen en el suelo; `VrPlay` recentra en la cabeza).
2. Profundidad real al drawable (hoy constante "lejos"): mejora la reproyección a 45 fps.
3. Resolución dinámica (el renderer recrea objetivos al cambiar de tamaño: hacerlo con viewport).
4. Calibrar presets M2/M5 con las líneas `vr pace:` del registro.
6. Comprobación de datos en el launcher: hecha (chunk1.psarc, texture.qar); probar con los datos reales.
