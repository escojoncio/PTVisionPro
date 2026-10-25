# Bitácora — PTVisionPro

Port de P.T. (CUSA01127 v01.00) a Apple Vision Pro en VR inmersivo. Base: `upstream/pt-ipad` (submódulo; pinea `pt-pc`
5c63078 + 18 parches) → `tools/prepare_source.py` aplica los cambios de visionOS sobre `build/port-src`
(+ `patches/0001-visionos-menus.patch`). C++ nativo + MoltenVK (`patches/moltenvk/0001…`, `0002…`).

## Último hecho

- Build 57 = mismo código que la 53 (re-ejecución de CI). Probada con log pt (41): **regresión visual** (ver Estado).
- Build 53 (987694a): icono `AppIcon.solidimagestack`, arte del launcher (`LauncherBackground.swift`, `HomeView`). Solo Swift.
- Build 52 (112839b): `lighting.glsl`, `light_main.glsl`, `light_all.frag`, `upscale_demod.frag` devueltos a la 50;
  `vpktaa.frag` `DEPTH_GATHER 0`. La 51 duplicaba el coste de luces.
- Build 51 (3fe7a81): destellos estéreo (`vfx::SetFlareStereo`, `vfx_particle.vert`), caché de sombras por tesela
  (`shadow_static_[4]`), recorte CPU de luces por tesela, bloom 1 pasada/ronda (`kawase_sum.frag`), post fusionado.
- Bitácora compactada; detalle estable movido a `notas/`.

## Estado

- Funciona (hasta la 51): juego completo de principio a fin, sin cierres desde la build 14.
- **Roto en la 57 (log pt (41))**: triángulos de colores por toda la escena; en el modo museo (`theater:`) solo se ven esos
  triángulos y el resto negro (gpu labels: gbuffer/lighting ≈0, solo `compose and forward/effects`; `cull` 1–5 draws).
  Sospecha unverified: partículas (`fx_sh_glsrin01_s1` 2228–3032 partículas) y/o desajuste C++↔shaders tras el revert de la 52.
- Menú muestra textos de PC (`option menu page PC settings`, iconos "PC page"): no deberían verse en Vision Pro.
- `museum: thumbnail capture could not start: Setting the working directory is not supported` (warn).
- HDR: sin verificar (el usuario no ve bien la imagen).
- Ajustes del usuario = preset M2: imagen 50 %, centro 60° al 100 %, altura -10°, periferia 10 %, VPKTAA 80 %, nitidez 100,
  VPKTAA en periferia, sombras altas, SSAO, bloom, reflejos, anisotrópico 8x, 45 fps.
- Referencia build 50 (pasillo, 765→956): GPU ~6,6–7,5 ms; inset/lighting/lights 1,4–1,7; wide/shadows 1,4–1,8.

## Pendiente (en orden)

1. Diagnosticar y arreglar los triángulos y el museo negro (comparar 51 vs 52/53).
2. Ocultar textos/páginas de PC en el menú de Vision Pro.
3. Revisar HDR una vez se vea bien.
4. Afinar constantes de `vpktaa.frag` (KEEP_*, SIGMA_*, DISOCCLUSION, afilado).
5. Conocido menor: `taa_valid_` no caduca si una vista se salta frames con otra vista en la misma columna.
6. 45→90 reales (spacewarp propio) si la reproyección con profundidad convence.

## Decisiones

- Luces: NO lecturas campo a campo ni `PT_LIGHT_SURFACE_CONSTANTS` (presión de registros en Metal; build 51).
- AA: VPKTAA por defecto; FXAA solo para comparar. MetalFX, SMAA, TBDR descartados y borrados.
- Descartado: resolución dinámica como solución; bajar la resolución base; VRR de Metal (`PT_VP_VRR=1`, apagado);
  luces en una pasada (`PT_LIGHT_ONE_PASS=1`); MetalFX espacial; máscara del centro en anchas; quitar reflejos o bajar
  sombras; ritmo fijo como sustituto de rendimiento.
- Arquitectura (Compositor Services + MoltenVK, misma cola Metal): ver `notas/arquitectura.md`. No cambiar sin motivo.
- Presets duplicados en `kPresets` (.mm) y `PTSettings.defaults(for:)`: mantener iguales.

## Ficheros en juego

- `patches/0001-visionos-menus.patch` (todo el código del motor; regenerar desde el árbol `--edit`, ver `notas/datos-ci.md`).
- `visionos/core/xr_host_visionos.mm`, `visionos/App/Core/LauncherBackground.swift`, `visionos/App/Views/HomeView.swift`.

## Índice de notas

- `notas/funciones.md`: funciones vigentes del port (host, foveado, AA, profundidad, controles, subtítulos, menús, logs).
- `notas/datos-ci.md`: carpeta VPS4 y partidas, cachés de CI, comprobación local sin Mac, cómo leer logs/releases.
- `notas/arquitectura.md`: arquitectura decidida y qué cambia cada fichero.
- Historial detallado de builds: `git log -- bitacora.md`.
