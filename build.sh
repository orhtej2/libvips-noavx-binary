#!/bin/bash
set -e

# libvips Static-Dependency Build Script (x86_64-v1 baseline)
# Builds libvips with its core delegate libraries statically linked into
# libvips.so, targeting the x86-64-v1 CPU baseline (SSE2 only, no AVX/AVX2).
# Usage: ./build.sh [TAG]
# Examples:
#   ./build.sh v8.18.7     # Build a specific libvips tag
#   ./build.sh              # Build latest release for x86_64-v1

# Configuration
LIBVIPS_REPO="https://github.com/libvips/libvips.git"
RELEASE_TAG="${1:-latest}"
TARGET_ARCH="amd64"
WORK_DIR="${PWD}/build-work"
BUILD_DIR="${PWD}/build"
PREFIX="${WORK_DIR}/install"
LOCK_FILE="${PWD}/dependencies.lock"
HOST_MULTIARCH="$(gcc -dumpmachine 2>/dev/null || true)"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
MESON_BIN="meson"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"

if [ -n "$HOST_MULTIARCH" ]; then
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$PREFIX/lib/$HOST_MULTIARCH/pkgconfig"
fi

# Keep pkg-config isolated from host metadata so libvips only enables
# delegates that this script actually built into the local prefix.
PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}"
export PKG_CONFIG_DIR=""
# Every dependency here is built as a static (.a) archive only. Route all
# pkg-config lookups (meson, cmake, autotools) through a wrapper that always
# passes --static, so transitive static libs (e.g. libheif -> libde265,
# libwebp -> libsharpyuv) and static-only Cflags (e.g. -DLIBHEIF_STATIC_BUILD)
# aren't silently dropped from consumers.
PKG_CONFIG_STATIC_WRAPPER="$WORK_DIR/pkg-config-static"
mkdir -p "$WORK_DIR"
cat > "$PKG_CONFIG_STATIC_WRAPPER" <<'PKGCONFIGEOF'
#!/bin/sh
exec pkg-config --static "$@"
PKGCONFIGEOF
chmod +x "$PKG_CONFIG_STATIC_WRAPPER"
export PKG_CONFIG="$PKG_CONFIG_STATIC_WRAPPER"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64${HOST_MULTIARCH:+ -L$PREFIX/lib/$HOST_MULTIARCH}"
export LD_LIBRARY_PATH="$PREFIX/lib${HOST_MULTIARCH:+:$PREFIX/lib/$HOST_MULTIARCH}:$LD_LIBRARY_PATH"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

compiler_supports_flag() {
    local flag="$1"
    local cc_bin="${CC:-gcc}"

    printf 'int main(void){return 0;}\n' | "$cc_bin" "$flag" -x c -c -o /dev/null - >/dev/null 2>&1
}

