#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/" && pwd)"
LOCK_FILE="$ROOT_DIR/dependencies.lock"

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "Lock file not found: $LOCK_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$LOCK_FILE"

latest_tag_from_remote() {
  local repo_url="$1"
  local tag_pattern="$2"

  local tags
  tags=$(git ls-remote --tags --refs "$repo_url" \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | grep -Ei "$tag_pattern" \
    | grep -Eiv 'alpha|beta|rc|pre|preview' || true)

  if [[ -z "$tags" ]]; then
    return 1
  fi

  printf '%s\n' "$tags" | sort -V | tail -n 1
}

update_var_if_newer() {
  local var_name="$1"
  local repo_var_name="$2"
  local tag_pattern="$3"

  local current_tag="${!var_name}"
  local repo_url="${!repo_var_name}"

  local latest_tag
  if ! latest_tag=$(latest_tag_from_remote "$repo_url" "$tag_pattern"); then
    echo "Could not resolve latest tag for $repo_url"
    return 0
  fi

  if [[ "$latest_tag" != "$current_tag" ]]; then
    printf -v "$var_name" '%s' "$latest_tag"
    echo "Updated $var_name: $current_tag -> $latest_tag"
    return 0
  fi

  echo "No change for $var_name ($current_tag)"
}

update_var_if_newer "ZLIB_TAG" "ZLIB_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBDEFLATE_TAG" "LIBDEFLATE_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBJPEG_TURBO_TAG" "LIBJPEG_TURBO_REPO" '^[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBPNG_TAG" "LIBPNG_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBWEBP_TAG" "LIBWEBP_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBTIFF_TAG" "LIBTIFF_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LCMS2_TAG" "LCMS2_REPO" '^lcms2\.[0-9]+$'
update_var_if_newer "CGIF_TAG" "CGIF_REPO" '^v[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBEXIF_TAG" "LIBEXIF_REPO" '^v[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "FFTW_TAG" "FFTW_REPO" '^fftw-[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "ORC_TAG" "ORC_REPO" '^orc-[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "HIGHWAY_TAG" "HIGHWAY_REPO" '^[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "OPENJPEG_TAG" "OPENJPEG_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBDE265_TAG" "LIBDE265_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBHEIF_TAG" "LIBHEIF_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBIMAGEQUANT_TAG" "LIBIMAGEQUANT_REPO" '^[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBARCHIVE_TAG" "LIBARCHIVE_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "PCRE2_TAG" "PCRE2_REPO" '^pcre2-[0-9]+\.[0-9]+$'
update_var_if_newer "LIBFFI_TAG" "LIBFFI_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "GLIB_TAG" "GLIB_REPO" '^[0-9]+\.[0-9]*[02468]\.[0-9]+$'
update_var_if_newer "MESON_TAG" "MESON_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'

cat > "$LOCK_FILE" <<EOF
# Pinned dependency sources and tags for build.sh
# Update with: ./update-dependency-lock.sh

ZLIB_REPO="$ZLIB_REPO"
ZLIB_TAG="$ZLIB_TAG"

LIBDEFLATE_REPO="$LIBDEFLATE_REPO"
LIBDEFLATE_TAG="$LIBDEFLATE_TAG"

LIBJPEG_TURBO_REPO="$LIBJPEG_TURBO_REPO"
LIBJPEG_TURBO_TAG="$LIBJPEG_TURBO_TAG"

LIBPNG_REPO="$LIBPNG_REPO"
LIBPNG_TAG="$LIBPNG_TAG"

LIBWEBP_REPO="$LIBWEBP_REPO"
LIBWEBP_TAG="$LIBWEBP_TAG"

LIBTIFF_REPO="$LIBTIFF_REPO"
LIBTIFF_TAG="$LIBTIFF_TAG"

LCMS2_REPO="$LCMS2_REPO"
LCMS2_TAG="$LCMS2_TAG"

CGIF_REPO="$CGIF_REPO"
CGIF_TAG="$CGIF_TAG"

LIBEXIF_REPO="$LIBEXIF_REPO"
LIBEXIF_TAG="$LIBEXIF_TAG"

FFTW_REPO="$FFTW_REPO"
FFTW_TAG="$FFTW_TAG"

ORC_REPO="$ORC_REPO"
ORC_TAG="$ORC_TAG"

HIGHWAY_REPO="$HIGHWAY_REPO"
HIGHWAY_TAG="$HIGHWAY_TAG"

OPENJPEG_REPO="$OPENJPEG_REPO"
OPENJPEG_TAG="$OPENJPEG_TAG"

LIBDE265_REPO="$LIBDE265_REPO"
LIBDE265_TAG="$LIBDE265_TAG"

LIBHEIF_REPO="$LIBHEIF_REPO"
LIBHEIF_TAG="$LIBHEIF_TAG"

LIBIMAGEQUANT_REPO="$LIBIMAGEQUANT_REPO"
LIBIMAGEQUANT_TAG="$LIBIMAGEQUANT_TAG"

LIBARCHIVE_REPO="$LIBARCHIVE_REPO"
LIBARCHIVE_TAG="$LIBARCHIVE_TAG"

PCRE2_REPO="$PCRE2_REPO"
PCRE2_TAG="$PCRE2_TAG"

LIBFFI_REPO="$LIBFFI_REPO"
LIBFFI_TAG="$LIBFFI_TAG"

GLIB_REPO="$GLIB_REPO"
GLIB_TAG="$GLIB_TAG"

GVDB_REPO="$GVDB_REPO"
GVDB_REF="$GVDB_REF"

MESON_REPO="$MESON_REPO"
MESON_TAG="$MESON_TAG"
EOF

echo "Wrote updated lock file: $LOCK_FILE"
