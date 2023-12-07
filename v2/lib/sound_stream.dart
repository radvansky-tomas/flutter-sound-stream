// ignore_for_file: constant_identifier_names

import 'sound_stream_platform_interface.dart';

enum SoundStreamStatus {
  Unset,
  Initialized,
  Playing,
  Stopped,
}

class SoundStream {
  Future<String?> getPlatformVersion() {
    return SoundStreamPlatform.instance.getPlatformVersion();
  }
}
