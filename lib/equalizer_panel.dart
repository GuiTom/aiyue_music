part of 'main.dart';

extension _EqualizerControls on _PlayerPageState {
  Future<void> openEqualizer() async {
    if (!Platform.isAndroid || playbackService == null) {
      message('均衡器目前支持 Android');
      return;
    }
    if (current < 0 || player.processingState == ProcessingState.idle) {
      message('请先播放一首歌曲，再调整均衡器');
      return;
    }
    try {
      final parameters = await playbackService!.equalizer.parameters.timeout(
        const Duration(seconds: 5),
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => EqualizerPanel(
          equalizer: playbackService!.equalizer,
          parameters: parameters,
        ),
      );
    } catch (e) {
      message('此设备暂时无法使用均衡器：$e');
    }
  }
}

class EqualizerPanel extends StatefulWidget {
  const EqualizerPanel({
    super.key,
    required this.equalizer,
    required this.parameters,
  });
  final AndroidEqualizer equalizer;
  final AndroidEqualizerParameters parameters;
  @override
  State<EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<EqualizerPanel> {
  bool busy = false;
  String? error;
  Future<void> change(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('eqEnabled', widget.equalizer.enabled);
      await prefs.setStringList(
        'eqGains',
        widget.parameters.bands.map((b) => b.gain.toString()).toList(),
      );
    } catch (e) {
      error = '音效调整失败：$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> preset(String name) => change(() async {
    final bands = widget.parameters.bands;
    for (var i = 0; i < bands.length; i++) {
      final f = bands[i].centerFrequency;
      final gain = switch (name) {
        // XBS-inspired bass contour, not a reproduction of Panasonic's DSP.
        // Interpolate in log-frequency space for different device band layouts.
        'XBS' || '松下随身听 XBS' => _xbsGain(f),
        '低音' => f < 250 ? 5.0 : (f < 1000 ? 2.0 : 0.0),
        '人声' => f >= 500 && f <= 4000 ? 3.0 : -2.0,
        '流行' => f < 250 || f > 4000 ? 3.0 : 1.0,
        _ => 0.0,
      };
      await bands[i].setGain(
        gain.clamp(
          widget.parameters.minDecibels,
          widget.parameters.maxDecibels,
        ),
      );
    }
    await widget.equalizer.setEnabled(true);
  });

  double _xbsGain(double frequency) {
    const points = [
      (60.0, 4.0),
      (200.0, 2.0),
      (910.0, 0.0),
      (3600.0, 2.0),
      (14000.0, 1.0),
    ];
    if (frequency <= points.first.$1) return points.first.$2;
    for (var i = 1; i < points.length; i++) {
      final (low, lowGain) = points[i - 1];
      final (high, highGain) = points[i];
      if (frequency <= high) {
        final mix = log(frequency / low) / log(high / low);
        return lowGain + (highGain - lowGain) * mix;
      }
    }
    return points.last.$2;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '均衡器',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('实时调节 · 设置自动保存'),
              value: widget.equalizer.enabled,
              onChanged: busy
                  ? null
                  : (v) => change(() => widget.equalizer.setEnabled(v)),
            ),
            Wrap(
              spacing: 8,
              children: ['平直', '低音', '人声', '流行', 'XBS']
                  .map(
                    (name) => ActionChip(
                      label: Text(name),
                      onPressed: busy ? null : () => preset(name),
                    ),
                  )
                  .toList(),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'XBS：60Hz +4 · 200Hz +2 · 910Hz 0 · 3.6kHz +2 · 14kHz +1 dB',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orange)),
            const SizedBox(height: 14),
            for (final band in widget.parameters.bands)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 62,
                      child: Text(
                        band.centerFrequency >= 1000
                            ? '${(band.centerFrequency / 1000).toStringAsFixed(1)}k Hz'
                            : '${band.centerFrequency.round()} Hz',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        min: widget.parameters.minDecibels,
                        max: widget.parameters.maxDecibels,
                        value: band.gain.clamp(
                          widget.parameters.minDecibels,
                          widget.parameters.maxDecibels,
                        ),
                        onChanged: busy || !widget.equalizer.enabled
                            ? null
                            : (v) => change(() => band.setGain(v)),
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Text(
                        '${band.gain.toStringAsFixed(1)} dB',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            const Text(
              '频段与增益范围由设备提供。增益较高时建议降低音量，避免失真。',
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}
