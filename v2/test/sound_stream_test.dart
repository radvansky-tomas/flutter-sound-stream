import 'package:flutter_test/flutter_test.dart';
import 'package:sound_stream/sound_stream.dart';
import 'package:sound_stream/sound_stream_platform_interface.dart';
import 'package:sound_stream/sound_stream_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockSoundStreamPlatform
    with MockPlatformInterfaceMixin
    implements SoundStreamPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final SoundStreamPlatform initialPlatform = SoundStreamPlatform.instance;

  test('$MethodChannelSoundStream is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelSoundStream>());
  });

  test('getPlatformVersion', () async {
    SoundStream soundStreamPlugin = SoundStream();
    MockSoundStreamPlatform fakePlatform = MockSoundStreamPlatform();
    SoundStreamPlatform.instance = fakePlatform;

    expect(await soundStreamPlugin.getPlatformVersion(), '42');
  });
}
