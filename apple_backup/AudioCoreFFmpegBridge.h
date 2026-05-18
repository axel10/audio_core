#ifndef AUDIO_CORE_FFMPEG_BRIDGE_H
#define AUDIO_CORE_FFMPEG_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  float *samples;
  int64_t sample_count;
  int32_t channels;
  double sample_rate;
  int64_t frame_count;
} AudioCoreFFmpegDecodedPCM;

bool audio_core_ffmpeg_decode_pcm(
  const char *path,
  AudioCoreFFmpegDecodedPCM *out_pcm,
  char **out_error_message
);

bool audio_core_ffmpeg_open_stream(
  const char *path,
  double target_sample_rate,
  int64_t start_frame,
  AudioCoreFFmpegDecodedPCM *out_metadata,
  void **out_decoder,
  char **out_error_message
);

bool audio_core_ffmpeg_decode_stream_chunk(
  void *decoder,
  int64_t max_frames,
  AudioCoreFFmpegDecodedPCM *out_pcm,
  bool *out_is_eof,
  char **out_error_message
);

void audio_core_ffmpeg_close_stream(void *decoder);

void audio_core_ffmpeg_free_pcm(AudioCoreFFmpegDecodedPCM *pcm);
void audio_core_ffmpeg_free_error(char *error_message);

#endif /* AUDIO_CORE_FFMPEG_BRIDGE_H */
