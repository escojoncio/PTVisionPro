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
- **Prueba build 12 (preset M2): mismo cierre al cargar el pasillo.** Límite real 8191 MB (la firma
  conserva increased-memory-limit); al morir footprint 3040 MB, disponible 5151 MB; sin presión de
  memoria, sin señal capturada, muerte antes de 10 s → no es memoria. Sospecha: `abort()`/
  `std::terminate` (el juego solo los registra en Windows: `InstallCrashReporting` va bajo
  `#ifdef _WIN32` en `main.cpp`) o `exit()`.
- **Build 13 (run_number 17): OK** → `releases/download/build-17/PTVisionPro-17.ipa` (75,9 MB; probada: se cierra al cargar el pasillo, ver abajo). Sin probar en el visor.
  Hipótesis a contrastar con su log: el pasillo carga 143 modelos + texturas en el hilo del juego
  (`StageManager::Load` → `models_.Get` → `TextureManager::Create`, subida síncrona), que es el mismo
  que presenta frames al compositor → varios segundos sin `cp_frame` → posible cierre del espacio
  inmersivo por el sistema. Descartado `FatalError` (escribe `fatal:` antes de `_Exit`; no aparece).
  Si las últimas `where:` muestran el bucle ocupado en la carga sin línea de crash/exit → presentar
  frames (último frame reproyectado o fondo de carga) desde otro hilo mientras el bucle está parado.
  `InstallCrashSignals` añade SIGABRT, `std::set_terminate`
  (mensaje de la excepción + abort → pila del que lanzó) y `std::atexit` (pila de quien llama a exit).
  Vigilante cada 100 ms, umbral 128 MB; mientras el bucle lleva >0,5 s parado, cada 0,5 s una línea
  `where: loop X s busy, game thread at +0x... +0x...` (offsets en la imagen de la app).
  Simbolizar: el binario de la IPA conserva la tabla de símbolos →
  `unzip PTVisionPro-N.ipa Payload/PTVisionPro.app/PTVisionPro`, luego
  `llvm-symbolizer --obj=PTVisionPro 0x1<offset>` (dirección = 0x100000000 + offset) o `llvm-nm -C -n`.
- **Prueba build 13: causa encontrada.** Sin crash/abort/exit; memoria 3023 MB de 8191. Últimas `where:`
  (simbolizadas con `llvm-nm -n` del binario de la IPA; `llvm-symbolizer` no resuelve) = carga normal del
  pasillo en el hilo del juego: `Game::Update → StageManager::Update → LoadStage → Load → ModelCache::Load →
  BuildMaterial → TextureManager::LoadFox → LoadFtex → uncompress` y luego `Surfaces → BuildSurfaces → LoadFmdl`;
  bucle >1,1 s sin dibujar y fin. **visionOS mata (SIGKILL, no capturable, motivo 0x27) una app inmersiva que
  pasa 2,0 s sin enviar fotogramas** (mensaje de sistema "hasn't been sending frames for 2.0s"; mismo caso
  documentado en Unity para cargas y compilación de shaders). En `VrPlay::BeginLoop` el juego abre el frame
  (WaitFrame+BeginFrame) ANTES de su update, así que la carga ocurre con un frame abierto.
- **Prueba build 14: el juego ya se juega** (keeper cubre cargas de 1,9 s y 0,3 s; menús, ajustes en vivo y
  botones con las manos OK). Problemas: (1) ojo derecho deforme (juego y pantalla virtual); (2) 11 fps:
  GPU 85 ms ambos ojos a 3419x2353 por ojo (sombras 11 solo izq.; por ojo: gbuffer 6, lighting 13, compose 13,
  post 5); gráficos al máximo solo −2 fps → limitado por píxeles; (3) escenas en pantalla virtual (2,8 m a
  2,5 m, `kScreenWidth/kScreenDistance` en `vr_play.cpp`) se ven pequeñas; (4) tras «Terminar partida» quedaba
  el mensaje de pausa sin botón «Continuar».
- **Build 15 (run_number 19): OK** → `releases/download/build-19/PTVisionPro-19.ipa`. Sin probar en el visor:
  - Ojo derecho: en layout `layered` hay UNA textura array (slice por ojo) y su `MTLRasterizationRateMap` tiene
    una capa por slice; una pasada por vista con `slice` fijo y sin array usaba la capa 0 (ojo izq.) para los
    dos ojos. Ahora `ComposeFrame` hace una pasada por textura del drawable (`renderTargetArrayLength` =
    `arrayLength`, 1 si 2D), `setViewports` con las vistas de esa textura, y cada draw elige slice y viewport
    con `Uniforms.target` (`uint4`, al final del struct en MSL y C++) → `[[render_target_array_index]]` /
    `[[viewport_array_index]]` en los tres vertex shaders. Pipelines con `inputPrimitiveTopology = Triangle`.
    Log único al empezar: `vr: drawable N view(s), N texture(s) (array, N slice(s)), N foveation map(s) of N layer(s)`.
  - Launcher: `AppModel.gameEnded` borra solo `pausedMessage` (estático); el resto de mensajes se mantiene.
