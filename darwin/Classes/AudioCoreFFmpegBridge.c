#include "AudioCoreFFmpegBridge.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>

static void set_error(char **out_error_message, const char *fmt, ...) {
  if (out_error_message == NULL) {
    return;
  }

  va_list args;
  va_start(args, fmt);
  char buffer[1024];
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);

  *out_error_message = strdup(buffer);
}

static void set_av_error(char **out_error_message, int error_code, const char *context) {
  char error_buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
  av_strerror(error_code, error_buffer, sizeof(error_buffer));
  set_error(out_error_message, "%s: %s", context, error_buffer);
}

static bool is_ignorable_decode_error(int error_code) {
  return error_code == AVERROR_INVALIDDATA;
}

static void recover_from_decode_error(AVCodecContext *codec_context, AVFrame *frame) {
  if (codec_context != NULL) {
    avcodec_flush_buffers(codec_context);
  }
  if (frame != NULL) {
    av_frame_unref(frame);
  }
}

static void free_pcm(AudioCoreFFmpegDecodedPCM *pcm) {
  if (pcm == NULL) {
    return;
  }

  free(pcm->samples);
  pcm->samples = NULL;
  pcm->sample_count = 0;
  pcm->channels = 0;
  pcm->sample_rate = 0.0;
  pcm->frame_count = 0;
}

static bool append_samples(
  float **samples,
  int64_t *sample_count,
  int64_t *capacity,
  const float *source,
  int64_t source_count
) {
  if (source_count <= 0) {
    return true;
  }

  int64_t needed = *sample_count + source_count;
  if (needed > *capacity) {
    int64_t next_capacity = *capacity > 0 ? *capacity : 16384;
    while (next_capacity < needed) {
      next_capacity *= 2;
    }

    float *next_samples = realloc(*samples, (size_t)next_capacity * sizeof(float));
    if (next_samples == NULL) {
      return false;
    }

    *samples = next_samples;
    *capacity = next_capacity;
  }

  memcpy(*samples + *sample_count, source, (size_t)source_count * sizeof(float));
  *sample_count += source_count;
  return true;
}

struct AudioCoreFFmpegStreamDecoder {
  AVFormatContext *format_context;
  AVCodecContext *codec_context;
  SwrContext *swr_context;
  AVChannelLayout input_layout;
  AVChannelLayout output_layout;
  AVFrame *frame;
  AVPacket *packet;
  int stream_index;
  int source_sample_rate;
  int channels;
  int target_sample_rate;
  int64_t frame_count;
  bool finished;
};

typedef struct AudioCoreFFmpegStreamDecoder AudioCoreFFmpegStreamDecoder;

static void close_stream_decoder(AudioCoreFFmpegStreamDecoder *decoder) {
  if (decoder == NULL) {
    return;
  }

  av_channel_layout_uninit(&decoder->input_layout);
  av_channel_layout_uninit(&decoder->output_layout);
  av_packet_free(&decoder->packet);
  av_frame_free(&decoder->frame);
  swr_free(&decoder->swr_context);
  avcodec_free_context(&decoder->codec_context);
  avformat_close_input(&decoder->format_context);
  free(decoder);
}

