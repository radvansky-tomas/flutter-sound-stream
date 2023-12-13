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
          {int sampleRate = 16000, bool showLogs = false,String? title, String? artist,}) =>
      methodChannel.invokeMethod("initializePlayer", {
        "sampleRate": sampleRate,
        "showLogs": showLogs,
        "title": title,
        "artist": artist,
      });

  /// Player will start receiving audio chunks (PCM 16bit data)
  /// to audiostream as Uint8List to play audio.
  @override
  Future<dynamic> startPlayer() => methodChannel.invokeMethod("startPlayer");

  /// Player will stop receiving audio chunks.
  @override
  Future<dynamic> stopPlayer() => methodChannel.invokeMethod("stopPlayer");

  /// Player will pause playback.
  @override
  Future<dynamic> pausePlayer() => methodChannel.invokeMethod("pausePlayer");

  /// Push audio [data] (PCM 16bit data) to player buffer as Uint8List
  /// to play audio. Chunks will be queued/scheduled to play sequentially
  @override
  Future<dynamic> writeChunk(Uint8List data) =>
      methodChannel.invokeMethod("writeChunk", <String, dynamic>{"data": data});

  @override
  Future<dynamic> changePlayerSpeed(double speed) => methodChannel.invokeMethod("changePlayerSpeed", <String, dynamic>{"speed": speed});

  @override
  Future<dynamic> getPlayerBuffer() => methodChannel.invokeMethod("getPlayerBuffer");

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
  Future<double?> checkCurrentTime() => methodChannel.invokeMethod<double>("checkCurrentTime");

  @override
  Future<double?> getDuration() => methodChannel.invokeMethod<double>("getDuration");
}