- **Prueba build 16:** estéreo y escenas inmersivas OK. Problemas: tras la escena inicial el jugador mira al
  revés; reflejos "bamboleantes"; el tamaño de imagen del menú no cambiaba nada (ojos 2696x2162 y render
  3419x2353 fijos desde el inicio). GPU 97–114 ms ambos ojos (~9 fps).
- **Prueba build 17** (imagen 50 %, FOV 85 %, MetalFX off): ojos 1910x1532, render 2422x1667 (4 MP/ojo), GPU 46–56 ms
  ambos ojos (~18–22 fps), térmico serious a los 80 s. Por ojo: lighting(+SSAO) 7–11, compose+forward+efectos 6–10,
  gbuffer 2,4–5, post(+SSR) 3,3; sombras 1,5–3 (compartidas). MetalFX resta 3–4 fps. El usuario quiere los
  reflejos (SSR) aunque bailen entre ojos. Culling existente: frustum por vista para draws (`Visible`, esferas
  vs planos) y luces (frustum + volúmenes oclusores de autor, `light_cull`); sin occlusion culling de geometría
  (el gbuffer es ~10 % del coste; el coste es por píxel).
- **Prueba build 18** (M2: imagen 60 %, periferia/centro 45 %, sombras altas): R 1539x1059, 4 vistas 45–56 ms
  (~17–20 fps), térmico serious. Por vista ~10–13 ms (gbuffer 1–2, lighting 3–4, compose 3–4,7, post 2,3 ancha /
  3,4 centro). Ajuste lineal frente a build 17: ~5 ms/MP + ~2,4 ms fijos por vista (sobre todo post). Los centros
  regrababan el atlas de sombras (2,5–3,5 ms más) porque la selección de luces/sombras depende del frustum.
- **Prueba build 19:** sin mejora apreciable (18–22 fps): las sombras ya se comparten (centros 0,02 ms) pero el total
  sigue 44–55 ms GPU (4 vistas) + composición 1–1,6 ms. Por vista ~10–12 ms a 1,6 MP. Subtítulos de la radio
  desplazados a un lado (HUD con seguimiento perezoso de 20°).
- **Prueba build 20:** ~20 fps, térmico serious. Drawable 4493×3604 por ojo; vistas anchas 1213×973 en imágenes
  (render 1539×1059, 4 vistas ≈ 6,4 MP). `gpu labels` por vista: compose+forward 3,2–3,7, lighting 2,6–2,7, post 2,2–2,3,
  gbuffer 2,1–2,3, sombras 1,3 (una vez), reflections 1,0 (centros), occlusion 0,9. ≈7 ms/MP: para 45 fps hay que bajar a
  ≈3,4 ms/MP (×2). El usuario NO quiere bajar resolución (ya baja, dientes de sierra): el camino es coste por píxel.
- **Prueba build 21 (run 25):** pantalla 90 Hz (medida), 18–20 fps, GPU 47–55 ms/frame, térmico fair. El preset M2 iba a
  90 fps (preset con 90). Por vista: effects 2,3–3,0 (la más cara), lights 1,9–2,4, post 2,2 (bloom 1,4), gbuffer 1,8,
  occlusion 0,85, forward 0,7, compose 0,27, reflections 1,0 (centros), probes 0,7, shadows 1,2–1,7/frame.
- **Prueba build 22 (run 26):** bloom compartido OK (post del centro 2,2 → 0,8 ms). 23–24 fps al inicio (GPU 40–44 ms), luego
  18–19 (48–54 ms: más geometría/luces/sombras). Vibración OK (el juego la pide en sucesos y con el reloj; llega al mando).
  Pantalla 100 Hz unos segundos y luego 90. Por vista: particles 1,2–2,0 (ancha) / 1,7–2,9 (centro), lights 1,8–2,5,
  gbuffer 1,1–2,2, effects ≈ particles + composite 0,5 + copias 0,15–0,2.
