# libvips (x86_64-v1)

Prebuilt [libvips](https://github.com/libvips/libvips) for Debian Bookworm/Ubuntu 22.04+
(x86_64 only), compiled for the **x86-64-v1** CPU baseline (SSE2, no AVX/AVX2),
with a curated set of core delegate libraries statically linked into `libvips.so`.

Deps used:

| Library | Repository |
| --- | --- |
| zlib | [repo](https://github.com/madler/zlib) |
| libdeflate | [repo](https://github.com/ebiggers/libdeflate) |
| libjpeg-turbo | [repo](https://github.com/libjpeg-turbo/libjpeg-turbo) |
| libpng | [repo](https://github.com/glennrp/libpng) |
| libwebp | [repo](https://github.com/webmproject/libwebp) |
| libtiff | [repo](https://gitlab.com/libtiff/libtiff) |
| lcms2 | [repo](https://github.com/mm2/Little-CMS) |
| cgif | [repo](https://github.com/dloebl/cgif) |
| libexif | [repo](https://github.com/libexif/libexif) |
| fftw | [repo](https://github.com/FFTW/fftw3) |
| orc | [repo](https://gitlab.freedesktop.org/gstreamer/orc) |
| highway | [repo](https://github.com/google/highway) |
| openjpeg | [repo](https://github.com/uclouvain/openjpeg) |
| libde265 | [repo](https://github.com/strukturag/libde265) |
| libheif | [repo](https://github.com/strukturag/libheif) |
| libimagequant | [repo](https://github.com/ImageOptim/libimagequant) |
| libarchive | [repo](https://github.com/libarchive/libarchive) |
| pcre2 | [repo](https://github.com/PCRE2Project/pcre2) |
| libffi | [repo](https://github.com/libffi/libffi) |
| glib | [repo](https://github.com/GNOME/glib) |
| gvdb | [repo](https://gitlab.gnome.org/GNOME/gvdb) |
| meson | [repo](https://github.com/mesonbuild/meson.git) |

Intentionally excluded (heavier/optional delegates): libraw, poppler, openslide,
rsvg/pangocairo, ImageMagick, jpeg-xl, OpenEXR, matio, nifti, cfitsio, uhdr, pdfium.

Note: libimagequant is Rust-based (built via `cargo-c`); `build.sh` installs a
local Rust toolchain via `rustup` automatically if `rustc` isn't already on
`PATH` (CI workflows set one up explicitly via `dtolnay/rust-toolchain`).
`cargo-c` itself is built with its `vendored-openssl` feature, so no system
`libssl-dev`/`openssl-dev` package is required at any point.

## Usage

```bash
./build.sh            # build latest libvips release
./build.sh v8.18.7     # build a specific tag
```

Output tarball: `build/libvips-<tag>-linux-amd64.tar.gz`, containing `bin/`,
`lib/` (including `libvips.so` and pkgconfig files) and `include/`.

Disclaimer: This repo is almost purely vibecoded with copilot.
