import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sound_stream_platform_interface.dart';

/// An implementation of [SoundStreamPlatform] that uses method channels.
class MethodChannelSoundStream extends SoundStreamPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('sound_stream');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