- **Prueba build 23 (run 27):** 45/45: 25 fps al inicio (GPU 38 ms), 19–20 luego (48–51 ms); térmico fair → serious.
  Periferia 30 / centro 60: GPU 27 ms (34 fps). Ajuste: ≈6 ms/MP + ≈10 ms fijos por frame. Centro nítido no cambia fps
  (mismos píxeles); al usuario el 60 le da más calidad (más área nítida). Resolución dinámica: bajó a 50 % (770×530)
  para 45 fps → borrón inaceptable; queda apagada y descartada como solución. Sombras 2,3–2,9 ms/frame.
- **Prueba build 24 (run 28):** encuadre propio OK, sin artefactos reportados. 1214×974 por vista. GPU 30 ms al inicio
  (31–37 fps), 36–44 ms después (21–26 fps); térmico serious a ~2 min. Por vista: lighting 3,1–3,3 (lights 2,3–2,6),
  gbuffer 2,1–2,3, compose+forward 2,9–3,2 ancha / 1,8 centro, post 2,3 ancha (bloom 1,5) / 0,7 centro, shadows 1,4–1,8,
  occlusion 0,8, reflections 0,85 (centros). Anisotrópico 2→16x: gbuffer +~0,1 ms/vista. El usuario exige ≥4–8x:
  cambia el sombreado visible (normal maps a ángulos rasantes).
- **Prueba build 25 (run 29):** igual que 24 (30 ms inicio, 36–42 ms después). Anisotrópico 8x OK. Luces ~3 ms/vista,
  sombras hasta 3,5 ms/frame. Partida con brillo 4 (`kBrightness[4]` = 0,76 → oscurece; 7 = neutro). El patrón de
  calibración (UI) no cambiaba: el HUD no recibía el brillo.
- **Prueba build 26 (run 30):** sin fuga (footprint 2,5 GB estable). Luces en una pasada: 2,1 ms/vista al inicio pero
  5,5 ms/vista en el pasillo (volúmenes: 2,3) → descartado como defecto. HDR por expansión SDR: el usuario lo rechaza
  (quería «HDR10»; en visionOS no hay señal HDR10, solo EDR en extended linear P3 con margen ×2 → siguiente: HDR nativo
  desde `hdr_` antes del tonemap, cadena de post e imágenes de ojo a 16 bits).
- **Prueba build 27 (run 31):** luces como en 25 (2,2–3,6 ms/vista); 30 ms inicio (32 fps), 36–40 ms después.
  Sombras 1,2 ms al inicio (antes 1,7) pero solo ~1/3 de teselas reutilizadas: el hash dependía del orden de `draws_`
  (ordenado por cámara). El usuario quiere «BT.2020 y brillo HDR».
- **Build 28 (run 32): OK** (sin probar):
  - Caché de sombras: hash de casters como conjunto (suma de hashes por caster + número).
  - HDR nativo: `tonemap.frag` del juego solo recorta `IMG_HDR` en 1. `screen_fx.frag` (pasada «screen», push
    `f0.y` = pico de `SetVrHdrPeak`, `f0.z` = factor de exposición del tonemap) escribe alfa = 2 − ganancia (ganancia =
    luminancia real con caída suave hasta el pico ÷ luminancia recortada, 1..2; alfa 1 = sin ganancia). `composite.frag`
    modo 0 pasa el alfa (fundido a 1 con `fade`); `xr_copy.frag` lo copia al ojo si `params.z` (`Renderer::xr_hdr`).
    main.cpp activa ambos en la rama estéreo con `Headset().hdr`. Composición Metal: `SceneLight` = P3 × clamp(2 − a, 1, 2)
    si `grade.x > 1` (ojo e inset; sin ganancia con MetalFX). Pantalla virtual, HUD y paneles: SDR.
  - Ajuste HDR = pico nativo (100/140/170/200), por defecto 200; clave Codable nueva `nativeHdr`; textos `pc_vp_hdr*`.
  - BT.2020: no aplica (drawable extended linear P3; contenido sRGB/709; ya se convierte a P3 desde build 26).
- **Build 27 (run 31): OK**:
  - `light_all` solo con `PT_LIGHT_ONE_PASS=1`; por defecto, volúmenes (igual que build 25).
  - Caché de teselas de sombra en `RecordShadows`: clave FNV por tesela (VkImage del atlas, rect, campos de su
    `gpu::View`, bias, cull, y por caster mesh/sub/material/transform); igual que la del frame anterior en el mismo rect
    → no se redibuja; casters con skin → siempre. Cada tesela redibujada en su propia pasada con área = rect y CLEAR
    (no carga el resto del atlas). Sin teselas que redibujar: solo transición a solo lectura. `PT_SHADOW_CACHE=0` la
    desactiva. Log `shadows: N tiles kept, M drawn in the last 10 s`.
  - HDR por expansión: por defecto 100 (apagado) en `pt_visionos_settings.h`, `ApplySettings`, `PTSettings`.
