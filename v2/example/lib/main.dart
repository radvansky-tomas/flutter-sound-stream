import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sound_stream/sound_stream.dart';
import 'package:sound_stream/utils.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  SoundStream soundStream = SoundStream();

  List<Uint8List> _micChunks = [];
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _useSpeaker = false;

  StreamSubscription? _recorderStatus;
  StreamSubscription? _playerStatus;
  StreamSubscription? _audioStream;

  @override
  void initState() {
    super.initState();
    initPlugin();
  }

  @override
  void dispose() {
    _recorderStatus?.cancel();
    _playerStatus?.cancel();
    _audioStream?.cancel();
    super.dispose();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlugin() async {
    _recorderStatus = soundStream.recorderStatus.listen((status) {
      if (mounted)
        setState(() {
          _isRecording = status == SoundStreamStatus.Playing;
        });
    });

    _audioStream = soundStream.recorderAudioStream.listen((data) {
      if (_isPlaying) {
        soundStream.writeChunk(data);
      } else {
        _micChunks.add(data);
      }
    });

    _playerStatus = soundStream.playerStatus.listen((status) {
      if (mounted)
        setState(() {
          _isPlaying = status == SoundStreamStatus.Playing;
        });
    });

    await Future.wait([
      soundStream.initializeRecorder(),
      soundStream.initializePlayer(),
    ]);
    // _player.usePhoneSpeaker(_useSpeaker);
  }

  void _play() async {
    await soundStream.startPlayer();

    if (_micChunks.isNotEmpty) {
      for (var chunk in _micChunks) {
        await soundStream.writeChunk(chunk);
      }
      _micChunks.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                IconButton(
                  iconSize: 96.0,
                  icon: Icon(_isRecording ? Icons.mic_off : Icons.mic),
                  onPressed: _isRecording
                      ? soundStream.stopRecorder
                      : soundStream.startRecorder,
                ),
                IconButton(
                  iconSize: 96.0,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: _isPlaying ? soundStream.stopPlayer : _play,
                ),
              ],
            ),
            IconButton(
              iconSize: 96.0,
              icon: Icon(_useSpeaker ? Icons.headset_off : Icons.headset),
              onPressed: () {
                setState(() {
                  _useSpeaker = !_useSpeaker;
                  soundStream.usePhoneSpeaker(_useSpeaker);
                });
              },
            ),
          ],
        ),
      ),
    );
  }
}
