/*
 * JPEG XR decoder using the Microsoft reference library.
 *
 * This file is part of FFmpeg and may be distributed under the terms of the
 * GNU Lesser General Public License, version 2.1 or (at your option) any
 * later version.
 */

#include <string.h>

#include <JXRGlue.h>

#include "libavutil/common.h"
#include "libavutil/imgutils.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/pixdesc.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"

static const struct {
    const PKPixelFormatGUID *guid;
    enum AVPixelFormat format;
    enum AVAlphaMode alpha;
} jxr_formats[] = {
    { &GUID_PKPixelFormat8bppGray,       AV_PIX_FMT_GRAY8 },
    { &GUID_PKPixelFormat16bppGray,      AV_PIX_FMT_GRAY16LE },
    { &GUID_PKPixelFormat16bppGrayHalf,  AV_PIX_FMT_GRAYF16LE },
    { &GUID_PKPixelFormat32bppGrayFloat, AV_PIX_FMT_GRAYF32LE },
    { &GUID_PKPixelFormat24bppRGB,       AV_PIX_FMT_RGB24 },
    { &GUID_PKPixelFormat24bppBGR,       AV_PIX_FMT_BGR24 },
    { &GUID_PKPixelFormat32bppBGR,       AV_PIX_FMT_BGR0 },
    { &GUID_PKPixelFormat32bppRGBA,      AV_PIX_FMT_RGBA,      AVALPHA_MODE_STRAIGHT },
    { &GUID_PKPixelFormat32bppBGRA,      AV_PIX_FMT_BGRA,      AVALPHA_MODE_STRAIGHT },
    { &GUID_PKPixelFormat32bppPRGBA,     AV_PIX_FMT_RGBA,      AVALPHA_MODE_PREMULTIPLIED },
    { &GUID_PKPixelFormat32bppPBGRA,     AV_PIX_FMT_BGRA,      AVALPHA_MODE_PREMULTIPLIED },
    { &GUID_PKPixelFormat48bppRGB,       AV_PIX_FMT_RGB48LE },
    { &GUID_PKPixelFormat64bppRGBA,      AV_PIX_FMT_RGBA64LE,  AVALPHA_MODE_STRAIGHT },
    { &GUID_PKPixelFormat48bppRGBHalf,   AV_PIX_FMT_RGBF16LE },
    { &GUID_PKPixelFormat64bppRGBAHalf,  AV_PIX_FMT_RGBAF16LE, AVALPHA_MODE_STRAIGHT },
    { &GUID_PKPixelFormat96bppRGBFloat,  AV_PIX_FMT_RGBF32LE },
    { &GUID_PKPixelFormat128bppRGBAFloat, AV_PIX_FMT_RGBAF32LE, AVALPHA_MODE_STRAIGHT },
};

/* The reference decoder reads fixed-size blocks past EOF. Zero the unread
 * tail explicitly; the SDK's memory stream otherwise leaves it untouched. */
static ERR jxr_read_memory(struct WMPStream *stream, void *dst, size_t size)
{
    const size_t pos = stream->state.buf.cbCur;
    const size_t length = stream->state.buf.cbBuf;
    const size_t available = pos < length ? FFMIN(size, length - pos) : 0;

    if (available)
        memcpy(dst, stream->state.buf.pbBuf + pos, available);
    if (available < size)
        memset((uint8_t *)dst + available, 0, size - available);
    stream->state.buf.cbCur += available;
    return WMP_errSuccess;
}

static int jxr_range_valid(size_t size, size_t offset, size_t length)
{
    return offset >= 8 && offset < size && length && length <= size - offset;
}

