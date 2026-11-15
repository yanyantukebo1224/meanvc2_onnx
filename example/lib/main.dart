import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:flutter_pcm_sound_spm/flutter_pcm_sound_spm.dart';
import 'package:meanvc2_onnx/meanvc2_onnx.dart';
import 'package:path_provider/path_provider.dart';

const _variant = ModelVariant.int8;
const _threads = 2;

void main() => runApp(const MeanVcApp());

class MeanVcApp extends StatelessWidget {
  const MeanVcApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF8B7CFF);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MeanVC2',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF111522),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0E17),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0E17),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF151A29),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      home: const StudioPage(),
    );
  }
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  final _player = AudioPlayer();
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSubscription;
  MeanVc2Stream? _liveEngine;
  Float32List _liveInput = Float32List(0);
  Future<void> _liveQueue = Future<void>.value();
  bool _liveStarting = false;
  bool _liveActive = false;
  int _liveChunks = 0;
  double _liveLatencyMs = 0;
  String? _referencePath;
  String? _sourcePath;
  String? _outputPath;
  String _status = 'モデルを準備しています';
  String _currentFile = '';
  bool _downloading = true;
  bool _converting = false;
  bool _modelsReady = false;
  double _downloadProgress = 0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  double _conversionProgress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepareModels();
  }

  @override
  void dispose() {
    unawaited(_disposeAudio());
    _player.dispose();
    super.dispose();
  }

  Future<void> _disposeAudio() async {
    await _stopLive();
    await _recorder.dispose();
  }

  Future<String> get _modelDirectory async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/meanvc2_onnx';
  }

  Future<void> _prepareModels() async {
    setState(() {
      _downloading = true;
      _status = 'モデルを確認しています';
      _error = null;
    });
    try {
      final dir = await _modelDirectory;
      await MeanVc2Models.download(
        dir,
        files: MeanVc2Models.files(_variant, speaker: _variant),
        onFile: (file) {
          if (!mounted) return;
          setState(() {
            _currentFile = file;
            _status = 'ダウンロード中';
          });
        },
        onProgress: (file, received, fileBytes, completed, total) {
          if (!mounted) return;
          setState(() {
            _currentFile = file;
            _downloadedBytes = completed;
            _totalBytes = total;
            _downloadProgress = total == 0 ? 0 : completed / total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _modelsReady = true;
        _downloading = false;
        _downloadProgress = 1;
        _status = 'すべてのモデルが準備できました';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _modelsReady = false;
        _error = e.toString();
        _status = 'モデルの準備に失敗しました';
      });
    }
  }

  Future<String?> _pickWav(String title) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['wav'],
      dialogTitle: title,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final dir = await getTemporaryDirectory();
    final saved = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_${file.name}');
    await saved.writeAsBytes(bytes, flush: true);
    return saved.path;
  }

  Future<void> _pickReference() async {
    try {
      final path = await _pickWav('変換先の声（お手本）を選択');
      if (path != null && mounted) setState(() => _referencePath = path);
    } catch (e) {
      _showError('音声ファイルを開けませんでした: $e');
    }
  }

  Future<void> _pickSource() async {
    try {
      final path = await _pickWav('変換したい音声を選択');
      if (path != null && mounted) setState(() => _sourcePath = path);
    } catch (e) {
      _showError('音声ファイルを開けませんでした: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _exportResult() async {
    final path = _outputPath;
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      final saved = await FilePicker.saveFile(
        dialogTitle: '変換した音声を書き出す',
        fileName: 'MeanVC2_output.wav',
        bytes: bytes,
      );
      if (saved != null && mounted) _showError('WAVを書き出しました');
    } catch (e) {
      _showError('書き出しに失敗しました: $e');
    }
  }

  Future<void> _startLive() async {
    if (_liveStarting || _liveActive || !_modelsReady || _referencePath == null) return;
    setState(() {
      _liveStarting = true;
      _status = 'リアルタイム変換を準備しています';
      _error = null;
    });
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('マイクへのアクセスが許可されていません');
      }
      final dir = await _modelDirectory;
      final reference = _readWav16k(await File(_referencePath!).readAsBytes());
      if (reference.length < 16000) {
        throw const FormatException('お手本音声は1秒以上のWAVを選択してください');
      }
      final encoder = await SpeakerEncoder.load(
        '$dir/${MeanVc2Models.speakerFileName(_variant)}',
        threads: _threads,
      );
      Float32List embedding;
      try {
        embedding = await encoder.embed(reference);
      } finally {
        await encoder.close();
      }
      final engine = await MeanVc2Stream.load(
        dir,
        variant: _variant,
        threads: _threads,
        steps: 2,
      );
      await engine.setTarget(embedding);
      _liveEngine = engine;

      await FlutterPcmSound.setup(
        sampleRate: 16000,
        channelCount: 1,
        iosAudioCategory: IosAudioCategory.playAndRecord,
      );
      await FlutterPcmSound.setFeedThreshold(3840);
      _liveInput = Float32List(0);
      _liveChunks = 0;
      final micStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
          streamBufferSize: 3200,
        ),
      );
      _micSubscription = micStream.listen(
        _onMicrophoneData,
        onError: (Object error) {
          _showError('マイク入力エラー: $error');
          _stopLive();
        },
        onDone: () {
          if (_liveActive) _stopLive();
        },
        cancelOnError: true,
      );
      if (!mounted) return;
      setState(() {
        _liveActive = true;
        _liveStarting = false;
        _status = 'リアルタイム変換中';
      });
    } catch (e) {
      await _stopLive();
      if (!mounted) return;
      setState(() {
        _liveStarting = false;
        _liveActive = false;
        _error = e.toString();
        _status = 'リアルタイム変換を開始できませんでした';
      });
    }
  }

  void _onMicrophoneData(Uint8List bytes) {
    if (!_liveActive && !_liveStarting) return;
    final evenLength = bytes.length - (bytes.length.isOdd ? 1 : 0);
    if (evenLength <= 0) return;
    final data = ByteData.sublistView(bytes, 0, evenLength);
    final incoming = Float32List(evenLength ~/ 2);
    for (var i = 0; i < incoming.length; i++) {
      incoming[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    final joined = Float32List(_liveInput.length + incoming.length);
    joined.setAll(0, _liveInput);
    joined.setAll(_liveInput.length, incoming);
    _liveInput = joined;
    _liveQueue = _liveQueue.then((_) => _drainLiveInput()).catchError((Object error) {
      _showError('リアルタイム推論エラー: $error');
      Future<void>.delayed(Duration.zero).then((_) => _stopLive());
    });
  }

  Future<void> _drainLiveInput() async {
    while (_liveInput.length >= kChunk && (_liveActive || _liveStarting)) {
      final chunk = Float32List.fromList(_liveInput.sublist(0, kChunk));
      _liveInput = Float32List.fromList(_liveInput.sublist(kChunk));
      final engine = _liveEngine;
      if (engine == null) return;
      final watch = Stopwatch()..start();
      final converted = await engine.process(chunk);
      _liveLatencyMs = watch.elapsedMicroseconds / 1000;
      if (converted.isNotEmpty) {
        final pcm = <int>[];
        for (final sample in converted) {
          // Soft limiting prevents clipped peaks without abrupt hard clipping.
          final limited = math.tanh(sample * 1.25);
          pcm.add((limited * 32767).round().clamp(-32768, 32767));
        }
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
      }
      _liveChunks++;
      if (mounted && _liveChunks % 5 == 0) {
        setState(() => _status = 'リアルタイム変換中 · $_liveChunks chunks');
      }
    }
  }

  Future<void> _stopLive() async {
    final wasActive = _liveActive || _liveStarting || _liveEngine != null;
    _liveActive = false;
    _liveStarting = false;
    await _micSubscription?.cancel();
    _micSubscription = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    await _liveQueue;
    await _liveEngine?.close();
    _liveEngine = null;
    _liveInput = Float32List(0);
    if (wasActive) {
      try {
        await FlutterPcmSound.release();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _liveActive = false;
        _liveStarting = false;
        _status = _modelsReady ? 'モデルの準備ができています' : _status;
      });
    }
  }

  Widget _liveCard() {
    final canStart = _modelsReady && _referencePath != null && !_liveStarting && !_liveActive && !_converting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('リアルタイム変換', 'マイク入力をその場でMeanVC2変換', Icons.mic_rounded),
            const SizedBox(height: 12),
            Text(
              _referencePath == null
                  ? '先に「TARGET VOICE」でお手本の声を選択してください。'
                  : '変換先: ${_referencePath!.split(Platform.pathSeparator).last}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 12),
            if (_liveActive) ...[
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  const Text('LIVE', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                  const Spacer(),
                  Text('$_liveChunks chunks', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                minHeight: 4,
                value: null,
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFF8B7CFF),
                backgroundColor: Colors.white10,
              ),
              const SizedBox(height: 8),
              Text('直近の推論時間: ${_liveLatencyMs.toStringAsFixed(0)} ms', style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _liveActive ? _stopLive : (canStart ? _startLive : null),
                icon: _liveStarting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_liveActive ? Icons.stop_rounded : Icons.mic_rounded),
                label: Text(_liveStarting ? '準備中...' : (_liveActive ? 'リアルタイム変換を停止' : 'マイクでリアルタイム変換')),
                style: FilledButton.styleFrom(
                  backgroundColor: _liveActive ? const Color(0xFFB94E62) : const Color(0xFF7565ED),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '初回出力にはモデルの先読み分として約0.3〜0.4秒かかります。イヤホン推奨。',
              style: TextStyle(fontSize: 10, color: Colors.white38, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _convert() async {
    if (_referencePath == null || _sourcePath == null || _converting) return;
    if (!_modelsReady) {
      _showError('先にモデルのダウンロードを完了してください');
      return;
    }
    setState(() {
      _converting = true;
      _conversionProgress = 0;
      _error = null;
      _status = '音声を読み込んでいます';
    });
    SpeakerEncoder? encoder;
    MeanVc2Stream? stream;
    try {
      final dir = await _modelDirectory;
      final reference = _readWav16k(await File(_referencePath!).readAsBytes());
      final source = _readWav16k(await File(_sourcePath!).readAsBytes());
      if (reference.length < 16000) {
        throw const FormatException('お手本音声は1秒以上のWAVを選択してください');
      }
      if (source.isEmpty) throw const FormatException('変換する音声が空です');
      if (mounted) setState(() => _status = '声の特徴を解析しています');
      encoder = await SpeakerEncoder.load(
        '$dir/${MeanVc2Models.speakerFileName(_variant)}',
        threads: _threads,
      );
      final embedding = await encoder.embed(reference);
      await encoder.close();
      encoder = null;

      if (mounted) setState(() => _status = '変換エンジンを起動しています');
      stream = await MeanVc2Stream.load(
        dir,
        variant: _variant,
        threads: _threads,
        steps: 3,
      );
      await stream.setTarget(embedding);

      final converted = <double>[];
      final chunks = (source.length + kChunk - 1) ~/ kChunk;
      for (var i = 0; i < chunks; i++) {
        final start = i * kChunk;
        final end = math.min(start + kChunk, source.length);
        final chunk = Float32List(kChunk);
        chunk.setRange(0, end - start, source, start);
        final output = await stream.process(chunk);
        converted.addAll(output);
        if (mounted) {
          setState(() {
            _conversionProgress = (i + 1) / chunks;
            _status = '音声を変換しています  ${i + 1} / $chunks';
          });
        }
      }
      await stream.close();
      stream = null;

      final docs = await getApplicationDocumentsDirectory();
      final outputFile = File(
        '${docs.path}/MeanVC2_${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      await outputFile.writeAsBytes(_writeWav16k(converted), flush: true);
      await _player.setFilePath(outputFile.path);
      if (!mounted) return;
      setState(() {
        _outputPath = outputFile.path;
        _converting = false;
        _conversionProgress = 1;
        _status = '変換が完了しました';
      });
    } catch (e) {
      await encoder?.close();
      await stream?.close();
      if (!mounted) return;
      setState(() {
        _converting = false;
        _error = e.toString();
        _status = '変換に失敗しました';
      });
    }
  }

  Widget _sectionTitle(String title, String subtitle, IconData icon) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFF8B7CFF).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFFB8AEFF), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fileTile({
    required String title,
    required String? path,
    required String emptyLabel,
    required VoidCallback onTap,
    required IconData icon,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1220),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFB8AEFF), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 12, color: Colors.white60)),
                  const SizedBox(height: 4),
                  Text(
                    path == null ? emptyLabel : path.split(Platform.pathSeparator).last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const Icon(Icons.add_circle_outline, color: Colors.white54),
          ],
        ),
      ),
    );
  }

  Widget _downloadCard() {
    final percent = (_downloadProgress * 100).clamp(0, 100).toStringAsFixed(0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('モデル', 'MeanVC2 int8 · オンデバイス推論', Icons.memory_rounded),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _modelsReady ? Icons.check_circle_rounded : Icons.downloading_rounded,
                  size: 17,
                  color: _modelsReady ? Colors.greenAccent : const Color(0xFFB8AEFF),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(_status, style: const TextStyle(fontSize: 13))),
                if (_downloading) Text('$percent%', style: const TextStyle(fontSize: 12)),
              ],
            ),
            if (_downloading) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _totalBytes == 0 ? null : _downloadProgress,
                minHeight: 7,
                borderRadius: BorderRadius.circular(8),
                backgroundColor: Colors.white10,
                color: const Color(0xFF8B7CFF),
              ),
              const SizedBox(height: 8),
              Text(
                '${_formatBytes(_downloadedBytes)} / ${_formatBytes(_totalBytes)}  ·  $_currentFile',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
            if (_error != null && !_converting) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _downloading ? null : _prepareModels,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('再試行'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _studioCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('ボイス変換', 'お手本の声に合わせて音声を変換', Icons.graphic_eq_rounded),
            const SizedBox(height: 18),
            _fileTile(
              title: 'TARGET VOICE · 変換先の声',
              path: _referencePath,
              emptyLabel: 'お手本のWAVを選択',
              onTap: _pickReference,
              icon: Icons.record_voice_over_rounded,
            ),
            const SizedBox(height: 10),
            _fileTile(
              title: 'SOURCE AUDIO · 変換元',
              path: _sourcePath,
              emptyLabel: '変換したいWAVを選択',
              onTap: _pickSource,
              icon: Icons.audio_file_rounded,
            ),
            const SizedBox(height: 16),
            if (_converting) ...[
              LinearProgressIndicator(
                value: _conversionProgress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFF8B7CFF),
                backgroundColor: Colors.white10,
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_modelsReady && !_converting && _referencePath != null && _sourcePath != null)
                    ? _convert
                    : null,
                icon: _converting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_converting ? '変換中...' : 'ボイス変換を開始'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF7565ED),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard() {
    if (_outputPath == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('変換結果', '端末内にWAVで保存しました', Icons.check_circle_outline_rounded),
            const SizedBox(height: 12),
            Text(
              _outputPath!.split(Platform.pathSeparator).last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (context, snapshot) {
                final playing = snapshot.data?.playing ?? false;
                return SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      if (playing) {
                        await _player.pause();
                      } else {
                        if (_player.processingState == ProcessingState.completed) {
                          await _player.seek(Duration.zero);
                        }
                        await _player.play();
                      }
                    },
                    icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    label: Text(playing ? '一時停止' : '変換した音声を再生'),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _exportResult,
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('WAVを書き出す'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MeanVC2', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text('ON-DEVICE VOICE CONVERSION', style: TextStyle(fontSize: 9, letterSpacing: 1.5, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'モデルを再確認',
            onPressed: _downloading || _converting ? null : _prepareModels,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF29234D), Color(0xFF171B30)],
                ),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('YOUR VOICE, REIMAGINED', style: TextStyle(fontSize: 10, letterSpacing: 1.8, color: Color(0xFFC4BCFF), fontWeight: FontWeight.w700)),
                  SizedBox(height: 8),
                  Text('声の個性を、そのままに。', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                  SizedBox(height: 5),
                  Text('音声ファイルを選ぶだけ。変換処理はすべて端末内で実行します。', style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.5)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _downloadCard(),
            const SizedBox(height: 2),
            _liveCard(),
            const SizedBox(height: 2),
            _studioCard(),
            const SizedBox(height: 2),
            _resultCard(),
            const SizedBox(height: 12),
            const Text(
              '対応形式: WAV / PCM 16-bit または Float32 · 16 kHz mono 推奨\n'
              'お手本音声は1秒以上の音声を使用してください。音声の利用には本人の許可を得てください。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: Colors.white38, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Float32List _readWav16k(Uint8List bytes) {
  if (bytes.length < 44 || String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('WAVファイルではありません');
  }
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  var format = 0;
  var channels = 0;
  var sampleRate = 0;
  var bits = 0;
  var dataOffset = -1;
  var dataLength = 0;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (start + size > bytes.length) throw const FormatException('WAVのチャンクが壊れています');
    if (id == 'fmt ') {
      format = data.getUint16(start, Endian.little);
      channels = data.getUint16(start + 2, Endian.little);
      sampleRate = data.getUint32(start + 4, Endian.little);
      bits = data.getUint16(start + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = start;
      dataLength = size;
      break;
    }
    offset = start + size + (size.isOdd ? 1 : 0);
  }
  if (dataOffset < 0 || channels < 1 || channels > 2 || sampleRate <= 0 ||
      !((format == 1 && bits == 16) || (format == 3 && bits == 32))) {
    throw const FormatException('PCM 16-bit / Float32 の mono・stereo WAVに対応しています');
  }
  final bytesPerSample = bits ~/ 8;
  final frames = dataLength ~/ (bytesPerSample * channels);
  if (frames == 0) throw const FormatException('音声データがありません');
  final mono = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var value = 0.0;
    for (var ch = 0; ch < channels; ch++) {
      final p = dataOffset + (i * channels + ch) * bytesPerSample;
      value += format == 1
          ? data.getInt16(p, Endian.little) / 32768.0
          : data.getFloat32(p, Endian.little);
    }
    mono[i] = (value / channels).clamp(-1.0, 1.0);
  }
  if (sampleRate == 16000) return mono;
  final outLength = (frames * 16000 / sampleRate).floor();
  final out = Float32List(outLength);
  for (var i = 0; i < outLength; i++) {
    final position = i * sampleRate / 16000;
    final left = position.floor().clamp(0, frames - 1);
    final right = math.min(left + 1, frames - 1);
    final fraction = position - left;
    out[i] = mono[left] * (1 - fraction) + mono[right] * fraction;
  }
  return out;
}

Uint8List _writeWav16k(List<double> samples) {
  final dataLength = samples.length * 2;
  final out = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(out);
  void ascii(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      out[at + i] = value.codeUnitAt(i);
    }
  }
  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final value = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(44 + i * 2, value, Endian.little);
  }
  return out;
}
