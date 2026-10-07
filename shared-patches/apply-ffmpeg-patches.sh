#!/usr/bin/env bash
set -euo pipefail
stage="$1"
mode="${2:-lite}"
patchdir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/dolby-hdr"
case "$mode" in
  lite)
    patches=(
      0002-avfilter-add-hdr10plus-producer-filter.patch
      0004-avfilter-add-dovi-apply-curve-filter.patch
      0005-avcodec-dovi_rpudec-tag-ICtCp-frames-from-the-RPU.patch
      0005b-avcodec-itut35-tag-ICtCp-frames-from-the-RPU.patch
      0008-avcodec-nvenc-carry-HDR10-plus-metadata-in-AV1-temporal-units.patch
      0010-avfilter-setparams-add-max-cll-max-fall-options.patch
      0011-avfilter-setparams-add-master-display-mdvc-options.patch
      0012-avfilter-add-dovi-compose-dual-layer-fel.patch
      0013-avfilter-add-hlg2pq-picture-converter.patch
      0014-fel-pairing-safety.patch
    )
    ;;
  full)
    patches=(
      0001-avcodec-libsvtav1-HDR10-metadata-through-svt_add_metadata.patch
      0002-avfilter-add-hdr10plus-producer-filter.patch
      0004-avfilter-add-dovi-apply-curve-filter.patch
      0005-avcodec-dovi_rpudec-tag-ICtCp-frames-from-the-RPU.patch
      0005b-avcodec-itut35-tag-ICtCp-frames-from-the-RPU.patch
      0007-avcodec-libx265-write-HDR10-metadata-as-per-picture-SEI.patch
      0008-avcodec-nvenc-carry-HDR10-plus-metadata-in-AV1-temporal-units.patch
      0010-avfilter-setparams-add-max-cll-max-fall-options.patch
      0011-avfilter-setparams-add-master-display-mdvc-options.patch
      0012-avfilter-add-dovi-compose-dual-layer-fel.patch
      0013-avfilter-add-hlg2pq-picture-converter.patch
      0014-fel-pairing-safety.patch
      iamf-object-position-v2.patch
      0015-iamf-preserve-packet-side-data-values.patch
      0016-iamf-init-audio-element-type-before-gotos.patch
      0017-iamf-object-position-safety.patch
    )
    ;;
  *) echo "Unknown patch mode: $mode" >&2; exit 2 ;;
esac
[[ -d "$stage/.git" || -f "$stage/.git" ]] || { echo "Not a Git worktree: $stage" >&2; exit 2; }
state="$stage/.ffmpeg-shared-patches-$mode"
fingerprint="$(git -C "$stage" rev-parse HEAD)"
for name in "${patches[@]}"; do
  patch="$patchdir/$name"
  [[ -f "$patch" ]] || { echo "Missing patch: $patch" >&2; exit 1; }
  fingerprint+="$(sha256sum "$patch" | cut -d ' ' -f1)"
done
if [[ -f "$state" ]] && [[ "$(cat "$state")" == "$fingerprint" ]]; then
  echo "Shared $mode patches already applied to $(git -C "$stage" rev-parse --short HEAD)"
  exit 0
fi
for name in "${patches[@]}"; do
  patch="$patchdir/$name"
  git -C "$stage" apply --check "$patch" || {
    echo "Patch does not match this FFmpeg source: $name" >&2
    exit 1
  }
  git -C "$stage" apply --whitespace=nowarn "$patch"
  echo "Applied: $name"
done
printf '%s' "$fingerprint" > "$state"