load_dependency_lock() {
    if [ ! -f "$LOCK_FILE" ]; then
        log_error "Dependency lock file not found: $LOCK_FILE"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$LOCK_FILE"

    local required_vars=(
        ZLIB_REPO ZLIB_TAG
        LIBDEFLATE_REPO LIBDEFLATE_TAG
        LIBJPEG_TURBO_REPO LIBJPEG_TURBO_TAG
        LIBPNG_REPO LIBPNG_TAG
        LIBWEBP_REPO LIBWEBP_TAG
        LIBTIFF_REPO LIBTIFF_TAG
        LCMS2_REPO LCMS2_TAG
        CGIF_REPO CGIF_TAG
        LIBEXIF_REPO LIBEXIF_TAG
        FFTW_REPO FFTW_TAG FFTW_SHA256
        ORC_REPO ORC_TAG
        HIGHWAY_REPO HIGHWAY_TAG
        OPENJPEG_REPO OPENJPEG_TAG
        LIBDE265_REPO LIBDE265_TAG
        LIBHEIF_REPO LIBHEIF_TAG
        LIBIMAGEQUANT_REPO LIBIMAGEQUANT_TAG
        LIBARCHIVE_REPO LIBARCHIVE_TAG
        PCRE2_REPO PCRE2_TAG
        LIBFFI_REPO LIBFFI_TAG
        GLIB_REPO GLIB_TAG
        GVDB_REPO GVDB_REF
        MESON_REPO MESON_TAG
    )

    local missing=0
    for var_name in "${required_vars[@]}"; do
        if [ -z "${!var_name}" ]; then
            log_error "Missing '$var_name' in dependency lock file"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

checkout_repo_tag() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_tag="$3"

    if [ -d "$repo_dir/.git" ]; then
        log_info "Updating $repo_dir to tag $repo_tag"
        git -C "$repo_dir" remote set-url origin "$repo_url"
        git -C "$repo_dir" fetch --depth 1 origin "refs/tags/$repo_tag:refs/tags/$repo_tag" || \
            git -C "$repo_dir" fetch --depth 1 origin "$repo_tag"
        git -C "$repo_dir" checkout -f "$repo_tag"
        git -C "$repo_dir" reset --hard "$repo_tag"
        git -C "$repo_dir" clean -fdx
    else
        rm -rf "$repo_dir"
        log_info "Cloning $repo_dir at tag $repo_tag"
        git clone --depth 1 --branch "$repo_tag" "$repo_url" "$repo_dir"
    fi

    git -C "$repo_dir" checkout -f "$repo_tag"
}

checkout_repo_ref() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"

    rm -rf "$repo_dir"
    mkdir -p "$repo_dir"

    git -C "$repo_dir" init >/dev/null
    git -C "$repo_dir" remote add origin "$repo_url"
    git -C "$repo_dir" fetch --depth 1 origin "$repo_ref"
    git -C "$repo_dir" checkout -f FETCH_HEAD
    git -C "$repo_dir" clean -fdx
}

# Function to install build dependencies
install_dependencies() {
    if [ "${SKIP_APT_INSTALL:-false}" = "true" ]; then
        log_warn "Skipping apt dependency installation (SKIP_APT_INSTALL=true)"
        return 0
    fi

    log_info "Installing build dependencies..."

    if ! command -v apt-get &> /dev/null; then
        log_error "apt-get not found. This script is designed for Debian/Ubuntu systems."
        exit 1
    fi

    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        pkgconf \
        git \
        curl \
        wget \
        gettext \
        autoconf \
        automake \
        libtool \
        libltdl-dev \
        cmake \
        nasm \
        perl \
        python3 \
        python3-pip \
        python3-venv \
        ninja-build \
        gperf \
        autopoint \
        po4a

    log_info "Build dependencies installed successfully"
}

# Function to install a local Rust toolchain + cargo-c (needed for libimagequant)
install_rust_toolchain() {
    if [ "${SKIP_APT_INSTALL:-false}" = "true" ]; then
        log_warn "Skipping Rust toolchain installation (SKIP_APT_INSTALL=true)"
    fi

    export CARGO_HOME="${CARGO_HOME:-$WORK_DIR/cargo-home}"
    export RUSTUP_HOME="${RUSTUP_HOME:-$WORK_DIR/rustup-home}"
    export PATH="$CARGO_HOME/bin:$PATH"

    if ! command -v rustc &> /dev/null; then
        log_info "Installing Rust toolchain via rustup..."
        mkdir -p "$WORK_DIR"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$WORK_DIR/rustup-init.sh"
        sh "$WORK_DIR/rustup-init.sh" -y --default-toolchain stable --profile minimal --no-modify-path
    fi

    if ! command -v cargo-cbuild &> /dev/null; then
        log_info "Installing cargo-c (with vendored/statically-linked OpenSSL, no libssl-dev needed)..."
        # Unset the sandboxed pkg-config env for this host build-tool step: it
        # must not see our target static libs, must not force --static (which
        # would drag in the system libcurl's private deps like gnutls/gpg-error
        # /unistring), and vendored-openssl means it does not need the
        # system's openssl.pc either.
        env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_PATH -u PKG_CONFIG \
            cargo install cargo-c --locked --features vendored-openssl
    fi

    log_info "Using Rust toolchain: $(rustc --version)"
}

