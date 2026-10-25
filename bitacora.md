# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad` (submódulo; pinea `pt-pc`
5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de visionOS sobre `build/port-src`
(+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK (`patches/moltenvk/0001…`, `0002…`).

## Último hecho

- Build 70 (rama `pt-1.0.5`): `pc_reset_confirm` restaurado (1.0.5 lo borró de las tablas); `PcText` (PT_VISIONOS) expande
  tokens `{accept}`/`{back}`/`{kb}`/`{pad}`… a texto de mando (0002 no trae `prompt_hint`); pistas del museo = controles VR;
  teatro del museo en estéreo por la rama `cutscene_` (ancla `ViewCamera`, L2/R2 zoom, Círculo sale, D-pad arriba/abajo
  anulado); HUD a distancia adaptativa (`FitHud`); preset M2 centro 55°; subtítulos 15 % por defecto. Detalle: `notas/pt-1.0.5.md`.
- Build 69 (log pt.log 25-oct, probada): triángulos resueltos (shaders 1.0.5 fusionados). Fallos que la 70 ataca: museo en
  2D sin zoom, textos del museo de PC, `pc_reset_confirm` en crudo, subtítulos con profundidad incómoda.
- Build 57: triángulos por Quad de partículas 192 B vs 304 B (C++ 1.0.5 sin shaders 1.0.5).
- `main` = build 53 (sin la fusión).

## Estado

- Commiteado sin build: diagnóstico del mapa de foveado (`FoveationDiag` en `xr_host_visionos.mm`, llamado en
  `Host::Present` solo para `x.drawable`; cada 1 s cuenta cambios del mapa y, en cola `pt.foveation-diag`, registra
  `foveation map: view N centre (x, y) density min..max`; `PT_VP_FOV_DIAG=0` lo apaga). Objetivo: saber si el mapa sigue la mirada.

- Rama de trabajo: `pt-1.0.5`. Build 69: juego visualmente correcto; build 70 sin probar.
- `museum: thumbnail capture could not start: Setting the working directory is not supported` (warn, sin investigar).
- `ui: option animation UI_sys_opt_setin_s missing` (warn, 7 veces en el log de la 69).
- HDR de la 1.0.5 (`vr_hdr.glsl`, `xr_copy.frag`): sin verificar en el visor.
- Ajustes del usuario (log 69) = nuevo preset M2: imagen 50 %, centro 55° al 100 %, altura -10°, periferia 10 %, VPKTAA 80 %,
  nitidez 100, VPKTAA en periferia, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps, subtítulos 15 %.
- Rendimiento build 69 (pasillo): 45 fps, GPU 4 vistas ~17,9 ms + composición 1,6 ms, térmico fair.

## Pendiente (en orden)

1. Próxima build: incluye el diagnóstico de foveado. Si `centre` se mueve al mirar sin girar la cabeza, mover el inset
   del VPKTAA a ese centro (`VrPlay::PrepareInsets`, `Host::InsetWanted`); si no, descartar definitivamente.
2. Log build 70: teatro en estéreo (giro, zoom, salir con Círculo, recorte con modelos pequeños: `kNearPlane` 0,05,
   `min_distance_` 0,08), pistas del museo, confirmación de reinicio, HUD adaptativo (raycast toca suelo/techo: aceptado).
3. Nombres de botón genéricos (Select/Back/Menu) en vez de iconos: fusionar `prompt_hint` de 1.0.5 si el usuario lo pide.
4. Otros idiomas (tr, zh, ar, ru, uk) caen al inglés en las claves del visor; tablas de upstream aún citan teclas.
5. Afinar `vpktaa.frag`. 6. `taa_valid_` (menor). 7. 45→90 reales (spacewarp propio).

## Decisiones

- Luces: NO lecturas campo a campo ni `PT_LIGHT_SURFACE_CONSTANTS` (presión de registros en Metal; build 51).
- AA: VPKTAA por defecto; FXAA solo para comparar. MetalFX, SMAA, TBDR descartados y borrados.
- Descartado: resolución dinámica como solución; bajar la resolución base; VRR de Metal (`PT_VP_VRR=1`, apagado);
  luces en una pasada (`PT_LIGHT_ONE_PASS=1`); MetalFX espacial; máscara del centro en anchas; quitar reflejos o bajar
  sombras; ritmo fijo como sustituto de rendimiento.
- Arquitectura (Compositor Services + MoltenVK, misma cola Metal): ver `notas/arquitectura.md`. No cambiar sin motivo.
- Mirada: visionOS no la da a apps Metal (foveado dinámico oficial solo en RealityKit o streaming con entitlement).
  Única vía en estudio: inferir el centro del mapa de foveado del drawable (pendiente del diagnóstico).
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
