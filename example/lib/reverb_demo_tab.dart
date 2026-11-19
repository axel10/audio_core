import 'package:audio_core/audio_core.dart';
import 'package:flutter/material.dart';

class ReverbDemoTab extends StatefulWidget {
  final AudioCoreController controller;

  const ReverbDemoTab({super.key, required this.controller});

  @override
  State<ReverbDemoTab> createState() => _ReverbDemoTabState();
}

class _ReverbDemoTabState extends State<ReverbDemoTab> {
  ReverbConfig _config = const ReverbConfig(
    enabled: false,
    algorithm: ReverbAlgorithm.freeverb,
    dryMix: 0.90,
    wetMix: 0.22,
    roomSize: 0.70,
    damping: 0.50,
    width: 0.85,
    timeSeconds: 3.02,
    freeze: false,
  );

  @override
  void initState() {
    super.initState();
    _loadCurrentConfig();
  }

  Future<void> _loadCurrentConfig() async {
    try {
      final loaded = await widget.controller.getReverbConfig();
      if (!mounted) return;
      setState(() => _config = loaded);
    } catch (_) {
      // Keep default Concert Hall preset if engine hasn't initialized yet.
    }
  }

  Future<void> _updateConfig(ReverbConfig next) async {
    setState(() => _config = next);
    await widget.controller.setReverbConfig(next);
  }

  void _applyConcertHallPreset() {
    _updateConfig(
      const ReverbConfig(
        enabled: true,
        algorithm: ReverbAlgorithm.freeverb,
        dryMix: 0.90,
        wetMix: 0.22,
        roomSize: 0.70,
        damping: 0.50,
        width: 0.85,
        timeSeconds: 3.02,
        freeze: false,
      ),
    );
  }

  void _applyFundspFdnPreset() {
    _updateConfig(
      const ReverbConfig(
        enabled: true,
        algorithm: ReverbAlgorithm.fundspStereo,
        dryMix: 0.90,
        wetMix: 1.00,
        roomSize: 0.88,
        damping: 1.00,
        width: 0.85,
        timeSeconds: 3.02,
        freeze: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFreeverb = _config.algorithm == ReverbAlgorithm.freeverb;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 0,
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Concert Hall Reverb (MAX Audio)',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isFreeverb
                              ? 'Rust Freeverb (Concert Hall)'
                              : 'FunDSP 32-ch FDN Stereo Reverb',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _config.enabled,
                    onChanged: (value) => _updateConfig(
                      _copyConfig(enabled: value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'DSP Algorithm (A/B Compare)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SegmentedButton<ReverbAlgorithm>(
                segments: const [
                  ButtonSegment(
                    value: ReverbAlgorithm.freeverb,
                    label: Text('Freeverb'),
                    icon: Icon(Icons.graphic_eq),
                  ),
                  ButtonSegment(
                    value: ReverbAlgorithm.fundspStereo,
                    label: Text('FunDSP FDN'),
                    icon: Icon(Icons.surround_sound),
                  ),
                ],
                selected: {_config.algorithm},
                onSelectionChanged: (selection) {
                  _updateConfig(_copyConfig(algorithm: selection.first));
                },
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _applyConcertHallPreset,
                    icon: const Icon(Icons.restore),
                    label: const Text('Freeverb 音乐厅预设'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _applyFundspFdnPreset,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('FunDSP FDN 预设'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildSlider(
                label: 'Dry Mix (干声比例)',
                value: _config.dryMix,
                min: 0.0,
                max: 1.5,
                onChanged: (v) => _updateConfig(_copyConfig(dryMix: v)),
              ),
              _buildSlider(
                label: 'Wet Mix (混响湿声)',
                value: _config.wetMix,
                min: 0.0,
                max: 1.5,
                onChanged: (v) => _updateConfig(_copyConfig(wetMix: v)),
              ),
              _buildSlider(
                label: 'Room Size (房间大小)',
                value: _config.roomSize,
                min: 0.0,
                max: 1.0,
                onChanged: (v) => _updateConfig(_copyConfig(roomSize: v)),
              ),
              _buildSlider(
                label: 'Damping (高频阻尼)',
                value: _config.damping,
                min: 0.0,
                max: 1.0,
                onChanged: (v) => _updateConfig(_copyConfig(damping: v)),
              ),
              if (isFreeverb) ...[
                _buildSlider(
                  label: 'Stereo Width (立体声宽度)',
                  value: _config.width,
                  min: 0.0,
                  max: 1.0,
                  onChanged: (v) => _updateConfig(_copyConfig(width: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Freeze Tail (冻结混响尾音)'),
                  value: _config.freeze,
                  onChanged: (v) => _updateConfig(_copyConfig(freeze: v)),
                ),
              ] else
                _buildSlider(
                  label: 'Reverb Time RT60 (秒)',
                  value: _config.timeSeconds,
                  min: 0.3,
                  max: 8.0,
                  unit: 's',
                  onChanged: (v) => _updateConfig(_copyConfig(timeSeconds: v)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  ReverbConfig _copyConfig({
    bool? enabled,
    ReverbAlgorithm? algorithm,
    double? dryMix,
    double? wetMix,
    double? roomSize,
    double? damping,
    double? width,
    double? timeSeconds,
    bool? freeze,
  }) {
    return ReverbConfig(
      enabled: enabled ?? _config.enabled,
      algorithm: algorithm ?? _config.algorithm,
      dryMix: dryMix ?? _config.dryMix,
      wetMix: wetMix ?? _config.wetMix,
      roomSize: roomSize ?? _config.roomSize,
      damping: damping ?? _config.damping,
      width: width ?? _config.width,
      timeSeconds: timeSeconds ?? _config.timeSeconds,
      freeze: freeze ?? _config.freeze,
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    String unit = '',
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              '${value.toStringAsFixed(2)}$unit',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