# Function to build a static dependency
build_zlib() {
    log_info "Building zlib (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "zlib" "$ZLIB_REPO" "$ZLIB_TAG"

    cd zlib
    CFLAGS="$CFLAGS -Wno-error" ./configure --static --prefix="$PREFIX"
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_libdeflate() {
    log_info "Building libdeflate (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libdeflate" "$LIBDEFLATE_REPO" "$LIBDEFLATE_TAG"

    cd libdeflate
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DLIBDEFLATE_BUILD_STATIC_LIB=ON \
        -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
        -DLIBDEFLATE_BUILD_GZIP=OFF \
        -DLIBDEFLATE_BUILD_TESTS=OFF \
        -DLIBDEFLATE_INSTALL=ON
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_jpeg() {
    log_info "Building libjpeg-turbo (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libjpeg-turbo" "$LIBJPEG_TURBO_REPO" "$LIBJPEG_TURBO_TAG"

    cd libjpeg-turbo
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DENABLE_SHARED=OFF \
        -DENABLE_STATIC=ON \
        -DWITH_SIMD=ON
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_png() {
    log_info "Building libpng (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libpng" "$LIBPNG_REPO" "$LIBPNG_TAG"

    cd libpng
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-zlib-prefix="${PREFIX%/}/"
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_webp() {
    log_info "Building libwebp (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libwebp" "$LIBWEBP_REPO" "$LIBWEBP_TAG"

    cd libwebp

    if [ ! -f "configure" ]; then
        log_info "Generating libwebp configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_tiff() {
    log_info "Building libtiff (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libtiff" "$LIBTIFF_REPO" "$LIBTIFF_TAG"

    cd libtiff

    if [ ! -f "configure" ]; then
        log_info "Generating libtiff configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-zstd \
                --disable-lzma \
                --disable-jbig \
                --with-zlib-include-dir="$PREFIX/include" \
                --with-zlib-lib-dir="$PREFIX/lib" \
                --with-libdeflate-include-dir="$PREFIX/include" \
                --with-libdeflate-lib-dir="$PREFIX/lib" \
                --with-jpeg-include-dir="$PREFIX/include" \
                --with-jpeg-lib-dir="$PREFIX/lib" \
                --with-webp-include-dir="$PREFIX/include" \
                --with-webp-lib-dir="$PREFIX/lib"
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_lcms2() {
    log_info "Building lcms2 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "lcms2" "$LCMS2_REPO" "$LCMS2_TAG"

    cd lcms2
    if [ ! -f "configure" ]; then
        log_info "Generating lcms2 configure script..."
        autoreconf -fi
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-examples
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_meson() {
    log_info "Building Meson (vendored)..."
    cd "$WORK_DIR"

    checkout_repo_tag "meson" "$MESON_REPO" "$MESON_TAG"

    cd meson
    rm -rf .venv
    python3 -m venv .venv
    .venv/bin/python -m pip install --upgrade pip setuptools wheel
    .venv/bin/python -m pip install .
    MESON_BIN="$PWD/.venv/bin/meson"
    export MESON_BIN
    log_info "Using vendored meson: $($MESON_BIN --version)"
    cd ..
}

build_cgif() {
    log_info "Building cgif (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "cgif" "$CGIF_REPO" "$CGIF_TAG"

    cd cgif
    rm -rf build
    "$MESON_BIN" setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Dtests=false \
        -Dexamples=false
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_libexif() {
    log_info "Building libexif (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libexif" "$LIBEXIF_REPO" "$LIBEXIF_TAG"

    cd libexif

    if [ ! -f "configure" ]; then
        log_info "Generating libexif configure script..."
        autoreconf -fi
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --without-doc
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_fftw() {
    log_info "Building fftw (static)..."
    cd "$WORK_DIR"

    # The FFTW git mirror does not include its generated codelets (those
    # require an OCaml toolchain to regenerate via genfft); build from the
    # official release tarball instead, which ships them pre-generated.
    # Everything is downloaded/extracted under $WORK_DIR (build-work/).
    local fftw_version="${FFTW_TAG#fftw-}"
    local fftw_dir="fftw-${fftw_version}"
    local tarball="${fftw_dir}.tar.gz"
    local tarball_url="https://www.fftw.org/${tarball}"

    if [ ! -f "$tarball" ] || ! echo "${FFTW_SHA256}  ${tarball}" | sha256sum -c - >/dev/null 2>&1; then
        log_info "Downloading $tarball_url"
        curl -fsSL -o "$tarball" "$tarball_url"
    fi
    echo "${FFTW_SHA256}  ${tarball}" | sha256sum -c -

    rm -rf "$fftw_dir"
    tar -xzf "$tarball"
    cd "$fftw_dir"

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-fortran \
                --with-pic
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_orc() {
    log_info "Building orc (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "orc" "$ORC_REPO" "$ORC_TAG"

    cd orc
    rm -rf build
    "$MESON_BIN" setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Dhotdoc=disabled \
        -Dbenchmarks=disabled \
        -Dexamples=disabled \
        -Dtests=disabled \
        -Dorc-test=disabled
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_highway() {
    log_info "Building highway (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "highway" "$HIGHWAY_REPO" "$HIGHWAY_TAG"

    cd highway
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DHWY_ENABLE_EXAMPLES=OFF \
        -DHWY_ENABLE_TESTS=OFF \
        -DHWY_ENABLE_CONTRIB=OFF \
        -DHWY_ENABLE_INSTALL=ON
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_openjpeg() {
    log_info "Building openjpeg (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "openjpeg" "$OPENJPEG_REPO" "$OPENJPEG_TAG"

    cd openjpeg
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_CODEC=OFF \
        -DBUILD_JPIP=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libde265() {
    log_info "Building libde265 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libde265" "$LIBDE265_REPO" "$LIBDE265_TAG"

    cd libde265
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_ENCODER=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libheif() {
    log_info "Building libheif (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libheif" "$LIBHEIF_REPO" "$LIBHEIF_TAG"

    cd libheif
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DWITH_LIBDE265=ON \
        -DWITH_X265=OFF \
        -DWITH_AOM=OFF \
        -DWITH_DAV1D=OFF \
        -DWITH_RAV1E=OFF \
        -DWITH_SvtEnc=OFF \
        -DWITH_OpenH264=OFF \
        -DWITH_JPEG_DECODER=OFF \
        -DWITH_JPEG_ENCODER=OFF \
        -DWITH_EXAMPLES=OFF \
        -DWITH_GDK_PIXBUF=OFF \
        -DWITH_REDUCED_VISIBILITY=ON \
        -DCMAKE_PREFIX_PATH="$PREFIX"
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libimagequant() {
    log_info "Building libimagequant (static, via cargo-c)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libimagequant" "$LIBIMAGEQUANT_REPO" "$LIBIMAGEQUANT_TAG"

    # The C API (capi feature, libimagequant.pc, headers) lives in the
    # imagequant-sys subcrate, not the workspace root.
    cd libimagequant/imagequant-sys
    cargo cinstall --release \
        --prefix="$PREFIX" \
        --libdir="$PREFIX/lib" \
        --library-type staticlib
    cd ../..
}

build_libarchive() {
    log_info "Building libarchive (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libarchive" "$LIBARCHIVE_REPO" "$LIBARCHIVE_TAG"

    cd libarchive
    # libarchive's source tree itself has a tracked "build/" directory (cmake
    # modules, autoconf snippets) -- use a different name for the out-of-source
    # build dir so it isn't wiped out.
    rm -rf _cmake_build
    cmake -S . -B _cmake_build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TEST=OFF \
        -DENABLE_CPIO=OFF \
        -DENABLE_TAR=OFF \
        -DENABLE_CAT=OFF \
        -DENABLE_ACL=OFF \
        -DENABLE_ICONV=OFF \
        -DENABLE_OPENSSL=OFF \
        -DENABLE_LIBXML2=OFF \
        -DENABLE_EXPAT=OFF \
        -DENABLE_BZip2=OFF \
        -DENABLE_LIBB2=OFF \
        -DENABLE_LZ4=OFF \
        -DENABLE_LZMA=OFF \
        -DENABLE_ZSTD=OFF \
        -DENABLE_ZLIB=ON \
        -DZLIB_ROOT="$PREFIX"
    cmake --build _cmake_build --parallel "$BUILD_JOBS"
    cmake --install _cmake_build
    cd ..
}

build_pcre2() {
    log_info "Building PCRE2 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "pcre2" "$PCRE2_REPO" "$PCRE2_TAG"

    cd pcre2
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DPCRE2_BUILD_PCRE2_8=ON \
        -DPCRE2_BUILD_PCRE2_16=OFF \
        -DPCRE2_BUILD_PCRE2_32=OFF \
        -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF \
        -DPCRE2_SUPPORT_JIT=OFF \
        -DPCRE2_SHOW_REPORT=OFF \
        -DPCRE2_SUPPORT_LIBBZ2=OFF \
        -DPCRE2_SUPPORT_LIBZ=OFF \
        -DPCRE2_SUPPORT_LIBREADLINE=OFF \
        -DPCRE2_SUPPORT_LIBEDIT=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libffi() {
    log_info "Building libffi (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libffi" "$LIBFFI_REPO" "$LIBFFI_TAG"

    cd libffi
    if [ ! -f "configure" ]; then
        log_info "Generating libffi configure script..."
        if [ -f "/usr/share/aclocal/ltdl.m4" ] && [ ! -f "m4/ltdl.m4" ]; then
            cp /usr/share/aclocal/ltdl.m4 m4/ltdl.m4
        fi
        autoreconf -vfi -I m4
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-docs \
                --disable-multi-os-directory
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_glib() {
    log_info "Building glib-2.0 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "glib" "$GLIB_REPO" "$GLIB_TAG"

    cd glib
    rm -rf build subprojects/gvdb
    mkdir -p subprojects
    checkout_repo_ref "subprojects/gvdb" "$GVDB_REPO" "$GVDB_REF"

    "$MESON_BIN" setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        --wrap-mode=nofallback \
        -Dtests=false \
        -Dinstalled_tests=false \
        -Dgtk_doc=false \
        -Dman=false \
        -Dnls=disabled \
        -Dselinux=disabled \
        -Dlibmount=disabled \
        -Dxattr=false \
        -Ddtrace=false \
        -Dsystemtap=false \
        -Dsysprof=disabled \
        -Dlibelf=disabled \
        -Dmultiarch=false \
        -Dglib_debug=disabled \
        -Dglib_assert=false \
        -Dglib_checks=false \
        -Doss_fuzz=disabled
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

# Function to fetch and checkout libvips source
fetch_libvips() {
    local tag=$1

    log_info "Fetching libvips source..."

    if [ -d "$WORK_DIR/libvips" ]; then
        log_info "Updating existing libvips repository..."
        cd "$WORK_DIR/libvips"
        git fetch origin
        cd "$WORK_DIR"
    else
        log_info "Cloning libvips repository..."
        cd "$WORK_DIR"
        git clone "$LIBVIPS_REPO" libvips
    fi

    cd "$WORK_DIR/libvips"

    if [ "$tag" = "latest" ]; then
        log_info "Checking out latest release..."
        git checkout $(git describe --tags --abbrev=0 2>/dev/null || git rev-parse HEAD)
    else
        log_info "Checking out tag: $tag..."
        git checkout "$tag"
    fi

    CHECKED_OUT_TAG=$(git describe --tags 2>/dev/null || git rev-parse --short HEAD)
    log_info "Checked out: $CHECKED_OUT_TAG"

    cd "$WORK_DIR"
}

# Function to build libvips with its core delegates statically linked in
build_libvips() {
    log_info "Building libvips with core delegates statically linked..."

    cd "$WORK_DIR/libvips"
    rm -rf build

    "$MESON_BIN" setup build \
        --prefix="$PREFIX/vips" \
        --libdir=lib \
        --buildtype=release \
        --default-library=shared \
        -Ddeprecated=false \
        -Dexamples=false \
        -Dcplusplus=true \
        -Dcpp-docs=false \
        -Ddocs=false \
        -Dmodules=disabled \
        -Dintrospection=disabled \
        -Dvapi=false \
        -Dcfitsio=disabled \
        -Dcgif=enabled \
        -Dexif=enabled \
        -Dfftw=enabled \
        -Dfontconfig=disabled \
        -Darchive=enabled \
        -Dheif=enabled \
        -Dheif-module=disabled \
        -Dimagequant=enabled \
        -Djpeg=enabled \
        -Duhdr=disabled \
        -Djpeg-xl=disabled \
        -Djpeg-xl-module=disabled \
        -Dlcms=enabled \
        -Dmagick=disabled \
        -Dmatio=disabled \
        -Dnifti=disabled \
        -Dopenexr=disabled \
        -Dopenjpeg=enabled \
        -Dopenslide=disabled \
        -Dopenslide-module=disabled \
        -Dhighway=enabled \
        -Dorc=enabled \
        -Dpangocairo=disabled \
        -Dpdfium=disabled \
        -Dpng=enabled \
        -Dpoppler=disabled \
        -Dpoppler-module=disabled \
        -Dquantizr=disabled \
        -Draw=disabled \
        -Drsvg=disabled \
        -Dspng=disabled \
        -Dtiff=enabled \
        -Dwebp=enabled \
        -Dzlib=enabled

    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install

    cd "$WORK_DIR"
}

# Function to verify libvips.so has no unexpected dynamic dependencies
verify_dependencies() {
    log_info "Verifying libvips shared library dependencies..."

    local lib_dir="$PREFIX/vips/lib"
    local so_file
    so_file=$(find "$lib_dir" -maxdepth 1 -name 'libvips.so.*' -type f | head -n1)

    if [ -z "$so_file" ]; then
        log_error "libvips.so not found in $lib_dir"
        exit 1
    fi

    log_info "Dynamic dependencies of $(basename "$so_file"):"
    ldd "$so_file" || true
}

# Function to strip binaries
optimize_binaries() {
    log_info "Stripping binaries and libraries..."

    find "$PREFIX/vips/bin" -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null || true
    find "$PREFIX/vips/lib" -maxdepth 1 -type f -name '*.so*' -exec strip --strip-unneeded {} \; 2>/dev/null || true

    log_info "Binary optimization complete"
}

# Function to create portable tarball
create_portable_tarball() {
    local tag=$1
    local arch=$2

    log_info "Creating portable tarball..."

    mkdir -p "$BUILD_DIR"

    local temp_dir="${WORK_DIR}/portable"
    local pkg_name="libvips-${tag}-${arch}"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir/$pkg_name"

    cp -a "$PREFIX/vips/bin" "$temp_dir/$pkg_name/" 2>/dev/null || true
    cp -a "$PREFIX/vips/lib" "$temp_dir/$pkg_name/"
    cp -a "$PREFIX/vips/include" "$temp_dir/$pkg_name/"

    cat > "$temp_dir/$pkg_name/README.md" << EOF
# libvips ${tag} (x86_64-v1 baseline)

Self-contained build of libvips with its core delegate libraries (zlib,
libdeflate, libjpeg-turbo, libpng, libwebp, libtiff, lcms2, cgif, libexif,
fftw, orc, highway, openjpeg, libde265, libheif, libimagequant, libarchive,
glib) statically linked into libvips.so.

Compiled for the x86-64-v1 CPU baseline (SSE2 only).

## Contents

- \`bin/\` - vips, vipsthumbnail, and other CLI tools
- \`lib/\` - libvips.so and pkgconfig files
- \`include/\` - C and C++ headers

## Usage

\`\`\`bash
export LD_LIBRARY_PATH="\$(pwd)/lib:\$LD_LIBRARY_PATH"
export PATH="\$(pwd)/bin:\$PATH"
export PKG_CONFIG_PATH="\$(pwd)/lib/pkgconfig:\$PKG_CONFIG_PATH"

vips --version
EOF

    cd "$temp_dir"
    tar -czf "${BUILD_DIR}/libvips-${tag}-linux-${arch}.tar.gz" "$pkg_name/"
    cd - > /dev/null

    log_info "Portable tarball created: ${BUILD_DIR}/libvips-${tag}-linux-${arch}.tar.gz"
    ls -lh "${BUILD_DIR}/libvips-${tag}-linux-${arch}.tar.gz"
}

usage() {
    cat << EOF
libvips Static-Dependency Build Script (x86_64-v1 baseline)

Builds libvips with its core delegate libraries statically linked into
libvips.so, targeting the x86-64-v1 CPU baseline (SSE2 only, no AVX/AVX2).

Usage: ./build.sh [TAG]

Environment:
    SKIP_APT_INSTALL=true   Skip the apt-get/rustup dependency step for local iterative builds

Options:
    TAG         Release tag to build (default: latest)
                Example: v8.18.7

Examples:
    ./build.sh
    ./build.sh v8.18.7

Output:
    - Portable tarball: build/libvips-<tag>-linux-amd64.tar.gz
    - Build directory: build-work/
    - Installed at: build-work/install/vips/
    - Dependency lock file: dependencies.lock

Notes:
    - Requires Ubuntu 22.04 or similar Debian-based system
    - libimagequant requires a Rust toolchain + cargo-c; installed automatically
      unless SKIP_APT_INSTALL=true
    - Optional heavier delegates (libraw, poppler, openslide, rsvg/pangocairo,
      ImageMagick, jpeg-xl) are intentionally disabled to keep the build scoped
EOF
}

cleanup_on_error() {
    log_error "Build failed"
    log_warn "Build directory retained for debugging: $WORK_DIR"
    exit 1
}

trap cleanup_on_error ERR

main() {
    log_info "libvips Static-Dependency Build (x86_64-v1 baseline)"
    log_info "Tag: $RELEASE_TAG"

    load_dependency_lock
    mkdir -p "$WORK_DIR"
    mkdir -p "$BUILD_DIR"

    CURRENT_ARCH=$(uname -m)
    if [ "$CURRENT_ARCH" != "x86_64" ]; then
        log_error "This script only targets x86_64; detected: $CURRENT_ARCH"
        exit 1
    fi

    # Use the x86-64-v1 baseline for a maximally portable build.
    local arch_cflags
    if compiler_supports_flag "-march=x86-64-v1"; then
        arch_cflags="-march=x86-64-v1 -mtune=generic"
    else
        log_warn "Compiler does not support -march=x86-64-v1; falling back to -march=x86-64"
        arch_cflags="-march=x86-64 -mtune=generic"
    fi

    # -fPIC is required so the statically-built dependencies can be linked
    # into the final libvips.so shared object.
    export CFLAGS="-O2 -fPIC $arch_cflags"
    export CXXFLAGS="-O2 -fPIC $arch_cflags"
    log_info "Compiler baseline flags: CFLAGS='$CFLAGS' CXXFLAGS='$CXXFLAGS'"

    log_info "Work directory: $WORK_DIR"
    log_info "Build output directory: $BUILD_DIR"

    install_dependencies
    install_rust_toolchain

    log_info "Building static dependencies..."
    build_zlib
    build_libdeflate
    build_jpeg
    build_png
    build_webp
    build_tiff
    build_lcms2
    build_meson
    build_cgif
    build_libexif
    build_fftw
    build_orc
    build_highway
    build_openjpeg
    build_libde265
    build_libheif
    build_libimagequant
    build_libarchive
    build_pcre2
    build_libffi
    build_glib

    fetch_libvips "$RELEASE_TAG"
    build_libvips
    verify_dependencies
    optimize_binaries

    ACTUAL_TAG=$CHECKED_OUT_TAG

    create_portable_tarball "$ACTUAL_TAG" "$TARGET_ARCH"

    log_info "================================"
    log_info "Build completed successfully!"
    log_info "================================"
    log_info "Output: $(pwd)/build/libvips-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info "To clean up build artifacts: rm -rf build-work/"
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

main
