# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad` (submódulo; pinea `pt-pc`
5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de visionOS sobre `build/port-src`
(+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK (`patches/moltenvk/0001…`, `0002…`).

## Último hecho

- Build 58 (rama `pt-1.0.5`): shaders de v1.0.5 fusionados (causa de los triángulos: `vfx_particle.*` con Quad de 192 B y
  el C++ 1.0.5 con 304 B), menú VISION PRO en todos los idiomas (`PcText`), teatro del museo en pantalla virtual.
  Detalle: `notas/pt-1.0.5.md`. Shaders compilan; .cpp sin compilar en local; revisión adversarial sin fallos.
- Build 57 (rama `pt-1.0.5`, 6632734, log pt (41)): triángulos de colores en toda la escena; museo negro salvo triángulos;
  menú "CONFIGURACIÓN DE PC".
- Builds 54–56: fallos de CI de la fusión 1.0.5 (ver `notas/pt-1.0.5.md`).
- `main` = build 53 (sin la fusión): icono y arte del launcher; build 52 luces devueltas a la 50.

## Estado

- Rama de trabajo: `pt-1.0.5` (juego pt-pc 1.0.5 + arreglos 1.0.6 sobre el port). `main` sin la fusión.
- Build 58 sin probar en el visor. Hasta la 51/53: juego completo de principio a fin, sin cierres desde la build 14.
- HDR: cambios de la 1.0.5 en `vr_hdr.glsl`/`xr_copy.frag` sin verificar en el visor.
- `museum: thumbnail capture could not start: Setting the working directory is not supported` (warn, sin investigar).
- Ajustes del usuario = preset M2: imagen 50 %, centro 60° al 100 %, altura -10°, periferia 10 %, VPKTAA 80 %, nitidez 100,
  VPKTAA en periferia, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps.
- Referencia build 50 (pasillo, 765→956): GPU ~6,6–7,5 ms; inset/lighting/lights 1,4–1,7; wide/shadows 1,4–1,8.

## Pendiente (en orden)

1. Log build 58: sin triángulos; museo visible en pantalla virtual (controles del teatro con los sticks: unverified);
   menú VISION PRO; HDR.
2. Textos de PC restantes en otros idiomas/museo (`pc_note_reset`, pistas `{kb}` según `prompt_style`): unverified.
3. Afinar constantes de `vpktaa.frag` (KEEP_*, SIGMA_*, DISOCCLUSION, afilado).
4. Conocido menor: `taa_valid_` no caduca si una vista se salta frames con otra vista en la misma columna.
5. 45→90 reales (spacewarp propio) si la reproyección con profundidad convence.

## Decisiones

- Luces: NO lecturas campo a campo ni `PT_LIGHT_SURFACE_CONSTANTS` (presión de registros en Metal; build 51).
- AA: VPKTAA por defecto; FXAA solo para comparar. MetalFX, SMAA, TBDR descartados y borrados.
- Descartado: resolución dinámica como solución; bajar la resolución base; VRR de Metal (`PT_VP_VRR=1`, apagado);
  luces en una pasada (`PT_LIGHT_ONE_PASS=1`); MetalFX espacial; máscara del centro en anchas; quitar reflejos o bajar
  sombras; ritmo fijo como sustituto de rendimiento.
- Arquitectura (Compositor Services + MoltenVK, misma cola Metal): ver `notas/arquitectura.md`. No cambiar sin motivo.
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
