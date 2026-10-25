# Datos, partidas, CI y comprobación local

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
- CI: solo con `[build]` o dispatch; logs en la rama `ci-logs` (`gh api "repos/{owner}/{repo}/contents/latest.log?ref=ci-logs"
  --jq .content | base64 -d`); releases por REST (`gh api repos/{owner}/{repo}/releases?per_page=1`); GraphQL bloqueado.