- **Build 26 (run 30): OK**:
  - Luces en una pasada: `shaders/light_all.frag` (hasta 32 luces, máscaras `ids.z` dibujadas / `ids.w` con sombra, mismo
    `EvaluateLight`), pipeline `light_all_` (Additive, 2 colores, profundidad solo lectura), en `RecordLighting` para
    `view_bit == 1` sin RT/contacto ni `PT_LIGHT_DRAW_ONLY/NO_SHADOW/PT_LIGHT_VOLUMES`; si no, volúmenes como antes.
  - Brillo en el HUD: `CopyToXr` pasa el brillo también premultiplicado; `xr_copy.frag` aplica `pow(straight, 1/b)`.
  - Composición Metal (.mm): `ToDisplayP3` (sRGB lineal → P3 lineal; el drawable rgba16Float es extended linear P3) y
    `ExpandHighlights` (rodilla 0,5, pico `Headset().hdr/100` hasta 2,0 = EDR del visor) en ojo, centro y pantalla
    virtual opaca; `Uniforms.grade` (MSL y C++) vía `GameGrade()`.
  - Ajuste HDR: `HeadsetSettings.hdr` (100/140/170/200, defecto 170, fuera de presets), `PT_VP_HDR`, fila `kVpHdr`
    (`pc_vp_hdr*`), Swift `PTSettings.hdr`, Picker en Gráficos, `GameRunner` `hdr`.
  - Comprobación de shaders local: glslang compilado desde fuente en /tmp/claude-0/glslang (`b/StandAlone/glslang -V
    --target-env vulkan1.2 -I. --P "#extension GL_GOOGLE_include_directive : require" f.frag`).
- **Build 25 (run 29): OK** (sin probar): anisotrópico como ajuste del visor: `Preset.anisotropy` (M2 8, M5 16) en `kPresets`, `MatchesPreset`,
  `ApplyPreset`/`GraphicsChanged` informan `anisotropy`, `AnisotropyStep`, `PT_VP_ANISOTROPY` (por defecto 8) aplicado tras
  `ApplyGraphicsPreset` en `ApplySettings`; main.cpp: `kVpPreset` llama `textures.SetAnisotropy`, `kAnisotropy` dispara
  `GraphicsChanged`. Swift: `PTSettings.anisotropy` (defaults, apply, matches, CodingKeys, env), Picker en
  `SettingsView` (Gráficos), `GameRunner` clave `anisotropy`.
- **Build 24 (run 28): OK** → `releases/download/build-28/PTVisionPro-28.ipa` (sin probar):
  - Encuadre propio por ojo (asimétrico) en visionOS: `xr::OwnRenderSize`/`xr::OwnFrustumFor` (xr_view.h);
    `Camera::offset` (camera.h, mismo convenio que el jitter: `p[2][0] = -offset.x`, `p[2][1] = -offset.y`);
    `add_view` suma `camera.offset` a `View::jitter.xy` (PixelNdc lo deshace); `EyeCamera` copia `frustum.offset`.
    Vistas anchas 1213×973 (antes 1539×1059 con 27 % tirado). `head_frustum_` (unión simétrica al nuevo aspecto) para
    la cámara de cabeza (culling de luces/sombras, VFX).
  - Centros: simétricos en el eje del ojo, `tan_y = center·tan_y(ancha)` limitado al campo de ambos ojos;
    `Stereo::inset_share[ojo]` = (escala xy, desplazamiento zw) → `SetVrInsetShare(const glm::vec4*)`, `SharePlace()`,
    `tonemap.frag`/`vfx_composite.frag` muestrean en `0.5+(uv-0.5)·f2.xy+f2.zw`. Mismo % = misma densidad, menos ancho.
  - `reflection_depth.glsl`: filtro de profundidad según `projection_param.w == 3` (upscaler activo), no `jitter≠0`.
  - Centro nítido 30–80 % (antes 30–60): .mm `InsetWanted`/`ApplySettings`, Swift `SettingsView`, menú `kVpCenter`
    (11 valores); nota corregida (no cambia fps).
