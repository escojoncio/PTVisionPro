# Rama pt-1.0.5: juego de pt-pc 1.0.5 (+ arreglos 1.0.6) sobre el port

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

## Shaders 1.0.5 (build 58)

- 0002 trae solo parte del C++ de v1.0.5: NO están vfx_pass.cpp, scene_renderer.cpp, scene_lighting.*, gpu::, renderer.cpp
  (salvo push de CopyToXr); de scene_frame.cpp solo el orden de decals. Ver `grep '^diff --git' patches/0002…`.
- Shaders fusionados a 3 bandas (base 5c63078): `vfx_particle.vert/.frag` (Quad 304 B: light_position[3], light_color[3],
  light_factors; locations 12–18; `kLit`=2048=`kQuadLit`; salida única `out_color`, sin near/far), `gbuffer.frag` (solo
  `CreatureUv`), mezcla de reflexión en sRGB en `reflect_blend_main.glsl`, `reflect_temporal.frag`, `upscale_resolve.frag`,
  `vpktaa.frag`. Tomados de v1.0.5: `compose.frag` (NaN), `upscale_demod.frag` (`BeamFactor`, solo vista plana).
- NO traídos (dependen del C++ no fusionado): rt_*, light_contact/light_rt/light_full, pt_*, neural_*, mb_*, bindless
  (`PT_TEX2D`, `images[62]`), common.glsl, lighting.glsl/light_main.glsl (zona build 50), luminance.comp nuevo,
  deband de screen_fx/tonemap (`f1.x/f1.y` colisionan con los nuestros), vfx_composite/vfx_depth_down (near/far),
  composite.frag, ui_sprite.frag, Lisa date/backdrop. Si se fusiona más C++ de render, revisar estos contratos.
- `PcText` (pc_settings.cpp), `PT_VISIONOS`: `pc_title`, `pc_entry`, `pc_note_quit`, `pc_vr` salen de nuestro `kTexts` antes
  que de `localized::Menu` (en español salía "CONFIGURACIÓN DE PC"). Claves nuevas del visor: añadirlas a esa lista.
- Teatro del museo en VR: `vr_play.cpp` `ScreenMode` incluye `game.ArchiveTheaterActive()`; main.cpp rama de pantalla
  virtual usa `view`/`view_builder`/`view_vfx`/`take_reflection_readback(view)` y el dt del teatro.

## Build 70: textos, teatro, HUD

- `PcText` (PT_VISIONOS): `HeadsetKey()` = claves que ganan sobre `localized::Menu` (pc_title, pc_entry, pc_note_quit, pc_vr,
  pistas del museo, pc_note_freecam, pc_note_photo_mode, pc_photo_hint); tokens expandidos a texto plano con caché
  (`std::map` + mutex, vistas estables); `{kb}…{/kb}` se descarta, `{pad}…{/pad}` se conserva; `{1}`/`{2}` intactos.
- Teatro: `ScreenMode` `screen = ((demo||theater) && !immersive) || peephole`; estéreo por la rama `cutscene_` con ancla
  `ViewCamera`; `theater_` reinicia `cutscene_entered_`; main.cpp pasa `view` a `PrepareStereo`. Menú de pausa suspendido
  durante el teatro: `menu_open = MenuOpen() && !ArchiveTheaterActive()` (ApplyControls y rama VR).
- `FitHud` (vr_play.cpp): raycast cabeza→delante, distancia `clamp(hit-0,15, 0,7, 1,6)`, suavizado 0,15 s / 0,5 s, ancho
  y caída escalados; con menú fijo a 1,6 m; guardas `isfinite`.

## Build 71–72: HUD completo

- HUD completo: `UifView::Draw` marca `CoversCanvas()` (malla no aditiva, alfa ≥ 0,9, ≥ 90 % del lienzo por área recortada;
  caja ≥ 95 %); `GameUi::FullCanvasUi()` (DemoUi o créditos del port, menú cerrado) → `VrPlay::SetHudFull` →
  `FinishStereo`: quad bloqueado a la cabeza, contain 16:9 en la intersección de los campos de ambos ojos a la distancia
  `d` (`eye_tangents_`, `eye_offset_` = ±½ IPD), ×0,98; transición 0,12 s. Subtítulos escalan con él.
- Build 72: disparador explícito: `DemoUi::FullOverlay()` = imagen de crash (`bug_pick`/`bug_nodes`, recalculado en cada
  `Draw` según visibilidad real tras `Apply`; solo tras `FindEvent` correcto); `GameUi::subliminal_full_` (subliminal con
  texto); `FullCanvasUi` = crash || subliminal || `CoversCanvas` || créditos, menú cerrado. Log `ui: full-view overlay on/off`.
- Botones: `PcText` expande tokens según `SetPcPromptStyle` (main.cpp tras `ApplyControls`, con `ForcedPromptStyle` de
  input.cpp = ajuste "Iconos de botones" o mando): PS Cross/Circle/Square/Triangle/Options/L1/R1/L2/R2, Xbox A/B/X/Y/Menu/
  LB/RB/LT/RT, Nintendo B/A/Y/X/+/L/R/ZL/ZR; español Equis/Círculo/Cuadrado/Triángulo. Caché (clave, idioma, estilo).
  Aviso del teatro (`set_theater_hint`) se recalcula si cambian estilo o idioma.
- Mirada eliminada (mapa de foveado estático, medido build 71): sin `GazeInset`, `DenseCentre`, `gaze_inset`, `FoveationDiag`.
