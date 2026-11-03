#!/usr/bin/env bash
set -euo pipefail
stage="${1:?usage: apply-ffmpeg-patches.sh STAGE [full|nvenc|qsv|lite|nmr]}"
mode="${2:-full}"
case "$mode" in full|nvenc|qsv|nmr|lite) ;; *) echo "Unknown patch mode: $mode" >&2; exit 2 ;; esac
patch_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$stage/.git" || -f "$stage/.git" ]] || { echo "Not a Git worktree: $stage" >&2; exit 2; }

patches=("$patch_root/compat/configure-linker-flags-v3.patch")
if [[ "$mode" == full ]]; then
  # Only Full links the HDR-capable upstream VmafPicture.color API.
  patches+=("$patch_root/compat/libvmaf-hdr-color.patch")
fi

# Old markers can outlive source refreshes, so verify the patch hunks directly.
pending=()
for patch in "${patches[@]}"; do
  [[ -f "$patch" ]] || { echo "Missing compatibility patch: $patch" >&2; exit 1; }
  if git -C "$stage" apply --reverse --check "$patch" 2>/dev/null; then
    echo "Compatibility patch already present: $(basename "$patch") ($mode)"
  elif git -C "$stage" apply --check "$patch" 2>/dev/null; then
    pending+=("$patch")
  else
    printf 'Compatibility patch does not match this FFmpeg source: %s\nPatch: %s\nSource left unchanged; preserve local edits and review the upstream change.\n' "$stage" "$patch" >&2
    exit 1
  fi
done

if (( ${#pending[@]} )); then
  # A single preflighted apply keeps the patch set atomic.
  git -C "$stage" apply --check "${pending[@]}"
  git -C "$stage" apply --whitespace=nowarn "${pending[@]}"
fi
for patch in "${patches[@]}"; do
  git -C "$stage" apply --reverse --check "$patch"
done
echo "Verified FFmpeg compatibility patches ($mode)"
