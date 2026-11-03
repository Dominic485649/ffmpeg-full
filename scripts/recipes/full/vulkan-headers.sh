#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "vulkan-headers")"
      local vk_version
      vk_version="$(git -C "$stage" describe --tags --always 2>/dev/null | sed 's/^v//' | sed 's/-.*//')"
      mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/lib/pkgconfig"
      cp -rf "$stage/include/"* "$PREFIX/include/"

      # ponytail: enough for MinGW to link Windows' system Vulkan loader (vulkan-1.dll); build full Vulkan-Loader only if this import lib stops working.
      cat > "$PREFIX/lib/vulkan-1.def" <<EOF
LIBRARY vulkan-1.dll
EXPORTS
vkGetInstanceProcAddr
EOF
      "$DLLTOOL" -d "$PREFIX/lib/vulkan-1.def" -l "$PREFIX/lib/libvulkan-1.dll.a" -D vulkan-1.dll
      cp -f "$PREFIX/lib/libvulkan-1.dll.a" "$PREFIX/lib/libvulkan.dll.a"

      cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Vulkan-Loader
Description: Windows Vulkan loader import library
Version: $vk_version
Libs: -L\${libdir} -lvulkan-1
Cflags: -I\${includedir}
EOF