static bool append_decoded_frame(
  AudioCoreFFmpegStreamDecoder *decoder,
  const AVFrame *frame,
  float **samples,
  int64_t *sample_count,
  int64_t *sample_capacity,
  char **out_error_message
) {
  int64_t delay = swr_get_delay(decoder->swr_context, decoder->source_sample_rate);
  int dst_nb_samples = (int)av_rescale_rnd(
    delay + frame->nb_samples,
    decoder->target_sample_rate,
    decoder->source_sample_rate,
    AV_ROUND_UP
  );
  if (dst_nb_samples <= 0) {
    return true;
  }

  uint8_t **converted_data = NULL;
  int converted_linesize = 0;
  int result = av_samples_alloc_array_and_samples(
    &converted_data,
    &converted_linesize,
    decoder->channels,
    dst_nb_samples,
    AV_SAMPLE_FMT_FLT,
    0
  );
  if (result < 0 || converted_data == NULL) {
    set_av_error(out_error_message, result, "failed to allocate resample buffer");
    if (converted_data != NULL) {
      av_freep(&converted_data[0]);
      av_freep(&converted_data);
    }
    return false;
  }

  int converted_frames = swr_convert(
    decoder->swr_context,
    converted_data,
    dst_nb_samples,
    (const uint8_t **)frame->extended_data,
    frame->nb_samples
  );
  if (converted_frames < 0) {
    set_av_error(out_error_message, converted_frames, "failed to resample audio");
    av_freep(&converted_data[0]);
    av_freep(&converted_data);
    return false;
  }

  int64_t produced_samples = (int64_t)converted_frames * decoder->channels;
  if (!append_samples(
        samples,
        sample_count,
        sample_capacity,
        (const float *)converted_data[0],
        produced_samples
      )) {
    set_error(out_error_message, "failed to append decoded samples");
    av_freep(&converted_data[0]);
    av_freep(&converted_data);
    return false;
  }

  av_freep(&converted_data[0]);
  av_freep(&converted_data);
  return true;
}

