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

void audio_core_ffmpeg_free_pcm(AudioCoreFFmpegDecodedPCM *pcm);
void audio_core_ffmpeg_free_error(char *error_message);

#endif /* AUDIO_CORE_FFMPEG_BRIDGE_H */
