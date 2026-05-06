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
      set_av_error(out_error_message, result, "failed to send packet to decoder");
      goto cleanup;
    }

    for (;;) {
      result = avcodec_receive_frame(codec_context, frame);
      if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
        break;
      }
      if (result < 0) {
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
    set_av_error(out_error_message, result, "failed to flush decoder");
    goto cleanup;
  }

  for (;;) {
    result = avcodec_receive_frame(codec_context, frame);
    if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) {
      break;
    }
    if (result < 0) {
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