- **Build 23:**
  - Orden estéreo con insets: izquierda ancha, izquierda centro, derecha ancha, derecha centro (`kInsetOrder` en main.cpp;
    `ReportEye` con `kInsetOrder[(k+2)%4]`). El centro usa lo que acaba de dejar su vista ancha.
  - Bloom compartido sin copias: el centro usa `bloom_[2]` tal cual (`InsetShares`/`SharedByInset`/`ShareStamp` en
    scene_renderer.h; sellos `shared_bloom_frame_`, reiniciados en `SetVrInsetShare` y al empezar la vista 0;
    `SharedByInset` invalida el otro ojo). Quitado `bloom_eye_`.
  - Partículas compartidas: la ancha copia `particles_` → `particles_kept_` tras dibujar sus VFX offscreen
    (`RecordParticles`); el centro no las dibuja, copia `particles_kept_` → `particles_` (su `RecordForward` usa
    `particles_` para transparencias) y `vfx_composite.frag` las muestrea en `0.5+(uv-0.5)·f2.x` (lineal). Equivale a
    partículas a media resolución en el centro; posibles halos en bordes de objetos cercanos.
- **Build 22:**
  - Bloom compartido: los centros (vistas 2, 3) copian el bloom de la vista ancha de su ojo (`bloom_eye_[2]`, sello
    `bloom_eye_frame_` = `frame_counter_ + (vr_eye_<=0)`, se invalida al empezar la vista 0) y el tonemap lo muestrea en
    `0.5 + (uv-0.5)·scale` (`push.f2.x`, `SetVrBloomShare(stereo.inset_scale)`). −1,4 ms × 2. Contrapartida: los brillos SSR
    (solo en centros) no generan halo.
  - Subetiquetas `effects/{particles, particles/scene copy, particles composite, scene copy}`.
  - Vibración: `Host::Haptic` devuelve los motores alcanzados (C/Swift `int`/`Int32`); `VrPlay::Rumble` registra el primer
    pulso y un resumen cada 10 s; pulso de 0,08 s. Origen: canal de movimiento del audio del juego (como en PS4).
  - Preset M2 a 45 fps (`kPresets.fps`, `PTSettings.defaults`); M5 a 90.
- **Build 21:** OK (run 25)
  - Perfilador más fino: `compose and forward/{compose,forward,effects}`, `lighting/{probes,lights}`,
    `post/{bloom,flare,tonemap,fxaa,color lut,screen blur,banding,screen}` (etiquetas fuera de render pass); log hasta 40 filas.
  - Flare en el visor: la pasada de limpiar `flare_` se salta mientras nada dibuja en él (`vr_eye_ >= 0`,
    `flare_clean_`, se reinicia al recrear targets).
  - Resolución dinámica (`VrPlay::ReportGpu/DrawSize`, `Host::GpuBudgetMs`): **apagada por defecto y en los presets**;
    fila «Resolución dinámica» (`kVpDynamicRes`, clave `dynamic_resolution`) e interruptor en el launcher (clave Codable
    nueva `dynamicResolutionChosen`: la vieja se guardó a true sin hacer nada). 0,5–1 en pasos de 0,05, decisión ≥1 s,
    cambio ≥2 s (cada cambio recrea targets: tirón), presupuesto = (divisor/Hz)·0,9 − 1 ms.
  - Hz reales del visor: `MeasureRefresh` (huecos entre tiempos de presentación de `WaitFrame`, error frente a
    90/96/100/120; 120 solo en M5) → log `vr: the display refreshes at N Hz`. **Compositor Services no deja pedir la
    frecuencia** (solo `minimumFrameRepeatCount`): el modo «una cada dos» da 45 a 90 Hz o 50 a 100 Hz según el sistema.
  - Preset M5 solo en un M5: `PT_VP_DEVICE` (Swift `detectedPreset`), `HeadsetSettings::device_m5`; menú del juego con
    2 valores (M2/personalizado) sin M5; `ApplyPreset/ApplySettings` lo rebajan a M2; launcher oculta M5, `load()` pasa
    un M5 guardado a M2, `apply(preset:)` lo rechaza.
- **Build 20 (run_number 24): OK** → `releases/download/build-24/PTVisionPro-24.ipa` (sin probar):
  - HUD sin menú pegado a la cabeza (orientación completa, 1,6 m, como el panel de rendimiento): `VrPlay::Place`
    (`head_orientation_local`, `hud_orientation_`); con menú abierto, colocado en el mundo como antes. `ScreenMode`
    reinicia `menu_was_open_` en pantalla.
  - Perfilador GPU por etiquetas (`PT_GPU_LABELS`, activado en `pt_vp_start`): gancho global en `BeginLabel/EndLabel`
    (`render_util`), pool de 256 timestamps por `FrameSlot`, 1 render de cada 13 (recorre todas las vistas), nombres
    `wide/`, `inset/`, `eye/` + ruta de etiquetas anidadas; `ReadLabelTimes` registra cada 10 s
    `gpu labels (ms per view, ...)` con las 24 más caras, promediadas por tipo de vista. Ojo: en Apple los
    timestamps caen en fronteras de encoder (las etiquetas solo-compute pueden salir ~0).
