#include <android/log.h>
#include <jni.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
#ifdef __cplusplus
#define __STDC_CONSTANT_MACROS
#ifdef _STDINT_H
#undef _STDINT_H
#endif
#include <stdint.h>
#endif
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
}

#define LOG_TAG "FfmpegExtractorJNI"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kAvioBufferSize = 32 * 1024;
constexpr int64_t kMaxSkipBytes = 256 * 1024;

// Must match FfmpegExtractor.kt constants.
constexpr int kReadResultPacket = 0;
constexpr int kReadResultEof = 1;
constexpr int kReadResultSeek = 2;
constexpr int kReadResultError = -1;

struct ExtractorContext {
  AVFormatContext* fmt_ctx = nullptr;
  AVIOContext* avio_ctx = nullptr;
  uint8_t* avio_buffer = nullptr;
  AVPacket* packet = nullptr;
  int audio_stream_index = -1;
  int64_t stream_length = -1;

  // Per-call synchronous JNI state (valid only inside a single JNI call).
  JNIEnv* env = nullptr;
  jobject thiz = nullptr;
  jbyteArray io_read_buffer = nullptr;
  int io_read_buffer_cap = 0;

  // Seek coordination with ExoPlayer ExtractorInput.
  int64_t current_pos = 0;
  int64_t deferred_seek_pos = -1;
  bool allow_skip_seek = true;
};

struct MethodIds {
  bool initialized = false;
  jmethodID read_from_input = nullptr;
  jmethodID skip_input = nullptr;
  jmethodID on_stream_info = nullptr;
  jmethodID on_packet = nullptr;
};

MethodIds g_methods;

bool EnsureMethods(JNIEnv* env, jobject thiz) {
  if (g_methods.initialized) return true;
  jclass clazz = env->GetObjectClass(thiz);
  if (!clazz) return false;
  g_methods.read_from_input = env->GetMethodID(clazz, "jniReadFromInput", "([BI)I");
  g_methods.skip_input = env->GetMethodID(clazz, "jniSkipInput", "(I)I");
  g_methods.on_stream_info =
      env->GetMethodID(clazz, "jniOnStreamInfo", "(Ljava/lang/String;IIJJ[B)V");
  g_methods.on_packet = env->GetMethodID(clazz, "jniOnPacket", "([BIJ)V");
  env->DeleteLocalRef(clazz);
  if (!g_methods.read_from_input || !g_methods.skip_input ||
      !g_methods.on_stream_info || !g_methods.on_packet) {
    LOGE("Failed to resolve FfmpegExtractor JNI methods");
    return false;
  }
  g_methods.initialized = true;
  return true;
}

int AvioReadPacket(void* opaque, uint8_t* buf, int buf_size) {
  auto* ctx = static_cast<ExtractorContext*>(opaque);
  if (!ctx || !ctx->env || !ctx->thiz || buf_size <= 0) {
    return AVERROR(EIO);
  }
  JNIEnv* env = ctx->env;

  if (!ctx->io_read_buffer || ctx->io_read_buffer_cap < buf_size) {
    if (ctx->io_read_buffer) {
      env->DeleteGlobalRef(ctx->io_read_buffer);
      ctx->io_read_buffer = nullptr;
    }
    jbyteArray local_arr = env->NewByteArray(buf_size);
    if (!local_arr) {
      env->ExceptionClear();
      return AVERROR(ENOMEM);
    }
    ctx->io_read_buffer = static_cast<jbyteArray>(env->NewGlobalRef(local_arr));
    env->DeleteLocalRef(local_arr);
    ctx->io_read_buffer_cap = buf_size;
  }

  jint bytes_read = env->CallIntMethod(ctx->thiz, g_methods.read_from_input,
                                       ctx->io_read_buffer, buf_size);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return AVERROR(EIO);
  }
  if (bytes_read == -1) {
    return AVERROR_EOF;
  }
  if (bytes_read < 0) {
    return AVERROR(EIO);
  }
  if (bytes_read > 0) {
    env->GetByteArrayRegion(ctx->io_read_buffer, 0, bytes_read,
                            reinterpret_cast<jbyte*>(buf));
    ctx->current_pos += bytes_read;
  }
  return bytes_read;
}

