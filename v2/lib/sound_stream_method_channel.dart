import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sound_stream/utils.dart';

import 'sound_stream_platform_interface.dart';

/// An implementation of [SoundStreamPlatform] that uses method channels.
class MethodChannelSoundStream extends SoundStreamPlatform {
  MethodChannelSoundStream() {
    _initSoundStream();
  }

  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('sound_stream');

  Future<void> _initSoundStream() async {
    methodChannel.setMethodCallHandler(_onMethodCall);
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case "platformEvent":
        await _processEvent(call.arguments);
        break;
    }
    return null;
  }

  Future<dynamic> _processEvent(dynamic event) async {
    if (event == null) return;
    final String eventName = event["name"] ?? "";
    switch (eventName) {
      case "playerStatus":
        final String status = event["data"] ?? "Unset";
        _playerStatusController.add(SoundStreamStatus.values.firstWhere(
          (value) => enumToString(value) == status,
          orElse: () => SoundStreamStatus.Unset,
        ));
        break;
      case "dataPeriod":
        final Uint8List audioData = Uint8List.fromList(event["data"]);
        if (audioData.isNotEmpty) _recorderAudioStreamController.add(audioData);
        break;
      case "recorderStatus":
        final String status = event["data"] ?? "Unset";
        _recorderStatusController.add(SoundStreamStatus.values.firstWhere(
          (value) => enumToString(value) == status,
          orElse: () => SoundStreamStatus.Unset,
        ));
        break;
    }
  }

  /// Player
  ///
  ///
  // _playerStatusController.add(SoundStreamStatus.Unset);
  // _audioStreamController.stream.listen((data) {
  // writeChunk(data);
  // });

  final _playerAudioStreamController = StreamController<Uint8List>();
  final _playerStatusController =
      StreamController<SoundStreamStatus>.broadcast();

  /// Initialize Player with specified [sampleRate]
  @override
  Future<dynamic> initializePlayer(
          {int sampleRate = 16000, bool showLogs = false}) =>
      methodChannel.invokeMethod("initializePlayer", {
        "sampleRate": sampleRate,
        "showLogs": showLogs,
      });

  /// Player will start receiving audio chunks (PCM 16bit data)
  /// to audiostream as Uint8List to play audio.
  @override
  Future<dynamic> startPlayer() => methodChannel.invokeMethod("startPlayer");

  /// Player will stop receiving audio chunks.
  @override
  Future<dynamic> stopPlayer() => methodChannel.invokeMethod("stopPlayer");

  /// Push audio [data] (PCM 16bit data) to player buffer as Uint8List
  /// to play audio. Chunks will be queued/scheduled to play sequentially
  @override
  Future<dynamic> writeChunk(Uint8List data) =>
      methodChannel.invokeMethod("writeChunk", <String, dynamic>{"data": data});

  @override
  Future<dynamic> seek(double seekTime) =>
    methodChannel.invokeMethod("seek", <String, dynamic>{"seekTime": seekTime});


  @override
  Stream<SoundStreamStatus> get playerStatus => _playerStatusController.stream;

  /// Stream's sink to receive PCM 16bit data to send to Player
  @override
  StreamSink<Uint8List> get playerAudioStream =>
      _playerAudioStreamController.sink;

  @override
  Future<dynamic> usePhoneSpeaker(bool value) => methodChannel
      .invokeMethod("usePhoneSpeaker", <String, dynamic>{"value": value});

  @override
  Future<dynamic> checkCurrentTime() => methodChannel.invokeMethod("checkCurrentTime");
  /// Recorder
  ///
  ///
  // _recorderStatusController.add(SoundStreamStatus.Unset);
  // _audioStreamController.add(Uint8List(0));
  final _recorderAudioStreamController =
      StreamController<Uint8List>.broadcast();

  final _recorderStatusController =
      StreamController<SoundStreamStatus>.broadcast();

  /// Initialize Recorder with specified [sampleRate]
  @override
  Future<dynamic> initializeRecorder(
          {int sampleRate = 16000, bool showLogs = false}) =>
      methodChannel.invokeMethod<dynamic>("initializeRecorder", {
        "sampleRate": sampleRate,
        "showLogs": showLogs,
      });

  /// Start recording. Recorder will start pushing audio chunks (PCM 16bit data)
  /// to audiostream as Uint8List
  @override
  Future<dynamic> startRecorder() =>
      methodChannel.invokeMethod<dynamic>("startRecording");

  /// Recorder will stop recording and sending audio chunks to the [audioStream].
  @override
  Future<dynamic> stopRecorder() =>
      methodChannel.invokeMethod<dynamic>("stopRecording");

  /// Current status of the [RecorderStream]
  @override
  Stream<SoundStreamStatus> get recorderStatus =>
      _recorderStatusController.stream;

  /// Stream of PCM 16bit data from Microphone
  @override
  Stream<Uint8List> get recorderAudioStream =>
      _recorderAudioStreamController.stream;
}
