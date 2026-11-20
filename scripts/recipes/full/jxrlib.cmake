# Installed only in the jxrlib staging tree. The reference glue also contains
# internal transcode/encode helpers; no SDK apps, DLLs, or FFmpeg encoder ship.
cmake_minimum_required(VERSION 3.16)
project(jxrlib LANGUAGES C)

add_library(jpegxr STATIC
    image/sys/adapthuff.c image/sys/image.c image/sys/strcodec.c
    image/sys/strPredQuant.c image/sys/strTransform.c image/sys/perfTimerANSI.c
    image/decode/decode.c image/decode/JXRTranscode.c image/decode/postprocess.c
    image/decode/segdec.c image/decode/strdec.c image/decode/strdec_x86.c
    image/decode/strInvTransform.c image/decode/strPredQuantDec.c
    image/encode/encode.c image/encode/segenc.c image/encode/strenc.c
    image/encode/strenc_x86.c image/encode/strFwdTransform.c image/encode/strPredQuantEnc.c)
add_library(jxrglue STATIC
    jxrgluelib/JXRGlue.c jxrgluelib/JXRGlueJxr.c
    jxrgluelib/JXRGluePFC.c jxrgluelib/JXRMeta.c)
foreach(target jpegxr jxrglue)
    target_include_directories(${target} PRIVATE common/include image/sys jxrgluelib)
    target_compile_definitions(${target} PRIVATE __ANSI__ DISABLE_PERF_MEASUREMENT)
endforeach()
target_link_libraries(jxrglue PRIVATE jpegxr)

install(TARGETS jpegxr jxrglue ARCHIVE DESTINATION lib)
install(FILES jxrgluelib/JXRGlue.h jxrgluelib/JXRMeta.h image/sys/windowsmediaphoto.h
        DESTINATION include/jxrlib)
install(DIRECTORY common/include/ DESTINATION include/jxrlib
        FILES_MATCHING PATTERN "*.h" PATTERN "guiddef.h" EXCLUDE)
