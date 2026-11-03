#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      # AviSynth+ 仅需要复制其 C 头文件即可使用
      local stage
      stage="$(stage_src "avisynth")"
      mkdir -p "$PREFIX/include/avisynth/avs"
      cp -rf "$stage/avs_core/include/avisynth_c.h" "$PREFIX/include/avisynth/"
      cp -rf "$stage/avs_core/include/avs/"* "$PREFIX/include/avisynth/avs/"
      
      # 动态生成 avs/version.h 以便满足 FFmpeg 版本的 CPP 校验
      cat > "$PREFIX/include/avisynth/avs/version.h" <<'EOF'
#ifndef _AVS_VERSION_H_
#define _AVS_VERSION_H_

#define       AVS_PPSTR_(x)    	#x
#define       AVS_PPSTR(x)    	AVS_PPSTR_(x)

#define       AVS_PROJECT       AviSynth+
#define       AVS_MAJOR_VER     3
#define       AVS_MINOR_VER     7
#define       AVS_BUGFIX_VER    3
#define       RELEASE_TARBALL
#define       AVS_FULLVERSION	AVS_PPSTR(AVS_PROJECT) " " AVS_PPSTR(AVS_MAJOR_VER) "." AVS_PPSTR(AVS_MINOR_VER) "." AVS_PPSTR(AVS_BUGFIX_VER) " (x86_64)"

#endif  //  _AVS_VERSION_H_
EOF
      echo "AviSynth Headers successfully copied to $PREFIX/include/avisynth/"
