import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
