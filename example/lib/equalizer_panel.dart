import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audio_visualizer_player/audio_visualizer_player.dart';

class EqualizerPanel extends StatelessWidget {
  final AudioVisualizerPlayerController controller;

  const EqualizerPanel({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final config = controller.equalizerConfig;
    final bandCount = config.bandCount.clamp(
      0,
      AudioVisualizerPlayerController.maxEqualizerBands,
    );
    final bandCenters = controller.getEqualizerBandCenters(
      bandCount: bandCount,
    );

    return Card(
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Equalizer',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 12),
                Switch(
                  value: config.enabled,
                  onChanged: (value) =>
                      unawaited(controller.setEqualizerEnabled(value)),
                ),
                const Spacer(),
                DropdownButton<int>(
                  value: bandCount == 0 ? 1 : bandCount,
                  items: List.generate(
                    AudioVisualizerPlayerController.maxEqualizerBands,
                    (index) {
                      final value = index + 1;
                      return DropdownMenuItem(
                        value: value,
                        child: Text('$value bands'),
                      );
                    },
                  ),
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(controller.setEqualizerBandCount(value));
                    }
                  },
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: controller.resetEqualizerDefaults,
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildSlider(
                    context,
                    label: 'Preamp',
                    value: config.preampDb,
                    min: -12,
                    max: 12,
                    onChanged: (value) =>
                        unawaited(controller.setEqualizerPreamp(value)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSlider(
                    context,
                    label: 'Bass Boost',
                    value: config.bassBoostDb,
                    min: 0,
                    max: 12,
                    onChanged: (value) =>
                        unawaited(controller.setBassBoost(value)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: bandCount <= 0
                  ? const Center(child: Text('EQ is disabled by band count.'))
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: bandCount,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final gain = config.bandGainsDb[index].toDouble();
                        final freq = bandCenters[index];
                        return SizedBox(
                          width: 44,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatBandFrequency(freq),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: -1,
                                  child: Slider(
                                    value: gain.clamp(-12.0, 12.0),
                                    min: -12,
                                    max: 12,
                                    divisions: 48,
                                    onChanged: (value) => unawaited(
                                      controller.setEqualizerBandGain(
                                        index,
                                        value,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) * 2).round(),
          label: value.toStringAsFixed(1),
          onChanged: onChanged,
        ),
        Text(
          '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} dB',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }

  String _formatBandFrequency(double hz) {
    if (hz >= 1000) {
      return '${(hz / 1000).toStringAsFixed(hz >= 10_000 ? 0 : 1)}k';
    }
    return hz.round().toString();
  }
}