int64_t AvioSeek(void* opaque, int64_t offset, int whence) {
  auto* ctx = static_cast<ExtractorContext*>(opaque);
  if (!ctx) return AVERROR(EINVAL);

  if (whence == AVSEEK_SIZE) {
    return ctx->stream_length >= 0 ? ctx->stream_length : AVERROR(ENOSYS);
  }

  int64_t target = offset;
  if (whence == SEEK_CUR) {
    target = ctx->current_pos + offset;
  } else if (whence == SEEK_END) {
    if (ctx->stream_length < 0) return AVERROR(ENOSYS);
    target = ctx->stream_length + offset;
  } else if (whence != SEEK_SET) {
    return AVERROR(EINVAL);
  }

  if (target < 0) return AVERROR(EINVAL);
  if (target == ctx->current_pos) {
    return target;
  }

  // Forward small skip directly through ExtractorInput.
  if (ctx->allow_skip_seek && target > ctx->current_pos &&
      (target - ctx->current_pos) <= kMaxSkipBytes && ctx->env && ctx->thiz) {
    int64_t remaining = target - ctx->current_pos;
    while (remaining > 0) {
      int chunk = static_cast<int>(std::min<int64_t>(remaining, 32 * 1024));
      jint skipped = ctx->env->CallIntMethod(ctx->thiz, g_methods.skip_input, chunk);
      if (ctx->env->ExceptionCheck()) {
        ctx->env->ExceptionClear();
        return AVERROR(EIO);
      }
      if (skipped <= 0) {
        return AVERROR_EOF;
      }
      ctx->current_pos += skipped;
      remaining -= skipped;
    }
    return ctx->current_pos;
  }

  // Record requested seek position so Kotlin side can return RESULT_SEEK.
  ctx->deferred_seek_pos = target;
  return AVERROR(ESPIPE);
}

