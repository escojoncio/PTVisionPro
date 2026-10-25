# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad` (submódulo; pinea `pt-pc`
5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de visionOS sobre `build/port-src`
(+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK (`patches/moltenvk/0001…`, `0002…`).

## Último hecho

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
- Pantalla de crash falsa invertida: causa NO encontrada (variantes `sh_bug_*` = mallas con textura propia por la misma
  ruta UI que los subtítulos, que salen bien). Pendiente del log (`ui: full-canvas picture…` + `ui: bug screen N`).
- Escena final pixelada: causa NO encontrada (no hay condición que salte el inset). Pendiente de `vr: stereo frame:`.
- `museum: thumbnail capture could not start: Setting the working directory is not supported` (warn, sin investigar).
- `ui: option animation UI_sys_opt_setin_s missing` (warn). HDR 1.0.5 sin verificar.
- Preset M2 = ajustes del usuario: imagen 50 %, centro 55° al 100 %, altura -10°, periferia 10 %, VPKTAA 80 %, nitidez 100,
  VPKTAA en periferia, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps, subtítulos 15 %.
- Rendimiento build 69 (pasillo): 45 fps, GPU 4 vistas ~17,9 ms + composición 1,6 ms, térmico fair.

## Pendiente (en orden)

1. Log con crash falsa (variante, orientación) y escena final (`sharp zone drawn/NOT drawn`): el log pt (3) no llegó.
   Próxima build: quitar `GazeInset`/`DenseCentre`/ajuste `gaze_inset` y `FoveationDiag` (mapa estático, código inútil).
2. Subtítulos con el HUD completo escalan con él (misma textura); sacarlos a otra capa si molesta.
3. Nombres de botón genéricos en vez de iconos (`prompt_hint` de 1.0.5 no fusionado).
4. Otros idiomas (tr, zh, ar, ru, uk) caen al inglés en las claves del visor.
5. Afinar `vpktaa.frag`. 6. `taa_valid_` (menor). 7. 45→90 reales (spacewarp propio).

## Decisiones

- Luces: NO lecturas campo a campo ni `PT_LIGHT_SURFACE_CONSTANTS` (presión de registros en Metal; build 51).
- AA: VPKTAA por defecto; FXAA solo para comparar. MetalFX, SMAA, TBDR descartados y borrados.
- Descartado: resolución dinámica como solución; bajar la resolución base; VRR de Metal (`PT_VP_VRR=1`, apagado);
  luces en una pasada (`PT_LIGHT_ONE_PASS=1`); MetalFX espacial; máscara del centro en anchas; quitar reflejos o bajar
  sombras; ritmo fijo como sustituto de rendimiento.
- Arquitectura (Compositor Services + MoltenVK, misma cola Metal): ver `notas/arquitectura.md`. No cambiar sin motivo.
- Mirada: visionOS no la da a apps Metal (foveado dinámico oficial solo en RealityKit o streaming con entitlement).
  El mapa de foveado del drawable es estático (medido, build 71): descartado definitivamente.
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
