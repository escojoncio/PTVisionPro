# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad` (submódulo; pinea `pt-pc`
5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de visionOS sobre `build/port-src`
(+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK (`patches/moltenvk/0001…`, `0002…`).

## Último hecho

- AA especular más suave (tipo HDRP): `gbuffer.frag` (0002) varianza 0,25→0,10, tope 0,18→0,06; el usuario veía brillos
  apagados. Sin build.

- Preset M2: nitidez (RCAS) 100 → 70 en `kPresets` (`xr_host_visionos.mm:2353`) y `PTSettings.defaults(for:)`
  (`PTSettings.swift:133`). `PTSettings.load()` reaplica el preset al arrancar: el M2 guardado pasa a 70. Sin build.
- Log pt (5) = build 74 (RCAS + AA especular): sin cierres. RCAS ~0,2 ms/vista nítida; AA especular sin coste
  visible; escala 0,75 → 30 fps, 1,00 → 20 fps; VPKTAA 85–100 % → 41–44 fps; térmico serious a 763 s (tras pruebas pesadas).

- Commiteado SIN build (usuario pidió no lanzar; run 73 cancelado): RCAS (`shaders/vpkrcas.frag`, FSR1, límite 0,1875,
  proxy HDR p=sqrt(x/(1+x)), clamp 0,99999) tras VPKTAA en vistas nítidas: VPKTAA escribe `upscaled_` (slot 43), RCAS escribe
  `post_hdr_`; historial sin afilar; afilado interno de `vpktaa.frag` eliminado; deslizador nitidez → stops=(1-s)·2
  (0 = sin pasada); etiqueta `rcas` en `gpu labels`. SSAO fuera de la periferia: descartado (ahorro 0,1–0,3 ms).

- Build 73 (CANCELADA en CI, código commiteado): AA especular en `gbuffer.frag` (kernel = min(0,25·(|dn/dx|²+|dn/dy|²), 0,18) sobre la normal
  normalizada, r' = (r⁴+kernel)^¼; derivadas válidas tras `discard` porque Apple compila con vulkan1.3 = demote), ajuste
  `specular_aa` (fila `kVpSpecularAa`, `Toggles::specular_aa`, bit 0x100 de `ids.z` del gbuffer, `PT_VP_SPECULAR_AA`,
  `PTSettings.specularAA`); `vpktaa.frag` `SIGMA_EDGE_STILL 1.15` (borde quieto). Jitter previo verificado sin jitter.

- Build 72 (rama `pt-1.0.5`): pantalla de crash falsa a vista completa por disparador explícito (no estaba invertida:
  confirmado por el usuario); botones del mando real en avisos del museo; código de mirada eliminado. Ver `notas/pt-1.0.5.md`.

- Build 71 (rama `pt-1.0.5`): HUD a pantalla completa con imágenes 2D que cubren el lienzo (`UifView::CoversCanvas`,
  `DemoUi::FullCanvas`, `GameUi::FullCanvasUi`, `VrPlay::SetHudFull`; tamaño = intersección de los campos de ambos ojos
  con ½ IPD); zona nítida sigue el mapa de foveado (`DenseCentre`/`GazeInset`, ajuste `gaze_inset`, env
  `PT_VP_GAZE_INSET`); logs nuevos `ui: full-canvas picture…`, `vr: stereo frame: sharp zone…`, `foveation map:`.
  Detalle: `notas/pt-1.0.5.md`. .mm/Swift sin compilar en local; revisión adversarial en 3 rondas sin bloqueos.
- Build 70 (log pt (2)): museo arreglado (estéreo, zoom). Fallos: pantalla de crash falsa invertida y pequeña, escena
  final (`gc_p06_010_final`) pixelada incluso mirándola.
- Build 69: triángulos resueltos (shaders 1.0.5). `main` = build 53 (sin la fusión).

## Estado

- Rama de trabajo: `pt-1.0.5`. Build 71 probada 67 s (log pt (3)): sin cierres, 47 fps, GPU 4 vistas 20,3 ms.
- Mapa de foveado ESTÁTICO (log pt (3)): centro fijo vista 0 (0,631, 0,497), vista 1 (0,369, 0,497) durante toda la
  sesión; el objeto se recrea cada frame con el mismo contenido. `GazeInset` nunca se activó. Seguir la mirada: imposible.
- Build 72 sin probar. Crash falsa (log pt (4)): `bug_expression.uigb` vía DemoUi; `CoversCanvas` no la detectaba.
- Escena final pixelada: causa NO encontrada (no hay condición que salte el inset). Pendiente de `vr: stereo frame:`.
- `museum: thumbnail capture could not start: Setting the working directory is not supported` (warn, sin investigar).
- `ui: option animation UI_sys_opt_setin_s missing` (warn). HDR 1.0.5 sin verificar.
- Preset M2 = ajustes del usuario: imagen 50 %, centro 55° al 100 %, altura -10°, periferia 10 %, VPKTAA 80 %, nitidez 70,
  AA especular, VPKTAA en periferia, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps, subtítulos 15 %.
- Rendimiento build 69 (pasillo): 45 fps, GPU 4 vistas ~17,9 ms + composición 1,6 ms, térmico fair.

## Pendiente (en orden)

1. Log build 72: crash a vista completa (`ui: full-view overlay`), botones del museo, escena final (`vr: stereo frame:`,
   aún sin reproducir en un log).
2. Nitidez: probar RCAS 70 en la próxima build. Límite real del centro = salida
   862 px para 55° (~15,7 px/°, visor ~34): subir % VPKTAA no se nota. Opciones: círculo menor y más denso; anillo
   intermedio (6 vistas, `vr_last_camera_[4]` etc. a 6). Usuario no convencido aún.
3. Subtítulos con el HUD completo escalan con él (misma textura); sacarlos a otra capa si molesta.
4. Iconos de botón reales (`prompt_hint` de 1.0.5 no fusionado); ahora nombres de texto.
5. Otros idiomas caen al inglés en claves del visor; PC aún en `pc_note_prompt_style`, `pc_note_display_mode`, `pc_mouse`.
6. `taa_valid_` (menor). 7. 45→90 reales (spacewarp propio).

## Decisiones

- `show_border` (borde rojo de la zona nítida) se mantiene: sirve para calibrar FOV/zona nítida.
- Luces: NO lecturas campo a campo ni `PT_LIGHT_SURFACE_CONSTANTS` (presión de registros en Metal; build 51).
- AA: VPKTAA por defecto; FXAA solo para comparar. MetalFX, SMAA, TBDR descartados y borrados.
- Descartado: resolución dinámica como solución; bajar la resolución base; VRR de Metal (`PT_VP_VRR=1`, apagado);
  luces en una pasada (`PT_LIGHT_ONE_PASS=1`); MetalFX espacial; máscara del centro en anchas; quitar reflejos o bajar
  sombras; ritmo fijo como sustituto de rendimiento.
- Arquitectura (Compositor Services + MoltenVK, misma cola Metal): ver `notas/arquitectura.md`. No cambiar sin motivo.
- Mirada: visionOS no la da a apps Metal (foveado dinámico oficial solo en RealityKit o streaming con entitlement).
  El mapa de foveado del drawable es estático (medido, build 71): descartado definitivamente.
- Anisotropía 8× en el preset M2 (decisión del usuario: no sobran frames).
- Presets duplicados en `kPresets` (.mm) y `PTSettings.defaults(for:)`: mantener iguales.

## Ficheros en juego

- `patches/0002-pt-1.0.5-update.patch` (binario; regenerar como en `notas/pt-1.0.5.md`).

- `patches/0001-visionos-menus.patch` (todo el código del motor; regenerar desde el árbol `--edit`, ver `notas/datos-ci.md`).
- `visionos/core/xr_host_visionos.mm`, `visionos/App/Core/LauncherBackground.swift`, `visionos/App/Views/HomeView.swift`.

## Índice de notas

- `notas/funciones.md`: funciones vigentes del port (host, foveado, AA, profundidad, controles, subtítulos, menús, logs).
- `notas/datos-ci.md`: carpeta VPS4 y partidas, cachés de CI, comprobación local sin Mac, cómo leer logs/releases.
- `notas/pt-1.0.5.md`: fusión 1.0.5/1.0.6, shaders traídos y no traídos, regeneración del 0002, menú y teatro.
- `notas/arquitectura.md`: arquitectura decidida y qué cambia cada fichero.
- Historial detallado de builds: `git log -- bitacora.md`.
