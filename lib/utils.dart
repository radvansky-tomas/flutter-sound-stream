// ignore_for_file: constant_identifier_names

enum SoundStreamStatus {
  Unset,
  Initialized,
  Playing,
  Paused,
  Stopped,
}

String enumToString(Object o) => o.toString().split('.').last;
