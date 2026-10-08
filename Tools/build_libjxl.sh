#!/bin/zsh
# Builds Vendor/libjxl.xcframework: libjxl with its encoder, decoder,
# threads, highway and brotli, as one static library per platform.
# Needs cmake and ninja (`pip install cmake ninja`).
# Usage: Tools/build_libjxl.sh [work directory]
set -euo pipefail

VERSION=v0.11.1
ROOT=${0:A:h:h}
WORK=${1:-$(mktemp -d)}
cd "$WORK"

[[ -d libjxl ]] || git clone -q --depth 1 --branch $VERSION https://github.com/libjxl/libjxl.git
git -C libjxl submodule update --init --depth 1 third_party/highway third_party/brotli third_party/skcms

build() {
    local sdk=$1 archs=$2
    cmake -S libjxl -B build-$sdk -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk "-DCMAKE_OSX_ARCHITECTURES=$archs" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_INSTALL_PREFIX=$WORK/install-$sdk \
        -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBROTLI_DISABLE_TESTS=ON \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DJPEGXL_STATIC=OFF \
        -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JPEGLI=OFF \
        -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_SKCMS=ON \
        -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=ON \
        -DJPEGXL_ENABLE_BOXES=ON -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
        -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF
    cmake --build build-$sdk
    cmake --install build-$sdk

    mkdir -p xc/$sdk/Headers
    libtool -static -o xc/$sdk/libjxl.a install-$sdk/lib/lib{jxl,jxl_cms,jxl_threads,hwy,brotlienc,brotlidec,brotlicommon}.a
    strip -S xc/$sdk/libjxl.a
    cp -R install-$sdk/include/jxl xc/$sdk/Headers/
    cat > xc/$sdk/Headers/module.modulemap <<'MAP'
module CJXL {
    header "jxl/encode.h"
    header "jxl/decode.h"
    header "jxl/thread_parallel_runner.h"
    link "c++"
    export *
}
MAP
}

build iphoneos arm64
build iphonesimulator "arm64;x86_64"

rm -rf "$ROOT/Vendor/libjxl.xcframework"
xcodebuild -create-xcframework \
    -library xc/iphoneos/libjxl.a -headers xc/iphoneos/Headers \
    -library xc/iphonesimulator/libjxl.a -headers xc/iphonesimulator/Headers \
    -output "$ROOT/Vendor/libjxl.xcframework"
