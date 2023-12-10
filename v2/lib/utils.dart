enum SoundStreamStatus {
  Unset,
  Initialized,
  Playing,
  Stopped,
}

String enumToString(Object o) => o.toString().split('.').last;