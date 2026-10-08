#!/bin/bash
# Builds the game for Apple Vision Pro: MoltenVK for visionOS, the game as static libraries
# (CMake), then the app (xcodegen + xcodebuild) as an unsigned IPA to sideload.
#
#   tools/build_visionos.sh [build-number]
#
# Needs: Xcode 16+ with the visionOS SDK, cmake, ninja, glslc (brew install shaderc), xcodegen.
# Everything lands under build/visionos; MoltenVK under build/moltenvk (both cached by the CI).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/visionos"
BUILD_NUMBER="${1:-1}"
MOLTENVK_COMMIT="$(python3 -c "import json;print(json.load(open('$ROOT/upstream/pt-ipad/source-lock.json'))['moltenvk_target'])")"
MOLTENVK="$ROOT/build/moltenvk"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

step() { echo; echo "==> $*"; }

# --- MoltenVK for visionOS (xros) ------------------------------------------------------------
LIB="$MOLTENVK/Package/Release/MoltenVK/static/MoltenVK.xcframework/xros-arm64/libMoltenVK.a"
if [ ! -f "$LIB" ]; then
  step "MoltenVK $MOLTENVK_COMMIT for visionOS"
  if [ ! -d "$MOLTENVK/.git" ]; then
    git clone https://github.com/KhronosGroup/MoltenVK.git "$MOLTENVK"
  fi
  git -C "$MOLTENVK" checkout --quiet "$MOLTENVK_COMMIT"
  (cd "$MOLTENVK" && ./fetchDependencies --xros --no-parallel-build && make xros)
fi
[ -f "$LIB" ] || { echo "MoltenVK xros archive missing"; exit 1; }
HEADERS="$MOLTENVK/Package/Release/MoltenVK/include"

# --- Voice models (whisper) -------------------------------------------------------------------
VOICE="$ROOT/build/voice"
mkdir -p "$VOICE"
fetch_model() {
  local name="$1" url="$2" expected="$3"
  if [ ! -f "$VOICE/$name" ]; then
    step "voice model $name"
    curl -L --fail --retry 3 -o "$VOICE/$name" "$url"
  fi
  local actual
  actual="$(shasum -a 256 "$VOICE/$name" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || { echo "$name: sha256 $actual, expected $expected"; exit 1; }
}
fetch_model ggml-base.en-q5_1.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin \
  4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f
fetch_model ggml-silero-v6.2.0.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin \
  2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987

# --- The game ---------------------------------------------------------------------------------
step "source"
python3 "$ROOT/tools/prepare_source.py"
GLSLC="${GLSLC:-$(command -v glslc)}"
step "cmake"
cmake -S "$ROOT/build/port-src" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
  -DFETCHCONTENT_BASE_DIR="$ROOT/build/deps" \
  -DPT_VISIONOS=ON "-DPT_VISIONOS_DIR=$ROOT/visionos" \
  "-DPT_APP_BUILD=$BUILD_NUMBER" -DPT_BUNDLE_IDENTIFIER=com.kdt.livecontainer \
  "-DPT_HOST_GLSLC=$GLSLC" "-DPT_VOICE_DIR=$VOICE" \
  "-DPT_MOLTENVK_LIBRARY=$LIB" "-DPT_MOLTENVK_INCLUDE_DIR=$HEADERS" "-DPT_MOLTENVK_LICENSE=$MOLTENVK/LICENSE" \
  -DPT_UPSCALERS=OFF -DPT_STREAMLINE=OFF -DPT_OPENXR=OFF -DPT_ENHANCED_TEXTURES=OFF -DPT_GAMEPLUS=OFF -DPT_NETWORK_UPDATES=OFF
step "build"
cmake --build "$BUILD" --target pt_visionos pt_shaders -j"$(sysctl -n hw.ncpu)"

# --- Libraries and resources for the app -----------------------------------------------------
step "collect"
rm -rf "$BUILD/lib" "$ROOT/visionos/Resources"
mkdir -p "$BUILD/lib" "$ROOT/visionos/Resources/licenses"
find "$BUILD" -name '*.a' -not -path "$BUILD/lib/*" -exec cp {} "$BUILD/lib/" \;
cp "$LIB" "$BUILD/lib/"
cp -R "$BUILD/shaders" "$ROOT/visionos/Resources/shaders"
cp -R "$VOICE" "$ROOT/visionos/Resources/voice"
cp -R "$ROOT/build/port-src/assets/fonts" "$ROOT/visionos/Resources/fonts"
cp "$ROOT/build/port-src/LICENSE" "$ROOT/visionos/Resources/licenses/pt-pc-MIT.txt"
cp "$ROOT/upstream/pt-ipad/LICENSE" "$ROOT/visionos/Resources/licenses/pt-ipad-MIT.txt"
cp "$MOLTENVK/LICENSE" "$ROOT/visionos/Resources/licenses/MoltenVK-LICENSE.txt"
# The game first, then its engine and the rest; the list twice for the archives that need each other.
LINK=""
for a in libpt_visionos.a libpt_engine.a libpt_thirdparty.a; do LINK="$LINK $BUILD/lib/$a"; done
for a in "$BUILD"/lib/*.a; do
  case "$(basename "$a")" in libpt_visionos.a|libpt_engine.a|libpt_thirdparty.a) ;; *) LINK="$LINK $a";; esac
done
LINK="$LINK $LINK"
echo "link: $LINK"

# --- The app ----------------------------------------------------------------------------------
step "app"
(cd "$ROOT/visionos" && xcodegen generate)
xcodebuild -project "$ROOT/visionos/PTVisionPro.xcodeproj" -scheme PTVisionPro -configuration Release \
  -destination 'generic/platform=visionOS' -derivedDataPath "$BUILD/derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "PT_LINK_FLAGS=$LINK" build
APP="$(find "$BUILD/derived/Build/Products" -name 'PTVisionPro.app' -type d | head -1)"
[ -d "$APP" ] || { echo "no app built"; exit 1; }
step "ipa"
rm -rf "$BUILD/ipa" && mkdir -p "$BUILD/ipa/Payload"
cp -R "$APP" "$BUILD/ipa/Payload/"
(cd "$BUILD/ipa" && zip -qry "PTVisionPro-$BUILD_NUMBER.ipa" Payload)
echo "IPA: $BUILD/ipa/PTVisionPro-$BUILD_NUMBER.ipa"
