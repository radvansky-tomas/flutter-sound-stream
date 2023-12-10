// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:typed_data';

import 'package:sound_stream/utils.dart';

import 'sound_stream_platform_interface.dart';

class SoundStream {
  /// Player
  Future<dynamic> initializePlayer({
    int sampleRate = 16000,
    bool showLogs = false,
  }) {
    return SoundStreamPlatform.instance
        .initializePlayer(sampleRate: sampleRate, showLogs: showLogs);
  }

  Future<dynamic> startPlayer() {
    return SoundStreamPlatform.instance.startPlayer();
  }

  Future<dynamic> stopPlayer() {
    return SoundStreamPlatform.instance.stopPlayer();
  }

  Future<dynamic> writeChunk(Uint8List data) {
    return SoundStreamPlatform.instance.writeChunk(data);
  }

  Future<double> checkCurrentTime()async{
    final double time = await SoundStreamPlatform.instance.checkCurrentTime();
    return time;
  }
  Stream<SoundStreamStatus> get playerStatus =>
      SoundStreamPlatform.instance.playerStatus;

  StreamSink<Uint8List> get playerAudioStream =>
      SoundStreamPlatform.instance.playerAudioStream;

  Future<dynamic> usePhoneSpeaker(bool value) {
    return SoundStreamPlatform.instance.usePhoneSpeaker(value);
  }

  /// Recorder
  Future<dynamic> initializeRecorder({
    int sampleRate = 16000,
    bool showLogs = false,
  }) {
    return SoundStreamPlatform.instance
        .initializeRecorder(sampleRate: sampleRate, showLogs: showLogs);
  }

  Future<dynamic> startRecorder() {
    return SoundStreamPlatform.instance.startRecorder();
  }

  Future<dynamic> stopRecorder() {
    return SoundStreamPlatform.instance.stopRecorder();
  }

  Stream<SoundStreamStatus> get recorderStatus =>
      SoundStreamPlatform.instance.recorderStatus;

  Stream<Uint8List> get recorderAudioStream =>
      SoundStreamPlatform.instance.recorderAudioStream;
}