static bool open_stream_decoder(
  const char *path,
  double target_sample_rate,
  int64_t start_frame,
  AudioCoreFFmpegDecodedPCM *out_metadata,
  void **out_decoder,
  char **out_error_message
) {
  if (out_metadata == NULL || out_decoder == NULL || path == NULL || *path == '\0') {
    set_error(out_error_message, "invalid stream arguments");
    return false;
  }

  memset(out_metadata, 0, sizeof(*out_metadata));
  *out_decoder = NULL;

  AudioCoreFFmpegStreamDecoder *decoder = calloc(1, sizeof(*decoder));
  if (decoder == NULL) {
    set_error(out_error_message, "failed to allocate stream decoder");
    return false;
  }

  AVFormatContext *format_context = NULL;
  AVCodecContext *codec_context = NULL;
  SwrContext *swr_context = NULL;
  AVChannelLayout input_layout = {0};
  AVChannelLayout output_layout = {0};
  AVFrame *frame = NULL;
  AVPacket *packet = NULL;

  int result = avformat_open_input(&format_context, path, NULL, NULL);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to open input");
    goto cleanup;
  }
  format_context->flags |= AVFMT_FLAG_DISCARD_CORRUPT;

  result = avformat_find_stream_info(format_context, NULL);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to read stream info");
    goto cleanup;
  }

  int stream_index = av_find_best_stream(
    format_context,
    AVMEDIA_TYPE_AUDIO,
    -1,
    -1,
    NULL,
    0
  );
  if (stream_index < 0) {
    set_error(out_error_message, "no audio stream found");
    goto cleanup;
  }

  AVStream *audio_stream = format_context->streams[stream_index];
  const AVCodec *codec = avcodec_find_decoder(audio_stream->codecpar->codec_id);
  if (codec == NULL) {
    set_error(out_error_message, "no decoder found for audio stream");
    goto cleanup;
  }

  codec_context = avcodec_alloc_context3(codec);
  if (codec_context == NULL) {
    set_error(out_error_message, "failed to allocate codec context");
    goto cleanup;
  }

  result = avcodec_parameters_to_context(codec_context, audio_stream->codecpar);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to copy codec parameters");
    goto cleanup;
  }

  result = avcodec_open2(codec_context, codec, NULL);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to open codec");
    goto cleanup;
  }

  int source_sample_rate = codec_context->sample_rate > 0
    ? codec_context->sample_rate
    : audio_stream->codecpar->sample_rate;
  if (source_sample_rate <= 0) {
    source_sample_rate = 44100;
  }

  int channels = codec_context->ch_layout.nb_channels > 0
    ? codec_context->ch_layout.nb_channels
    : audio_stream->codecpar->ch_layout.nb_channels;
  if (channels <= 0) {
    channels = 2;
  }

  int target_rate = (int)lrint(target_sample_rate > 0 ? target_sample_rate : source_sample_rate);
  if (target_rate <= 0) {
    target_rate = source_sample_rate;
  }

  if (codec_context->ch_layout.nb_channels > 0) {
    result = av_channel_layout_copy(&input_layout, &codec_context->ch_layout);
  } else if (audio_stream->codecpar->ch_layout.nb_channels > 0) {
    result = av_channel_layout_copy(&input_layout, &audio_stream->codecpar->ch_layout);
  } else {
    av_channel_layout_default(&input_layout, channels);
    result = 0;
  }
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to configure input channel layout");
    goto cleanup;
  }

  av_channel_layout_default(&output_layout, channels);

  result = swr_alloc_set_opts2(
    &swr_context,
    &output_layout,
    AV_SAMPLE_FMT_FLT,
    target_rate,
    &input_layout,
    codec_context->sample_fmt,
    source_sample_rate,
    0,
    NULL
  );
  if (result < 0 || swr_context == NULL) {
    set_av_error(out_error_message, result, "failed to allocate resampler");
    goto cleanup;
  }

  result = swr_init(swr_context);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to initialize resampler");
    goto cleanup;
  }

  frame = av_frame_alloc();
  packet = av_packet_alloc();
  if (frame == NULL || packet == NULL) {
    set_error(out_error_message, "failed to allocate decode buffers");
    goto cleanup;
  }

  int64_t total_frame_count = 0;
  if (audio_stream->duration > 0) {
    total_frame_count = av_rescale_q(
      audio_stream->duration,
      audio_stream->time_base,
      (AVRational){1, target_rate}
    );
  } else if (format_context->duration > 0) {
    total_frame_count = av_rescale_q(
      format_context->duration,
      AV_TIME_BASE_Q,
      (AVRational){1, target_rate}
    );
  }

  if (start_frame > 0) {
    int64_t seek_timestamp = av_rescale_q(
      start_frame,
      (AVRational){1, target_rate},
      audio_stream->time_base
    );
    result = av_seek_frame(format_context, stream_index, seek_timestamp, AVSEEK_FLAG_BACKWARD);
    if (result < 0) {
      set_av_error(out_error_message, result, "failed to seek audio stream");
      goto cleanup;
    }
    avcodec_flush_buffers(codec_context);
    swr_close(swr_context);
    result = swr_init(swr_context);
    if (result < 0) {
      set_av_error(out_error_message, result, "failed to reinitialize resampler");
      goto cleanup;
    }
  }

  decoder->format_context = format_context;
  decoder->codec_context = codec_context;
  decoder->swr_context = swr_context;
  decoder->input_layout = input_layout;
  decoder->output_layout = output_layout;
  decoder->frame = frame;
  decoder->packet = packet;
  decoder->stream_index = stream_index;
  decoder->source_sample_rate = source_sample_rate;
  decoder->channels = channels;
  decoder->target_sample_rate = target_rate;
  decoder->frame_count = total_frame_count;
  decoder->finished = false;
  format_context = NULL;
  codec_context = NULL;
  swr_context = NULL;
  frame = NULL;
  packet = NULL;

  out_metadata->samples = NULL;
  out_metadata->sample_count = 0;
  out_metadata->channels = channels;
  out_metadata->sample_rate = (double)target_rate;
  out_metadata->frame_count = total_frame_count;
  fprintf(
    stderr,
    "[AudioCoreFFmpegBridge] stream open path=%s targetRate=%d sourceRate=%d channels=%d totalFrames=%lld startFrame=%lld\n",
    path,
    target_rate,
    source_sample_rate,
    channels,
    (long long)total_frame_count,
    (long long)start_frame
  );
  fflush(stderr);
  *out_decoder = (void *)decoder;
  return true;

cleanup:
  av_channel_layout_uninit(&input_layout);
  av_channel_layout_uninit(&output_layout);
  av_packet_free(&packet);
  av_frame_free(&frame);
  swr_free(&swr_context);
  avcodec_free_context(&codec_context);
  avformat_close_input(&format_context);
  free(decoder);
  return false;
}