static int jxr_decode_frame(AVCodecContext *avctx, AVFrame *frame,
                            int *got_frame, AVPacket *pkt)
{
    PKImageDecode *decoder = NULL;
    struct WMPStream *stream = NULL;
    PKPixelFormatGUID guid;
    const WmpDEMisc *directory;
    const uint8_t *data = pkt->data;
    const size_t size = pkt->size;
    enum AVPixelFormat format = AV_PIX_FMT_NONE;
    enum AVAlphaMode alpha = AVALPHA_MODE_UNSPECIFIED;
    PKRect rect = { 0 };
    I32 width, height;
    uint32_t ifd;
    unsigned int entries;
    int row_bytes, ret;
    ERR err;

    if (pkt->size < 8 || AV_RL24(data) != 0xbc4949 || data[3] > 1)
        return AVERROR_INVALIDDATA;
    ifd = AV_RL32(data + 4);
    if (!jxr_range_valid(size, ifd, 2))
        return AVERROR_INVALIDDATA;
    entries = AV_RL16(data + ifd);
    if (!entries || !jxr_range_valid(size, ifd, 2 + 12 * entries + 4))
        return AVERROR_INVALIDDATA;

    if ((err = CreateWS_Memory(&stream, pkt->data, size)) != WMP_errSuccess)
        goto sdk_error;
    stream->Read = jxr_read_memory;
    if ((err = PKImageDecode_Create_WMP(&decoder)) != WMP_errSuccess ||
        (err = decoder->Initialize(decoder, stream)) != WMP_errSuccess ||
        (err = decoder->GetSize(decoder, &width, &height)) != WMP_errSuccess ||
        (err = decoder->GetPixelFormat(decoder, &guid)) != WMP_errSuccess)
        goto sdk_error;

    directory = &decoder->WMP.wmiDEMisc;
    if (!jxr_range_valid(size, directory->uImageOffset, directory->uImageByteCount)) {
        ret = AVERROR_INVALIDDATA;
        goto done;
    }
    if (decoder->WMP.bHasAlpha &&
        !jxr_range_valid(size, directory->uAlphaOffset, directory->uAlphaByteCount)) {
        /* Some SDK writers store an end offset instead of an alpha length. */
        if (directory->uAlphaOffset < 8 ||
            directory->uAlphaByteCount <= directory->uAlphaOffset ||
            directory->uAlphaByteCount > size) {
            ret = AVERROR_INVALIDDATA;
            goto done;
        }
    }

    for (unsigned int i = 0; i < FF_ARRAY_ELEMS(jxr_formats); i++) {
        if (IsEqualGUID(&guid, jxr_formats[i].guid)) {
            format = jxr_formats[i].format;
            alpha = jxr_formats[i].alpha;
            break;
        }
    }
    if (format == AV_PIX_FMT_NONE || decoder->WMP.wmiI.oOrientation >= O_RCW) {
        av_log(avctx, AV_LOG_ERROR, "Unsupported JPEG XR pixel format or rotated orientation\n");
        ret = AVERROR(ENOSYS);
        goto done;
    }
    if (width <= 0 || height <= 0) {
        ret = AVERROR_INVALIDDATA;
        goto done;
    }
    ret = av_image_check_size2(width, height, avctx->max_pixels, format, 0, avctx);
    if (ret < 0 || (ret = ff_set_dimensions(avctx, width, height)) < 0)
        goto done;

    avctx->pix_fmt = format;
    avctx->bits_per_raw_sample = av_pix_fmt_desc_get(format)->comp[0].depth;
    avctx->alpha_mode = alpha;
    ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0)
        goto done;
    row_bytes = av_image_get_linesize(format, width, 0);
    if (row_bytes < 0 || frame->linesize[0] < row_bytes) {
        ret = AVERROR_INVALIDDATA;
        goto done;
    }

    /* Include alpha as well as color; the reference decoder defaults to color only. */
    decoder->WMP.wmiSCP.uAlphaMode = alpha != AVALPHA_MODE_UNSPECIFIED ? 2 : 0;
    rect.Width = width;
    rect.Height = height;
    err = decoder->Copy(decoder, &rect, frame->data[0], frame->linesize[0]);
    if (err != WMP_errSuccess)
        goto sdk_error;

    *got_frame = 1;
    ret = pkt->size;
    goto done;

sdk_error:
    av_log(avctx, AV_LOG_ERROR, "JPEG XR reference decoder failed (%d)\n", (int)err);
    ret = err == WMP_errOutOfMemory ? AVERROR(ENOMEM) : AVERROR_INVALIDDATA;
done:
    if (decoder)
        decoder->Release(&decoder);
    if (stream)
        stream->Close(&stream);
    return ret;
}

const FFCodec ff_libjxr_decoder = {
    .p.name         = "libjxr",
    CODEC_LONG_NAME("JPEG XR via jxrlib"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_JPEGXR,
    .p.capabilities = AV_CODEC_CAP_DR1,
    FF_CODEC_DECODE_CB(jxr_decode_frame),
    .p.wrapper_name = "libjxr",
};
