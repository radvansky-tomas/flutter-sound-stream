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
    String? title,
    String? artist,
  }) {
    return SoundStreamPlatform.instance.initializePlayer(
      sampleRate: sampleRate,
      showLogs: showLogs,
      title: title,
      artist: artist,
    );
  }

  Future<dynamic> startPlayer() {
    return SoundStreamPlatform.instance.startPlayer();
  }

  Future<dynamic> stopPlayer() {
    return SoundStreamPlatform.instance.stopPlayer();
  }

  Future<dynamic> pausePlayer() {
    return SoundStreamPlatform.instance.pausePlayer();
  }

  Future<dynamic> writeChunk(Uint8List data) {
    return SoundStreamPlatform.instance.writeChunk(data);
  }

  Future<double> checkCurrentTime() async {
    final time = await SoundStreamPlatform.instance.checkCurrentTime() ?? 0.0;
    return time < 0.0 ? 0.0 : time;
  }

  Future<double> getDuration() async {
    final time = await SoundStreamPlatform.instance.getDuration() ?? 0.0;
    return time < 0.0 ? 0.0 : time;
  }

  Future<Uint8List> getPlayerBuffer() async {
    final Uint8List buffer =
        await SoundStreamPlatform.instance.getPlayerBuffer();
    return buffer;
  }

  Stream<SoundStreamStatus> get playerStatus =>
      SoundStreamPlatform.instance.playerStatus;

  Future<dynamic> usePhoneSpeaker(bool value) {
    return SoundStreamPlatform.instance.usePhoneSpeaker(value);
  }

  Future<dynamic> changePlayerSpeed(double speed) {
    return SoundStreamPlatform.instance.changePlayerSpeed(speed);
  }

  Future<dynamic> seek(double seekTime) {
    return SoundStreamPlatform.instance.seek(seekTime);
  }
}