bool audio_core_ffmpeg_open_stream(
  const char *path,
  double target_sample_rate,
  int64_t start_frame,
  AudioCoreFFmpegDecodedPCM *out_metadata,
  void **out_decoder,
  char **out_error_message
) {
  return open_stream_decoder(
    path,
    target_sample_rate,
    start_frame,
    out_metadata,
    out_decoder,
    out_error_message
  );
}

bool audio_core_ffmpeg_decode_stream_chunk(
  void *decoder_ptr,
  int64_t max_frames,
  AudioCoreFFmpegDecodedPCM *out_pcm,
  bool *out_is_eof,
  char **out_error_message
) {
  AudioCoreFFmpegStreamDecoder *decoder = (AudioCoreFFmpegStreamDecoder *)decoder_ptr;
  if (decoder == NULL || out_pcm == NULL || max_frames <= 0) {
    set_error(out_error_message, "invalid stream chunk arguments");
    return false;
  }

  memset(out_pcm, 0, sizeof(*out_pcm));
  if (out_is_eof != NULL) {
    *out_is_eof = false;
  }

  if (decoder->finished) {
    if (out_is_eof != NULL) {
      *out_is_eof = true;
    }
    fprintf(
      stderr,
      "[AudioCoreFFmpegBridge] stream chunk finished=1 eof=1 sampleCount=0 frameCount=0 maxFrames=%lld\n",
      (long long)max_frames
    );
    fflush(stderr);
    return true;
  }

  float *samples = NULL;
  int64_t sample_count = 0;
  int64_t sample_capacity = 0;
  int result = 0;
  bool success = false;
  bool reached_input_eof = false;

  for (;;) {
    if (sample_count / decoder->channels >= max_frames) {
      break;
    }

    result = av_read_frame(decoder->format_context, decoder->packet);
    if (result == AVERROR_EOF) {
      reached_input_eof = true;
      break;
    }
    if (result < 0) {
      if (is_ignorable_decode_error(result)) {
        av_packet_unref(decoder->packet);
        continue;
      }
      set_av_error(out_error_message, result, "failed to read packet");
      goto cleanup;
    }

    if (decoder->packet->stream_index != decoder->stream_index) {
      av_packet_unref(decoder->packet);
      continue;
    }

    result = avcodec_send_packet(decoder->codec_context, decoder->packet);
    av_packet_unref(decoder->packet);
    if (result < 0) {
      if (is_ignorable_decode_error(result)) {
        recover_from_decode_error(decoder->codec_context, decoder->frame);
        continue;
      }
      set_av_error(out_error_message, result, "failed to send packet to decoder");
      goto cleanup;
    }

    for (;;) {
      result = avcodec_receive_frame(decoder->codec_context, decoder->frame);
      if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
        break;
      }
      if (result < 0) {
        if (is_ignorable_decode_error(result)) {
          recover_from_decode_error(decoder->codec_context, decoder->frame);
          break;
        }
        set_av_error(out_error_message, result, "failed to receive decoded frame");
        goto cleanup;
      }

      if (!append_decoded_frame(
            decoder,
            decoder->frame,
            &samples,
            &sample_count,
            &sample_capacity,
            out_error_message
          )) {
        goto cleanup;
      }

      av_frame_unref(decoder->frame);
      if (sample_count / decoder->channels >= max_frames) {
        break;
      }
    }
  }

  if (reached_input_eof) {
    result = avcodec_send_packet(decoder->codec_context, NULL);
    if (result < 0 && result != AVERROR_EOF) {
      if (!is_ignorable_decode_error(result)) {
        set_av_error(out_error_message, result, "failed to flush decoder");
        goto cleanup;
      }
    }

    for (;;) {
      result = avcodec_receive_frame(decoder->codec_context, decoder->frame);
      if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) {
        if (result == AVERROR_EOF) {
          decoder->finished = true;
        }
        break;
      }
      if (result < 0) {
        if (is_ignorable_decode_error(result)) {
          recover_from_decode_error(decoder->codec_context, decoder->frame);
          break;
        }
        set_av_error(out_error_message, result, "failed to receive flushed frame");
        goto cleanup;
      }

      if (!append_decoded_frame(
            decoder,
            decoder->frame,
            &samples,
            &sample_count,
            &sample_capacity,
            out_error_message
          )) {
        goto cleanup;
      }

      av_frame_unref(decoder->frame);
      if (sample_count / decoder->channels >= max_frames) {
        break;
      }
    }
  }

  out_pcm->samples = samples;
  out_pcm->sample_count = sample_count;
  out_pcm->channels = decoder->channels;
  out_pcm->sample_rate = (double)decoder->target_sample_rate;
  out_pcm->frame_count = decoder->channels > 0 ? sample_count / decoder->channels : 0;
  samples = NULL;
  success = true;
  if (out_is_eof != NULL) {
    *out_is_eof = decoder->finished;
  }
  if (out_is_eof != NULL && out_pcm->frame_count == 0 && decoder->finished) {
    *out_is_eof = true;
  }

  fprintf(
    stderr,
    "[AudioCoreFFmpegBridge] stream chunk finished=%d eof=%d sampleCount=%lld frameCount=%lld maxFrames=%lld inputEof=%d reachedInputEof=%d\n",
    decoder->finished ? 1 : 0,
    (out_is_eof != NULL && *out_is_eof) ? 1 : 0,
    (long long)out_pcm->sample_count,
    (long long)out_pcm->frame_count,
    (long long)max_frames,
    decoder->finished ? 1 : 0,
    reached_input_eof ? 1 : 0
  );
  fflush(stderr);