- **Build 19 (run_number 23): OK** → `releases/download/build-23/PTVisionPro-23.ipa` (sin probar):
  - `SceneRenderer::SetVrCullCamera(const Camera*)`: en `PrepareFrame`, culling de luces (planos, oclusores,
    `main_cull_view_projection_`, `LightLodScales`) y `BuildShadowViews` usan la cámara de culling;
    `main_view_.planes` y `main_view_.eye` se sustituyen y se restauran tras `BuildShadowViews` (los draws siguen
    culleados por vista). main.cpp la pone para las 4 vistas: `stereo.head` retrasada 0,1 m (su frustum contiene
    los de los dos ojos). Pendiente: con espejo activo `same()` sigue fallando (índice `sv.view`, candidatos del
    espejo por vista); oclusión de luces calculada desde la cabeza (riesgo de pop en marcos de puerta).
  - Log `vr pace` añade `composition X ms` (GPU de nuestra pasada Metal, `g_composite_ms` por completion handler).
  - Presets M2 y M5: sombras altas (`kPresets`, `PTSettings.defaults`).
- **Build 18 (run_number 22): OK** → `releases/download/build-22/PTVisionPro-22.ipa` (sin probar). **Foveado del juego (*quad views*)**:
  - Por fotograma 4 renders al mismo tamaño R: vistas 0/1 = ojos (frustum unión de siempre) con imágenes de ojo a
    `periphery`% del tamaño de imagen (`SetupEyes(..., eye_factor)`, `EyeFactor(h)`); vistas 2/3 = centros:
    frustum simétrico `tan_y = center * frusta_[0].tan_y`, `tan_x = tan_y * aspect(R)`, cámara del ojo con otro
    `fov_y` (`VrPlay::PrepareInsets`, `Stereo.insets/inset_targets/inset_tangents`), copiados enteros a
    `Host::InsetSwapchain(i)` (`EnsureInsetImages(R)`, 3 imágenes por ojo, `inset_memory`). Densidad del centro =
    `periphery/center` × tamaño de imagen; píxeles ≈ 4·periphery²·S (45/45: ~2,5× menos que antes).
  - Compositor: tras el ojo, `inset_pipeline` (`eye_vertex` + `inset_fragment`, premultiplicado, fundido 12 % en
    cada borde) sobre el rectángulo de tangentes del centro. `FrameLayers.inset/inset_tangents` (L,R,U,D);
    `textures/next_image/last_index[6]` (4,5 = centros); keeper los reutiliza.
  - Motor: `SceneRenderer::SetVrLowDetail` en vistas anchas (sin SSR ni SSS; SSAO se queda); SSR vuelve en el
    resto. Sombras: la vista 0 graba el atlas, las demás lo reutilizan si las vistas de sombra coinciden.
    Exposición medida solo en la vista 0 (`RecordLuminance` y `ReadMeasurements` saltan con `vr_eye_ > 0`).
    Con 4 vistas los frame slots (2) se alternan: `ReportEye(view, views, ...)` etiqueta `(eye+2)%4`.
  - Ajustes: `HeadsetSettings.game_foveation/periphery(30–70)/center(30–60)`, `PT_VP_GAME_FOVEATION/PERIPHERY/
    CENTER`, menú VISION PRO (`kVpGameFoveation/kVpPeriphery/kVpCenter`, textos en `pc_settings.cpp`), launcher
    (`PTSettings`, `SettingsView`, `GameRunner.settingFromGame`). `InsetWanted` sigue al `eye_factor` aplicado.
    Presets: MetalFX off en ambos; M2 con SSAO y reflejos. Los presets se reaplican al cargar (`PTSettings.load`).
  - `pt::visionos::RequestRecenter` restaurada (se había perdido en la edición).
