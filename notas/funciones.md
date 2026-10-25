# Funciones vigentes (dónde está cada cosa)

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
  foveado del juego, ancho, altura, nitidez zona, periferia, AA). Textos en `pc_settings.cpp`. Sincronía menú →
  `SettingChanged` → `GameRunner.settingFromGame` → `PTSettings` (UserDefaults). Presets duplicados en `kPresets` (.mm) y
  `PTSettings.defaults(for:)`: mantener iguales (incluyen foveado). M5 solo seleccionable en un M5.
  Las filas del foveado llaman `HeadsetCustom()`.
- Diagnóstico en el log: `vr pace` (cada 10 s), `gpu labels` (`PT_GPU_LABELS`), `cull`, `shadows`, `alive`, `where:`.