cleanup:
  if (!success) {
    free(samples);
    free_pcm(out_pcm);
  }
  return success;
}

void audio_core_ffmpeg_close_stream(void *decoder_ptr) {
  close_stream_decoder((AudioCoreFFmpegStreamDecoder *)decoder_ptr);
}

bool audio_core_ffmpeg_decode_pcm(
  const char *path,
  AudioCoreFFmpegDecodedPCM *out_pcm,
  char **out_error_message
) {
  if (out_pcm == NULL || path == NULL || *path == '\0') {
    set_error(out_error_message, "invalid decode arguments");
    return false;
  }

  memset(out_pcm, 0, sizeof(*out_pcm));

  AVFormatContext *format_context = NULL;
  AVCodecContext *codec_context = NULL;
  SwrContext *swr_context = NULL;
  AVChannelLayout input_layout = {0};
  AVChannelLayout output_layout = {0};
  AVFrame *frame = NULL;
  AVPacket *packet = NULL;
  float *samples = NULL;
  int64_t sample_count = 0;
  int64_t sample_capacity = 0;
  bool success = false;

  int result = avformat_open_input(&format_context, path, NULL, NULL);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to open input");
    goto cleanup;
  }
  format_context->flags |= AVFMT_FLAG_DISCARD_CORRUPT;

  result = avformat_find_stream_info(format_context, NULL);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to read stream info");
    goto cleanup;
  }

  int stream_index = av_find_best_stream(
    format_context,
    AVMEDIA_TYPE_AUDIO,
    -1,
    -1,
    NULL,
    0
  );
  if (stream_index < 0) {
    set_error(out_error_message, "no audio stream found");
    goto cleanup;
  }

  AVStream *audio_stream = format_context->streams[stream_index];
  const AVCodec *codec = avcodec_find_decoder(audio_stream->codecpar->codec_id);
  if (codec == NULL) {
    set_error(out_error_message, "no decoder found for audio stream");
    goto cleanup;
  }

  codec_context = avcodec_alloc_context3(codec);
  if (codec_context == NULL) {
    set_error(out_error_message, "failed to allocate codec context");
    goto cleanup;
  }

  result = avcodec_parameters_to_context(codec_context, audio_stream->codecpar);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to copy codec parameters");
    goto cleanup;
  }

  result = avcodec_open2(codec_context, codec, NULL);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to open codec");
    goto cleanup;
  }

  int sample_rate = codec_context->sample_rate > 0
    ? codec_context->sample_rate
    : audio_stream->codecpar->sample_rate;
  if (sample_rate <= 0) {
    sample_rate = 44100;
  }

  int channels = codec_context->ch_layout.nb_channels > 0
    ? codec_context->ch_layout.nb_channels
    : audio_stream->codecpar->ch_layout.nb_channels;
  if (channels <= 0) {
    channels = 2;
  }

  if (codec_context->ch_layout.nb_channels > 0) {
    result = av_channel_layout_copy(&input_layout, &codec_context->ch_layout);
  } else if (audio_stream->codecpar->ch_layout.nb_channels > 0) {
    result = av_channel_layout_copy(&input_layout, &audio_stream->codecpar->ch_layout);
  } else {
    av_channel_layout_default(&input_layout, channels);
    result = 0;
  }
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to configure input channel layout");
    goto cleanup;
  }

  av_channel_layout_default(&output_layout, channels);

  result = swr_alloc_set_opts2(
    &swr_context,
    &output_layout,
    AV_SAMPLE_FMT_FLT,
    sample_rate,
    &input_layout,
    codec_context->sample_fmt,
    sample_rate,
    0,
    NULL
  );
  if (result < 0 || swr_context == NULL) {
    set_av_error(out_error_message, result, "failed to allocate resampler");
    goto cleanup;
  }

  result = swr_init(swr_context);
  if (result < 0) {
    set_av_error(out_error_message, result, "failed to initialize resampler");
    goto cleanup;
  }

  frame = av_frame_alloc();
  packet = av_packet_alloc();
  if (frame == NULL || packet == NULL) {
    set_error(out_error_message, "failed to allocate decode buffers");
    goto cleanup;
  }

  for (;;) {
    result = av_read_frame(format_context, packet);
    if (result == AVERROR_EOF) {
      break;
    }
    if (result < 0) {
      if (is_ignorable_decode_error(result)) {
        av_packet_unref(packet);
        continue;
      }
      set_av_error(out_error_message, result, "failed to read packet");
      goto cleanup;
    }

    if (packet->stream_index != stream_index) {
      av_packet_unref(packet);
      continue;
    }

    result = avcodec_send_packet(codec_context, packet);
    av_packet_unref(packet);
    if (result < 0) {
      if (is_ignorable_decode_error(result)) {
        recover_from_decode_error(codec_context, frame);
        continue;
      }
      set_av_error(out_error_message, result, "failed to send packet to decoder");
      goto cleanup;
    }

    for (;;) {
      result = avcodec_receive_frame(codec_context, frame);
      if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
        break;
      }
      if (result < 0) {
        if (is_ignorable_decode_error(result)) {
          recover_from_decode_error(codec_context, frame);
          break;
        }
        set_av_error(out_error_message, result, "failed to receive decoded frame");
        goto cleanup;
      }

      int64_t delay = swr_get_delay(swr_context, sample_rate);
      int dst_nb_samples = (int)av_rescale_rnd(
        delay + frame->nb_samples,
        sample_rate,
        sample_rate,
        AV_ROUND_UP
      );
      if (dst_nb_samples <= 0) {
        av_frame_unref(frame);
        continue;
      }

      uint8_t **converted_data = NULL;
      int converted_linesize = 0;
      result = av_samples_alloc_array_and_samples(
        &converted_data,
        &converted_linesize,
        channels,
        dst_nb_samples,
        AV_SAMPLE_FMT_FLT,
        0
      );
      if (result < 0 || converted_data == NULL) {
        set_av_error(out_error_message, result, "failed to allocate resample buffer");
        if (converted_data != NULL) {
          av_freep(&converted_data[0]);
          av_freep(&converted_data);
        }
        goto cleanup;
      }

      const uint8_t **input_data = (const uint8_t **)frame->extended_data;
      int converted_frames = swr_convert(
        swr_context,
        converted_data,
        dst_nb_samples,
        input_data,
        frame->nb_samples
      );
      if (converted_frames < 0) {
        set_av_error(out_error_message, converted_frames, "failed to resample audio");
        av_freep(&converted_data[0]);
        av_freep(&converted_data);
        goto cleanup;
      }

      int64_t produced_samples = (int64_t)converted_frames * channels;
      if (!append_samples(
            &samples,
            &sample_count,
            &sample_capacity,
            (const float *)converted_data[0],
            produced_samples
          )) {
        set_error(out_error_message, "failed to append decoded samples");
        av_freep(&converted_data[0]);
        av_freep(&converted_data);
        goto cleanup;
      }

      av_freep(&converted_data[0]);
      av_freep(&converted_data);
      av_frame_unref(frame);
    }
  }

  result = avcodec_send_packet(codec_context, NULL);
  if (result < 0 && result != AVERROR_EOF) {
    if (!is_ignorable_decode_error(result)) {
      set_av_error(out_error_message, result, "failed to flush decoder");
      goto cleanup;
    }
  }

  for (;;) {
    result = avcodec_receive_frame(codec_context, frame);
    if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) {
      break;
    }
    if (result < 0) {
      if (is_ignorable_decode_error(result)) {
        recover_from_decode_error(codec_context, frame);
        break;
      }
      set_av_error(out_error_message, result, "failed to receive flushed frame");
      goto cleanup;
    }

    int64_t delay = swr_get_delay(swr_context, sample_rate);
    int dst_nb_samples = (int)av_rescale_rnd(
      delay + frame->nb_samples,
      sample_rate,
      sample_rate,
      AV_ROUND_UP
    );
    if (dst_nb_samples <= 0) {
      av_frame_unref(frame);
      continue;
    }

    uint8_t **converted_data = NULL;
    int converted_linesize = 0;
    result = av_samples_alloc_array_and_samples(
      &converted_data,
      &converted_linesize,
      channels,
      dst_nb_samples,
      AV_SAMPLE_FMT_FLT,
      0
    );
    if (result < 0 || converted_data == NULL) {
      set_av_error(out_error_message, result, "failed to allocate resample buffer");
      if (converted_data != NULL) {
        av_freep(&converted_data[0]);
        av_freep(&converted_data);
      }
      goto cleanup;
    }

    int converted_frames = swr_convert(
      swr_context,
      converted_data,
      dst_nb_samples,
      (const uint8_t **)frame->extended_data,
      frame->nb_samples
    );
    if (converted_frames < 0) {
      set_av_error(out_error_message, converted_frames, "failed to resample audio");
      av_freep(&converted_data[0]);
      av_freep(&converted_data);
      goto cleanup;
    }

    int64_t produced_samples = (int64_t)converted_frames * channels;
    if (!append_samples(
          &samples,
          &sample_count,
          &sample_capacity,
          (const float *)converted_data[0],
          produced_samples
        )) {
      set_error(out_error_message, "failed to append decoded samples");
      av_freep(&converted_data[0]);
      av_freep(&converted_data);
      goto cleanup;
    }

    av_freep(&converted_data[0]);
    av_freep(&converted_data);
    av_frame_unref(frame);
  }

  out_pcm->samples = samples;
  out_pcm->sample_count = sample_count;
  out_pcm->channels = channels;
  out_pcm->sample_rate = (double)sample_rate;
  out_pcm->frame_count = channels > 0 ? sample_count / channels : 0;
  samples = NULL;
  success = true;

cleanup:
  if (!success) {
    free_pcm(out_pcm);
    free(samples);
  }
  av_channel_layout_uninit(&input_layout);
  av_channel_layout_uninit(&output_layout);
  av_packet_free(&packet);
  av_frame_free(&frame);
  swr_free(&swr_context);
  avcodec_free_context(&codec_context);
  avformat_close_input(&format_context);
  return success;
}

void audio_core_ffmpeg_free_pcm(AudioCoreFFmpegDecodedPCM *pcm) {
  free_pcm(pcm);
}

void audio_core_ffmpeg_free_error(char *error_message) {
  free(error_message);
}