- **Build 17 (run_number 21): OK** → `releases/download/build-21/PTVisionPro-21.ipa` (la recomendada; sin probar en el visor):
  - Mirar al revés: el centrado (base del rig = yaw de la cámara, 0) ocurre antes del spawn (yaw 180) y el primer
    look de la cabeza ignoraba el rumbo del juego. `Player::SetVrReference(yaw)` (player.h, nuevo) llamado al
    centrar en `VrPlay::ApplyControls`: `vr_last_yaw_ = yaw; vr_looked_ = true` → el spawn y la cámara que
    devuelve una escena giran la vista por la ruta normal (`vr_turn_` → `TakeVrTurn` → `rig_.Turn`).
    `PrepareStereo` (rama normal) consume `TakeVrTurn` antes de las cámaras: el giro se ve en el mismo
    fotograma (queda 1 fotograma hacia atrás justo al acabar la escena: el giro se calcula en el `Update` siguiente).
  - Reflejos: `scene_frame.cpp`, con `vr_eye_ >= 0` y `PT_VISIONOS`, `toggles.local_reflections = false` (SSR
    distintos por ojo); quedan sondas y espejos. El ajuste «Reflejos» solo afecta ya a la pantalla virtual.
  - Tamaño de imagen / campo de visión / MetalFX en vivo: `SetupEyes()` en `xr_host_visionos.mm` (StartSession
    y `PollEvents` con el mutex): `vkDeviceWaitIdle` + command buffer Metal vacío esperado, destruye vistas,
    imágenes y memoria (`eye_memory[2]`), recrea imágenes y escaladores MetalFX, `have_last = false`. Espera a
    que el valor lleve 400 ms quieto (`pending_*`). Si falla, vuelve a los valores anteriores (y al menú) y solo
    termina si eso también falla. `VrPlay` recalcula `render_size_` al cambiar la extensión (`render_for_`).
    Notas del menú (`pc_settings.cpp`): «se aplica al momento». `Shutdown` libera la memoria de los ojos.
- **Build 16 (run_number 20): OK** → `releases/download/build-20/PTVisionPro-20.ipa` (la recomendada; sin probar en el visor). **Escenas inmersivas** (`vr_play.cpp/.h` en el parche; ajuste «Escenas inmersivas» en
  `PTSettings.immersiveCutscenes` → `PT_VP_CUTSCENES`, `SettingsView` sección Juego; por defecto sí):
  - `ScreenMode`: con cámara de demo y ajuste activo → `cutscene_` (estéreo), no pantalla virtual. La mirilla
    (`IsPeepholeTheaterActive`) sigue en pantalla. Log `vr: cutscene in stereo from the scene's camera`.
  - `PrepareStereo` con `cutscene_`: al entrar guarda `cutscene_ref_yaw_` (yaw de la cabeza en mundo) y
    `cutscene_entry_` (offset de la cabeza); `heading = Yaw(logic.yaw - ref)`; ojos en `logic.position` (cámara
    de la demo vía `DemoSystem::CameraOverride`) + `heading * (Offset(ojo) - entry)` con el mismo límite que en
    juego (kHeadReach/Rise/Drop) y raycast contra paredes desde la cámara; orientación `heading * ToWorld(ojo)`.
    Pitch/roll de la cámara de la demo ignorados a propósito (mareo). Recentrar reinicia la referencia.
  - `ApplyControls`: `screen = screen || cutscene_` (sin giro, stick derecho al juego, linterna de la escena).
  - Revisión: pendiente de comodidad, viñeteado/fundido en cortes de cámara (criterio de salto de
    `BlendCameras`, main.cpp:854-863).
- Comprobación local de `vr_play.cpp`: con `/root/deps/lua51` de LuaDist (rama 5.1.5) copiar
  `src/luaconf.h.orig` a `src/luaconf.h` e incluir `-I/root/deps/lua51/src`.
- **Build 14 (run_number 18): OK** → `releases/download/build-18/PTVisionPro-18.ipa` (la recomendada; sin probar en el visor). "Keeper" de fotogramas (`xr_host_visionos.mm`):
  - `Impl::mutex` + `GameCall()` (sella `game_call_ns` antes y después de bloquear) en PollEvents, WaitFrame,
    BeginFrame, LocateViews, SyncActions, Acquire, EndFrame, SetFrameDivisor. Ninguno llama a otro con guarda.
  - Hilo `KeepPresenting` (arranca al final de `StartSession`, `join` al principio de `Shutdown`; QoS
    user-interactive; `@autoreleasepool` por vuelta): si no hay llamada del juego en 0,7 s, con el mutex,
    `PresentHeldFrame`: termina el frame abierto del juego (lo vacía: `BeginFrame`/`LocateViews`/`EndFrame`
    ven `x.frame` nil y no hacen nada; el render de ese frame se pierde) o pide uno nuevo
    (query/update/wait/submission). `ShowHeld`: última imagen (`last_layers`, `last_origin_from_device`,
    `last_index[4]`, `last_anchor`) con su pose → el compositor la reproyecta (escena congelada y estable);
    sin imagen aún: negro con la cabeza actual (`idle_anchor`). Log: `vr: the game loop is busy (a load)...` /
    `vr: the game loop is back after X s; N frames were shown for it`.
  - El ancla del dispositivo se pone una sola vez por drawable, quien lo presenta: `EndFrame` (antes en
    `BeginFrame`), `PresentBlank` para frames del juego sobrantes, el keeper con `last_anchor`/`idle_anchor`.
  - `EndFrame` guarda `last_*` si `anything && anchor_valid` (swap `anchor`↔`last_anchor`); sin `x.frame`
    pone `frame_open_ = false`. `Acquire` salta la imagen `last_index` (3 imágenes: alterna las otras dos).
    `have_last = false` al cambiar o cerrarse el espacio. `ComposeFrame` acepta `indices` (imágenes dadas).
  - Riesgo sin verificar: el keeper termina en su hilo un `cp_frame` empezado en el hilo del juego (orden
    garantizado por el mutex). Si el log del sistema se queja: terminar el frame abierto en la siguiente
    llamada del juego y que el keeper solo pida frames nuevos.