void ReleaseContext(ExtractorContext* ctx, JNIEnv* env) {
  if (!ctx) return;
  if (ctx->packet) {
    av_packet_free(&ctx->packet);
  }
  if (ctx->fmt_ctx) {
    avformat_close_input(&ctx->fmt_ctx);
  }
  if (ctx->avio_ctx) {
    av_freep(&ctx->avio_ctx->buffer);
    avio_context_free(&ctx->avio_ctx);
    ctx->avio_buffer = nullptr;
  } else if (ctx->avio_buffer) {
    av_freep(&ctx->avio_buffer);
  }
  if (ctx->io_read_buffer && env) {
    env->DeleteGlobalRef(ctx->io_read_buffer);
    ctx->io_read_buffer = nullptr;
  }
  delete ctx;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_extractor_FfmpegExtractor_nativeOpen(
    JNIEnv* env, jobject thiz, jlong inputLength, jlong initialPos) {
  if (!EnsureMethods(env, thiz)) return 0;

  auto* ctx = new ExtractorContext();
  ctx->stream_length = inputLength;
  ctx->current_pos = initialPos;
  ctx->env = env;
  ctx->thiz = thiz;
  // During open/probe, only allow small forward skips; do not trigger deferred seeks.
  ctx->allow_skip_seek = true;

  ctx->avio_buffer = static_cast<uint8_t*>(av_malloc(kAvioBufferSize));
  if (!ctx->avio_buffer) {
    ReleaseContext(ctx, env);
    return 0;
  }

  ctx->avio_ctx = avio_alloc_context(
      ctx->avio_buffer, kAvioBufferSize, 0, ctx, &AvioReadPacket, nullptr, &AvioSeek);
  if (!ctx->avio_ctx) {
    ReleaseContext(ctx, env);
    return 0;
  }
  // Mark seekable if length is known so FFmpeg probes properly, while AvioSeek handles ESPIPE.
  ctx->avio_ctx->seekable = (inputLength > 0) ? AVIO_SEEKABLE_NORMAL : 0;

  ctx->fmt_ctx = avformat_alloc_context();
  if (!ctx->fmt_ctx) {
    ReleaseContext(ctx, env);
    return 0;
  }
  ctx->fmt_ctx->pb = ctx->avio_ctx;
  ctx->fmt_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;

  AVDictionary* opts = nullptr;
  av_dict_set(&opts, "probesize", "524288", 0);
  av_dict_set(&opts, "analyzeduration", "1000000", 0);

  int ret = avformat_open_input(&ctx->fmt_ctx, nullptr, nullptr, &opts);
  av_dict_free(&opts);
  if (ret < 0) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    LOGD("avformat_open_input failed: %s", errbuf);
    ctx->env = nullptr;
    ctx->thiz = nullptr;
    ReleaseContext(ctx, env);
    return 0;
  }

  ret = avformat_find_stream_info(ctx->fmt_ctx, nullptr);
  if (ret < 0) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    LOGD("avformat_find_stream_info failed: %s", errbuf);
    ctx->env = nullptr;
    ctx->thiz = nullptr;
    ReleaseContext(ctx, env);
    return 0;
  }

  int stream_idx = av_find_best_stream(ctx->fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
  if (stream_idx < 0) {
    LOGD("No audio stream found");
    ctx->env = nullptr;
    ctx->thiz = nullptr;
    ReleaseContext(ctx, env);
    return 0;
  }
  ctx->audio_stream_index = stream_idx;

  AVStream* stream = ctx->fmt_ctx->streams[stream_idx];
  AVCodecParameters* codecpar = stream->codecpar;
  const AVCodec* dec = avcodec_find_decoder(codecpar->codec_id);
  const char* codec_name = dec ? dec->name : avcodec_get_name(codecpar->codec_id);
  int sample_rate = codecpar->sample_rate > 0 ? codecpar->sample_rate : 44100;
  int channels = codecpar->ch_layout.nb_channels > 0 ? codecpar->ch_layout.nb_channels : 2;

  int64_t duration_us = -1;
  if (stream->duration != AV_NOPTS_VALUE && stream->duration > 0) {
    duration_us = av_rescale_q(stream->duration, stream->time_base, {1, AV_TIME_BASE});
  } else if (ctx->fmt_ctx->duration != AV_NOPTS_VALUE && ctx->fmt_ctx->duration > 0) {
    duration_us = ctx->fmt_ctx->duration;
  }

  jbyteArray extra_data_arr = nullptr;
  if (codecpar->extradata && codecpar->extradata_size > 0) {
    extra_data_arr = env->NewByteArray(codecpar->extradata_size);
    if (extra_data_arr) {
      env->SetByteArrayRegion(extra_data_arr, 0, codecpar->extradata_size,
                              reinterpret_cast<const jbyte*>(codecpar->extradata));
    }
  }

  jstring j_codec_name = env->NewStringUTF(codec_name ? codec_name : "");
  env->CallVoidMethod(thiz, g_methods.on_stream_info, j_codec_name, sample_rate,
                      channels, static_cast<jlong>(duration_us),
                      static_cast<jlong>(ctx->current_pos), extra_data_arr);
  env->DeleteLocalRef(j_codec_name);
  if (extra_data_arr) env->DeleteLocalRef(extra_data_arr);

  ctx->packet = av_packet_alloc();
  ctx->deferred_seek_pos = -1;
  ctx->env = nullptr;
  ctx->thiz = nullptr;
  return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT jint JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_extractor_FfmpegExtractor_nativeReadPacket(
    JNIEnv* env, jobject thiz, jlong handle, jlong currentPos) {
  auto* ctx = reinterpret_cast<ExtractorContext*>(handle);
  if (!ctx || !ctx->fmt_ctx || !ctx->packet) return kReadResultError;

  ctx->env = env;
  ctx->thiz = thiz;
  ctx->current_pos = currentPos;
  ctx->deferred_seek_pos = -1;

  while (true) {
    av_packet_unref(ctx->packet);
    int ret = av_read_frame(ctx->fmt_ctx, ctx->packet);
    if (ret == AVERROR_EOF) {
      ctx->env = nullptr;
      ctx->thiz = nullptr;
      return kReadResultEof;
    }
    if (ret < 0) {
      if (ctx->deferred_seek_pos >= 0) {
        ctx->env = nullptr;
        ctx->thiz = nullptr;
        return kReadResultSeek;
      }
      ctx->env = nullptr;
      ctx->thiz = nullptr;
      return kReadResultError;
    }
    if (ctx->packet->stream_index != ctx->audio_stream_index) {
      continue;
    }

    AVStream* stream = ctx->fmt_ctx->streams[ctx->audio_stream_index];
    int64_t pts_us = 0;
    int64_t ts = (ctx->packet->pts != AV_NOPTS_VALUE) ? ctx->packet->pts : ctx->packet->dts;
    if (ts != AV_NOPTS_VALUE) {
      pts_us = av_rescale_q(ts, stream->time_base, {1, AV_TIME_BASE});
      if (pts_us < 0) pts_us = 0;
    }

    jbyteArray pkt_arr = env->NewByteArray(ctx->packet->size);
    if (!pkt_arr) {
      env->ExceptionClear();
      ctx->env = nullptr;
      ctx->thiz = nullptr;
      return kReadResultError;
    }
    if (ctx->packet->size > 0) {
      env->SetByteArrayRegion(pkt_arr, 0, ctx->packet->size,
                              reinterpret_cast<const jbyte*>(ctx->packet->data));
    }
    env->CallVoidMethod(thiz, g_methods.on_packet, pkt_arr, ctx->packet->size,
                        static_cast<jlong>(pts_us));
    env->DeleteLocalRef(pkt_arr);
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      ctx->env = nullptr;
      ctx->thiz = nullptr;
      return kReadResultError;
    }

    ctx->env = nullptr;
    ctx->thiz = nullptr;
    return kReadResultPacket;
  }
}

