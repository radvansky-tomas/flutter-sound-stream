// ignore_for_file: constant_identifier_names

enum SoundStreamStatus {
  Unset,
  Initialized,
  Playing,
  Paused,
  Stopped,
}

enum SoundStreamFormat { MP3, PCM }

String enumToString(Object o) => o.toString().split('.').last;
