import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_core/audio_core.dart';

typedef BandGainChanged = void Function(int index, double value);

class EqualizerPanel extends StatelessWidget {
  final AudioCoreController controller;

  const EqualizerPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.equalizer,
      builder: (context, _) {
        final equalizer = controller.equalizer;
        final config = equalizer.config;
        final isAdvanced = equalizer.isAdvanced;

        final isAndroid = Platform.isAndroid;

        return Card(
          elevation: 0,
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, equalizer, config, isAndroid),
                const SizedBox(height: 16),
                if (isAdvanced || !isAndroid)
                  _buildAdvancedControls(context, equalizer, config)
                else
                  _buildSystemControls(context, equalizer),
                const SizedBox(height: 20),
                _buildEqualizerBands(context, equalizer, config, isAndroid),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    EqualizerController equalizer,
    EqualizerConfig config,
    bool isAndroid,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Audio Equalizer',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isAndroid)
                    Text(
                      equalizer.isAdvanced
                          ? 'Custom C++ Engine'
                          : 'Android System',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (isAndroid) ...[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Advanced Mode', style: TextStyle(fontSize: 11)),
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 28,
                    child: Switch(
                      value: equalizer.isAdvanced,
                      onChanged: (value) =>
                          unawaited(equalizer.setAdvanced(value)),
                      activeThumbColor: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 20),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Enabled', style: TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                SizedBox(
                  height: 28,
                  child: Switch(
                    value: config.enabled,
                    onChanged: (value) =>
                        unawaited(equalizer.setEnabled(value)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAdvancedControls(
    BuildContext context,
    EqualizerController equalizer,
    EqualizerConfig config,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildSlider(
                context,
                label: 'Preamp (Master Gain)',
                value: config.preampDb,
                min: -15,
                max: 15,
                onChanged: (value) => unawaited(equalizer.setPreamp(value)),
                color: Colors.deepPurpleAccent,
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bands', style: Theme.of(context).textTheme.labelLarge),
                DropdownButton<int>(
                  value: config.bandCount,
                  items: [5, 10, 15, 20].map((int value) {
                    return DropdownMenuItem<int>(
                      value: value,
                      child: Text('$value Bands'),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(equalizer.setBandCount(value));
                    }
                  },
                ),
              ],
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: equalizer.resetDefaults,
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset',
            ),
          ],
        ),
        Text(
          'Custom C++ equalizer with high precision biquad filters.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontStyle: FontStyle.italic,
            color: Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildSystemControls(
    BuildContext context,
    EqualizerController equalizer,
  ) {
    return Row(
      children: [
        Expanded(
          child: _buildSlider(
            context,
            label: 'System Bass Boost',
            value: equalizer.systemBassBoostDb,
            min: 0,
            max: 15,
            onChanged: (value) =>
                unawaited(equalizer.setSystemBassBoost(value)),
          ),
        ),
        const SizedBox(width: 16),
        IconButton(
          onPressed: equalizer.resetDefaults,
          icon: const Icon(Icons.refresh),
          tooltip: 'Reset',
        ),
      ],
    );
  }

  Widget _buildEqualizerBands(
    BuildContext context,
    EqualizerController equalizer,
    EqualizerConfig config,
    bool isAndroid,
  ) {
    final int bandCount;
    final List<String> labels;
    final List<double> gains;
    final BandGainChanged onGainChanged;

    if (!isAndroid || equalizer.isAdvanced) {
      bandCount = config.bandCount;
      final centers = equalizer.getBandCenters();
      labels = centers.map((f) => _formatBandFrequency(f)).toList();
      gains = config.bandGainsDb.toList().sublist(0, bandCount);
      onGainChanged = (idx, val) => unawaited(equalizer.setBandGain(idx, val));
    } else {
      final params = equalizer.systemParams;
      bandCount = params?['numBands'] ?? 5;
      final List<dynamic> freqs = params?['frequencies'] ?? [];
      labels = freqs.map((f) {
        double hz = (f as int) / 1000.0;
        if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(1)}k';
        return hz.toInt().toString();
      }).toList();
      gains = List.generate(bandCount, (i) => equalizer.getSystemBandGain(i));
      onGainChanged = (idx, val) =>
          unawaited(equalizer.setSystemBandGain(idx, val));
    }

    return SizedBox(
      height: 220,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: bandCount,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final gain = gains[index];
          final label = index < labels.length ? labels[index] : '';

          return SizedBox(
            width: 48,
            child: Column(
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: RotatedBox(
                    quarterTurns: -1,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                      ),
                      child: Slider(
                        value: gain.clamp(-15.0, 15.0),
                        min: -15,
                        max: 15,
                        divisions: 30,
                        onChanged: (value) => onGainChanged(index, value),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(0)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          );
        },
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
    Color? color,
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
          activeColor: color,
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
