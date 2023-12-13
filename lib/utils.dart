enum SoundStreamStatus {
  Unset,
  Initialized,
  Playing,
  Paused,
  Stopped,
}

String enumToString(Object o) => o.toString().split('.').last;
