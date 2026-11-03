#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      # AMD AMF SDK 仅需复制头文件即可使用
      local stage
      stage="$(stage_src "amf")"
      mkdir -p "$PREFIX/include/AMF"
      cp -rf "$stage/amf/public/include/"* "$PREFIX/include/AMF/"
      echo "AMF Headers successfully copied to $PREFIX/include/AMF/"