JNIEXPORT jlong JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_extractor_FfmpegExtractor_nativeGetDeferredSeekPos(
    JNIEnv* env, jobject thiz, jlong handle) {
  auto* ctx = reinterpret_cast<ExtractorContext*>(handle);
  return ctx ? ctx->deferred_seek_pos : -1;
}

JNIEXPORT jint JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_extractor_FfmpegExtractor_nativeSeek(
    JNIEnv* env, jobject thiz, jlong handle, jlong timeUs, jlong currentPos) {
  auto* ctx = reinterpret_cast<ExtractorContext*>(handle);
  if (!ctx || !ctx->fmt_ctx || ctx->audio_stream_index < 0) return kReadResultError;

  ctx->env = env;
  ctx->thiz = thiz;
  ctx->current_pos = currentPos;
  ctx->deferred_seek_pos = -1;

  AVStream* stream = ctx->fmt_ctx->streams[ctx->audio_stream_index];
  int64_t target_ts = av_rescale_q(timeUs, {1, AV_TIME_BASE}, stream->time_base);
  int ret = av_seek_frame(ctx->fmt_ctx, ctx->audio_stream_index, target_ts, AVSEEK_FLAG_BACKWARD);

  ctx->env = nullptr;
  ctx->thiz = nullptr;

  if (ctx->deferred_seek_pos >= 0) {
    return kReadResultSeek;
  }
  if (ret < 0) {
    // Fallback: flush buffers even if seek failed.
    avformat_flush(ctx->fmt_ctx);
    return kReadResultError;
  }
  return kReadResultPacket;
}

JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_extractor_FfmpegExtractor_nativeClose(
    JNIEnv* env, jobject thiz, jlong handle) {
  auto* ctx = reinterpret_cast<ExtractorContext*>(handle);
  ReleaseContext(ctx, env);
}

}  // extern "C"