- **Build 11 (run_number 15): OK** → `releases/download/build-15/PTVisionPro-15.ipa`. **Build 12 (run_number 16): OK** → `releases/download/build-16/PTVisionPro-16.ipa` (la recomendada):
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

## VPEngine (escojoncio/VPEngine)

- Revisado hasta `c400350`: traductor AOT x86-64→C para juegos de PS4 + capa Swift común
  (`platform/visionos`: controlador, Sense, VPS4, logs, idioma) copiada de este repo y desacoplada. Nada
  aplicable a P.T. (que es C++ nativo, sin emulación) en ese punto.
- Revisado hasta `cf5d774` (22 commits): FPU x87 exacta con SoftFloat, SSSE3/SSE4/SSE4a/AES/PCLMUL/CRC32,
  caché de despacho por hilo y de veneers HLE, excepciones C++ traducidas, puntos de reanudación
  (fibers/corrutinas), pila de 16 MiB para hilos invitados en el parche de shadPS4, CI con logs. Todo es
  traductor/runtime AOT o emulación; `platform/visionos` sin cambios → descartado, nada aplicable.

## Pendiente (siguiente sesión, en orden)

Objetivo de rendimiento: **45 fps reales estables** (modo 45 FPS, `SetFrameDivisor(2)`, el compositor reproyecta a 90),
con sombras altas, SSAO, bloom y reflejos (estándar mínimo M2); presupuesto GPU ≈ 22 ms por fotograma para las 4 vistas
más la composición. Clave para que no maree: profundidad real al drawable (reproyección posicional).
Frecuencias: M2 90/96/100 Hz → modos estables 45/90, 48/96, 50/100 (M2 apunta a 50/100 si la GPU llega); M5 hasta
120 Hz → 60/120 como PS VR. La app no puede pedir la frecuencia (comprobado, build 21 la mide y la registra).
Preset M5 bloqueado sin M5: hecho (build 21).

Siguiente (tras el log de build 24): coste fijo por frame (~10 ms): sombras 2,3–2,9 ms (caché de sombras estáticas),
post/bloom de las anchas, iluminación; formatos de luz más ligeros (R11G11B10F) si no cambian la imagen; máscara del
centro en las vistas anchas (no dibujar bajo el inset). Fusionar pasadas para la GPU de tiles.

0. Medir build 18 (log `vr pace` con 4 vistas) y calibrar periphery/center por defecto. Siguiente: resolución
   dinámica por tiempo de GPU, caché de sombras estáticas, profundidad al drawable (reproyección posicional),
   inset por ojo (hoy simétrico sobre la tangente unión: el lado nasal se dibuja de más), anillo en el borde del
   centro (SSR solo dentro). Comodidad: fundido en cortes de cámara de escenas.
1. Primera prueba en el visor (build 8): ver estéreo. Comprobar orientación de los ejes (ARKit es Y arriba,
   -Z adelante, igual que OpenXR; si la imagen sale girada revisar `QuatOf`/tangentes) y la
   altura (ARKit origen en el suelo; `VrPlay` recentra en la cabeza).
2. Profundidad real al drawable (hoy constante "lejos"): mejora la reproyección a 45 fps.
3. Resolución dinámica (el renderer recrea objetivos al cambiar de tamaño: hacerlo con viewport).
4. Calibrar presets M2/M5 con las líneas `vr pace:` del registro.
6. Comprobación de datos en el launcher: hecha (chunk1.psarc, texture.qar); probar con los datos reales.
