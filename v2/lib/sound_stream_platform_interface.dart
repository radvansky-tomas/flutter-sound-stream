import 'dart:async';
import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sound_stream/utils.dart';

import 'sound_stream_method_channel.dart';

abstract class SoundStreamPlatform extends PlatformInterface {
  /// Constructs a SoundStreamPlatform.
  SoundStreamPlatform() : super(token: _token);

  static final Object _token = Object();

  static SoundStreamPlatform _instance = MethodChannelSoundStream();

  /// The default instance of [SoundStreamPlatform] to use.
  ///
  /// Defaults to [MethodChannelSoundStream].
  static SoundStreamPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [SoundStreamPlatform] when
  /// they register themselves.
  static set instance(SoundStreamPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Player
  Future<dynamic> initializePlayer(
      {int sampleRate = 16000, bool showLogs = false}) {
    throw UnimplementedError();
  }

  Future<dynamic> startPlayer() {
    throw UnimplementedError();
  }

  Future<dynamic> stopPlayer() {
    throw UnimplementedError();
  }

  Future<dynamic> writeChunk(Uint8List data) {
    throw UnimplementedError();
  }

  Stream<SoundStreamStatus> get playerStatus =>
      Stream.value(SoundStreamStatus.Unset);

  StreamSink<Uint8List> get playerAudioStream => StreamController<Uint8List>();

  Future<dynamic> usePhoneSpeaker(bool value) {
    throw UnimplementedError();
  }

  /// Recorder
  Future<dynamic> initializeRecorder(
      {int sampleRate = 16000, bool showLogs = false}) {
    throw UnimplementedError();
  }

  Future<dynamic> startRecorder() {
    throw UnimplementedError();
  }

  Future<dynamic> stopRecorder() {
    throw UnimplementedError();
  }

  Stream<SoundStreamStatus> get recorderStatus =>
      Stream.value(SoundStreamStatus.Unset);

  Stream<Uint8List> get recorderAudioStream => Stream.empty();
}
