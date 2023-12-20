import Flutter
import UIKit
import AVFoundation
import MediaPlayer

public enum SoundStreamErrors: String {
    case FailedToPlay
    case FailedToStop
    case FailedToWriteBuffer
    case Unknown
}

public enum SoundStreamStatus: String {
    case Unset
    case Initialized
    case Playing
    case Stopped
    case Paused
}

public enum SoundStreamFormat: String {
    case MP3
    case PCM
}

// This function reads data from a buffer and returns the number of bytes read.
func data_AudioFile_ReadProc(_ inClientData: UnsafeMutableRawPointer, _ inPosition: Int64, _ requestCount: UInt32, _ buffer: UnsafeMutableRawPointer, _ actualCount: UnsafeMutablePointer<UInt32>) -> OSStatus {
  let data = inClientData.assumingMemoryBound(to: Data.self).pointee
  let bufferPointer = UnsafeMutableRawBufferPointer(start: buffer, count: Int(requestCount))
  
  // Calculate the valid range to copy
  let start = Int(inPosition)
  let end = min(start + Int(requestCount), data.count)
  
  // Ensure the range is valid
  if start < data.count {
    let range = start..<end
    let copied = data.copyBytes(to: bufferPointer, from: range)
    actualCount.pointee = UInt32(copied)
  } else {
    // Handle the case where start is beyond the end of the data
    actualCount.pointee = 0
  }
  
  return noErr
}

// This function returns the size of the data.
func data_AudioFile_GetSizeProc(_ inClientData: UnsafeMutableRawPointer) -> Int64 {
    let data = inClientData.assumingMemoryBound(to: Data.self).pointee
    return Int64(data.count)
}

// This extension to the Data class provides a method to convert the data to a specified audio format.
extension Data {
    func convertedTo(_ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        var data = self
        
        // Open an audio file with callbacks for reading data and getting the file size.
        var af: AudioFileID? = nil
        var status = AudioFileOpenWithCallbacks(&data, data_AudioFile_ReadProc, nil, data_AudioFile_GetSizeProc(_:), nil, 0, &af)
        guard status == noErr, af != nil else {
            return nil
        }
        
        defer {
            AudioFileClose(af!)
        }
        
        // Wrap the audio file in an extended audio file.
        var eaf: ExtAudioFileRef? = nil
        status = ExtAudioFileWrapAudioFileID(af!, false, &eaf)
        guard status == noErr, eaf != nil else {
            return nil
        }
        
        defer {
            ExtAudioFileDispose(eaf!)
        }
        
        // Set the client data format for the extended audio file.
        var clientFormat = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(eaf!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: clientFormat)), &clientFormat)
        guard status == noErr else {
            return nil
        }
        
        // Set the client channel layout for the extended audio file, if one is provided.
        if let channelLayout = format.channelLayout {
            var clientChannelLayout = channelLayout.layout.pointee
            status = ExtAudioFileSetProperty(eaf!, kExtAudioFileProperty_ClientChannelLayout, UInt32(MemoryLayout.size(ofValue: clientChannelLayout)), &clientChannelLayout)
            guard status == noErr else {
                return nil
            }
        }
        
        // Get the length of the file in frames.
        var frameLength: Int64 = 0
        var propertySize: UInt32 = UInt32(MemoryLayout.size(ofValue: frameLength))
        status = ExtAudioFileGetProperty(eaf!, kExtAudioFileProperty_FileLengthFrames, &propertySize, &frameLength)
        guard status == noErr else {
            return nil
        }
        
        // Create a PCM buffer with the specified format and frame capacity.
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else {
            return nil
        }
        
        // Set up an audio buffer list for reading data from the extended audio file.
        let bufferSizeFrames = 512
        let bufferSizeBytes = Int(format.streamDescription.pointee.mBytesPerFrame) * bufferSizeFrames
        let numBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let numInterleavedChannels = format.isInterleaved ? Int(format.channelCount) : 1
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: numBuffers)
        for i in 0 ..< numBuffers {
            audioBufferList[i] = AudioBuffer(mNumberChannels: UInt32(numInterleavedChannels), mDataByteSize: UInt32(bufferSizeBytes), mData: malloc(bufferSizeBytes))
        }
        
        defer {
            for buffer in audioBufferList {
                free(buffer.mData)
            }
            free(audioBufferList.unsafeMutablePointer)
        }
        
        // Read data from the extended audio file into the audio buffer list.
        while true {
            var frameCount: UInt32 = UInt32(bufferSizeFrames)
            status = ExtAudioFileRead(eaf!, &frameCount, audioBufferList.unsafeMutablePointer)
            guard status == noErr else {
                return nil
            }
            
            if frameCount == 0 {
                break
            }
            
            // Copy the data from the audio buffer list to the PCM buffer.
            let src = audioBufferList
            let dst = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
            
            if src.count != dst.count {
                return nil
            }
            
            for i in 0 ..< src.count {
                let srcBuf = src[i]
                let dstBuf = dst[i]
                memcpy(dstBuf.mData?.advanced(by: Int(dstBuf.mDataByteSize)), srcBuf.mData, Int(srcBuf.mDataByteSize))
            }
            
            pcmBuffer.frameLength += frameCount
        }
        
        return pcmBuffer
    }
}

public class SoundStreamPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var debugLogging: Bool = false
    
    private let mAudioEngine = AVAudioEngine()
    private var isUsingSpeaker: Bool = false
    //========= Player's vars
    private var mPlayerFormat:SoundStreamFormat = SoundStreamFormat.PCM
    private var mPlayerStatus: SoundStreamStatus = SoundStreamStatus.Unset
    private let PLAYER_OUTPUT_SAMPLE_RATE: Double = 44100
    private let mPlayerBus = 0
    private let mPlayerNode = AVAudioPlayerNode()
    private var mPlayerSampleRate: Double = 16000
    private var mPlayerOutputFormat: AVAudioFormat!
    private var mPlayerInputFormat: AVAudioFormat!
    private let speedControl = AVAudioUnitVarispeed()
    private let pitchControl = AVAudioUnitTimePitch()
    private var mPlayerBuffer:AVAudioPCMBuffer?
    private var mp3Header:[UInt8]?
    
    // Add a property to store the start frame of the current segment
    private var startFrameOfCurrentSegment: AVAudioFramePosition = 0
    private var lastCurrentTime:Double = 0.0
    private var lastDuration:Double = 0.0
    private var nowPlayingInfo = [String : Any]()
    private var title:String = "";
    private var artist:String = "";
    
    
    /** ======== Basic Plugin initialization ======== **/
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "sound_stream", binaryMessenger: registrar.messenger())
        let instance = SoundStreamPlugin(channel, registrar:registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    init( _ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar ) {
        self.channel = channel
        self.registrar = registrar
        
        super.init()
        self.attachPlayer()
        self.initEngine()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "usingSpeaker":
            sendResult(result, isUsingSpeaker)
        case "usePhoneSpeaker":
            usePhoneSpeaker(call, result)
        case "initializePlayer":
            initializePlayer(call, result)
        case "startPlayer":
            startPlayer(result)
        case "stopPlayer":
            stopPlayer(result)
        case "pausePlayer":
            pausePlayer(result)
        case "writeChunk":
            writeChunk(call, result)
        case "changePlayerSpeed":
            changePlayerSpeed(call, result)
        case "seek":
            seek(call, result)
        case "checkCurrentTime":
            getCurrentTime(result)
        case "getDuration":
            getDuration(result)
        case "getPlayerBuffer":
            getPlayerBuffer(result)
        default:
            print("Unrecognized method: \(call.method)")
            sendResult(result, FlutterMethodNotImplemented)
        }
    }
    
    private func sendResult(_ result: @escaping FlutterResult, _ arguments: Any?) {
        DispatchQueue.main.async {
            result( arguments )
        }
    }
    
    private func invokeFlutter( _ method: String, _ arguments: Any? ) {
        DispatchQueue.main.async {
            self.channel.invokeMethod( method, arguments: arguments )
        }
    }
    
    private func initEngine() {
        mAudioEngine.prepare()
        startEngine()
        
        let avAudioSession = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [AVAudioSession.CategoryOptions.allowBluetooth, AVAudioSession.CategoryOptions.mixWithOthers,AVAudioSession.CategoryOptions.allowBluetoothA2DP]
        
        try? avAudioSession.setCategory(AVAudioSession.Category.playback, options: options)
        try? avAudioSession.setMode(AVAudioSession.Mode.default)
        setupInterruptionNotification()
        setUsePhoneSpeaker(false)
    }
    
    private func startEngine() {
        guard !mAudioEngine.isRunning else {
            return
        }
        
        try? mAudioEngine.start()
    }
    
    private func stopEngine() {
        mAudioEngine.stop()
        mAudioEngine.reset()
    }
    
    private func attachPlayer() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        try! session.setCategory(
            .playAndRecord,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .allowAirPlay
            ])
        try! session.setActive(true)
        
        mPlayerOutputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatFloat32, sampleRate: PLAYER_OUTPUT_SAMPLE_RATE, channels: 1, interleaved: true)
        
        mAudioEngine.attach(mPlayerNode)
        mAudioEngine.attach(pitchControl)
        mAudioEngine.attach(speedControl)
        
        mAudioEngine.connect(mPlayerNode, to: pitchControl, format: mPlayerOutputFormat)
        mAudioEngine.connect(pitchControl, to: speedControl, format: mPlayerOutputFormat)
        mAudioEngine.connect(speedControl, to: mAudioEngine.mainMixerNode, format: mPlayerOutputFormat)
        
        UIApplication.shared.beginReceivingRemoteControlEvents()
        setupRemoteTransportControls()
        
    }
    
    func setupInterruptionNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // Interruption began, take appropriate actions (e.g., pause audio player node)
            mPlayerNode.pause()
        case .ended:
            // Interruption ended, take appropriate actions (e.g., resume audio player node)
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    mPlayerNode.play()
                }
            }
        default: ()
        }
    }
    
    func setupRemoteTransportControls() {
        
        // Get the shared MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Add handler for Play Command
        commandCenter.playCommand.addTarget { [unowned self] event in
            startPlayerInternal()
            return .success
            
            // return .commandFailed
        }
        
        // Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { [unowned self] event in
            pausePlayerInternal()
            return .success
            
            // return .commandFailed
        }
        commandCenter.skipBackwardCommand.addTarget{ [unowned self] event in
            seekInternal(seekTime: getCurrentTimeInternal() - 10.0)
            return .success
            
            // return .commandFailed
        }
        commandCenter.skipForwardCommand.addTarget{ [unowned self] event in
            seekInternal(seekTime: getCurrentTimeInternal() + 10.0)
            return .success
            
            //return .commandFailed
        }
    }
    
    private func startPlayerInternal() {
        startEngine()
        if !mPlayerNode.isPlaying {
            if (mPlayerStatus == SoundStreamStatus.Paused)
            {
                ///Skip
            }
            //            else if (playerStatus == SoundStreamStatus.Stopped && mPlayerBuffer != nil && Double(mPlayerBuffer!.frameLength) > PLAYER_OUTPUT_SAMPLE_RATE * 4){
            //                /// Start over
            //                let bufferSegment = segment(of: mPlayerBuffer!, from: Int64(0), to: nil)
            //                let chunkBufferLength = Int(mPlayerBuffer!.frameLength)
            //                startFrameOfCurrentSegment = AVAudioFramePosition(0)
            //                mPlayerNode.scheduleBuffer(bufferSegment!,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
            //                    if (chunkBufferLength < Int(self.mPlayerBuffer?.frameLength ?? 0))
            //                    {
            //                        // we had another chunk
            //                    }
            //                    else{
            //                        self.sendPlayerStatus(SoundStreamStatus.Stopped)
            //                    }
            //
            //                };
            //            }
            mPlayerNode.play()
        }
        sendPlayerStatus(SoundStreamStatus.Playing)
    }
    
    private func pausePlayerInternal() {
        if mPlayerNode.isPlaying {
            mPlayerNode.pause()
        }
        sendPlayerStatus(SoundStreamStatus.Paused)
    }
    
    private func getCurrentTimeInternal()->Double{
        if (mPlayerStatus == SoundStreamStatus.Paused)
        {
            // Fake previous time, as whilst paused, time is 0
            return lastCurrentTime;
        }
        
        if let nodeTime = mPlayerNode.lastRenderTime, let playerTime = mPlayerNode.playerTime(forNodeTime: nodeTime) {
            let currentTime = (Double(startFrameOfCurrentSegment) + Double(playerTime.sampleTime)) / PLAYER_OUTPUT_SAMPLE_RATE
            lastCurrentTime =  currentTime < 0.0 ? 0.0 : currentTime
            
            return lastCurrentTime
        } else {
            return 0.0
        }
    }
    
    private func getDurationInternal()->Double{
        if (mPlayerBuffer != nil)
        {
            let duration = Double(Double(mPlayerBuffer!.frameLength) / Double(mPlayerSampleRate))
            lastDuration = duration
            return duration
        }
        else
        {
            lastDuration = 0
            return 0.0
        }
    }
    
    private func seekInternal(seekTime:Double){
        var tmpSeekTime = seekTime
        let duration = getDurationInternal()
        if (tmpSeekTime < 0.0)
        {
            tmpSeekTime = 0.0
        }
        else if (tmpSeekTime > duration - 10.0)
        {
            tmpSeekTime = duration
        }
        mPlayerNode.stop()
        
        let bufferSegment = segment(of: mPlayerBuffer!, from: Int64(tmpSeekTime * PLAYER_OUTPUT_SAMPLE_RATE), to: nil)
        if (bufferSegment != nil)
        {
            let chunkBufferLength = Int(mPlayerBuffer!.frameLength)
            startFrameOfCurrentSegment = AVAudioFramePosition(Int64(tmpSeekTime * PLAYER_OUTPUT_SAMPLE_RATE))
            mPlayerNode.scheduleBuffer(bufferSegment!,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
                if (chunkBufferLength < Int(self.mPlayerBuffer?.frameLength ?? 0))
                {
                    // we had another chunk
                }
                else{
                    self.sendPlayerStatus(SoundStreamStatus.Stopped)
                }
            };
            
            mPlayerNode.play()
            sendPlayerStatus(SoundStreamStatus.Playing)
        }
        else{
            sendPlayerStatus(SoundStreamStatus.Stopped)
        }
    }
    
    func updateNowPlayingInfo(title: String, artist: String, duration: TimeInterval, elapsedTime: TimeInterval) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        let image = UIImage(named: "AppIcon")!
        let artwork = MPMediaItemArtwork.init(boundsSize: image.size, requestHandler: { (size) -> UIImage in
            return image
        })
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        
        
        if #available(iOS 13.0, *) {
            nowPlayingInfoCenter.nowPlayingInfo =  nowPlayingInfo
            switch (mPlayerStatus)
            {
            case SoundStreamStatus.Playing:
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.playing
                break
            case SoundStreamStatus.Paused:
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.paused
                break
            case SoundStreamStatus.Stopped:
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.stopped
                break
            case SoundStreamStatus.Initialized:
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.unknown
                break
            case SoundStreamStatus.Unset:
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.unknown
                break
            }
        } else {
            // Fallback on earlier versions
            switch (mPlayerStatus)
            {
            case SoundStreamStatus.Playing:
                nowPlayingInfoCenter.nowPlayingInfo =  nowPlayingInfo
                break
            case SoundStreamStatus.Paused:
                nowPlayingInfoCenter.nowPlayingInfo =  nowPlayingInfo
                break
            case SoundStreamStatus.Stopped:
                nowPlayingInfoCenter.nowPlayingInfo =  nil
                break
            case SoundStreamStatus.Initialized:
                nowPlayingInfoCenter.nowPlayingInfo =  nil
                break
            case SoundStreamStatus.Unset:
                nowPlayingInfoCenter.nowPlayingInfo =  nil
                break
            }
        }
        
        
    }
    
    private func sendEventMethod(_ name: String, _ data: Any) {
        var eventData: [String: Any] = [:]
        eventData["name"] = name
        eventData["data"] = data
        invokeFlutter("platformEvent", eventData)
    }
    
    /** ======== Plugin methods ======== **/
    private func sendPlayerStatus(_ status: SoundStreamStatus) {
        mPlayerStatus = status /// keep last status
        sendEventMethod("playerStatus", status.rawValue)
    }
    
    private func initializePlayer(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        /// Clear audio buffer
        if (mPlayerNode.isPlaying)
        {
            mPlayerNode.stop()
        }
        
        mPlayerBuffer = nil
        mp3Header = nil
        if let formatString = argsArr["format"] as? String, let format = SoundStreamFormat(rawValue: formatString) {
            mPlayerFormat = format
            var readFormat = AudioStreamBasicDescription()
            readFormat.mSampleRate = 44100.0
            readFormat.mFormatID = kAudioFormatMPEGLayer3
            readFormat.mFormatFlags = 0
            readFormat.mBytesPerPacket = 0
            readFormat.mFramesPerPacket = 1152 // MP3 has 1152 frames per packet
            readFormat.mBytesPerFrame = 0
            readFormat.mChannelsPerFrame = 1 // Stereo
            readFormat.mBitsPerChannel = 0
            readFormat.mReserved = 0
            mPlayerInputFormat = AVAudioFormat(streamDescription: &readFormat)!
        } else {
            mPlayerFormat = .PCM
            mPlayerInputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mPlayerSampleRate, channels: 1, interleaved: true)
        }
        title = argsArr["title"] as? String ?? ""
        artist = argsArr["artist"] as? String ?? ""
        mPlayerSampleRate = argsArr["sampleRate"] as? Double ?? mPlayerSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        
        sendPlayerStatus(SoundStreamStatus.Initialized)
        sendResult(result, true)
    }
    
    private func getCurrentTime(_ result: @escaping FlutterResult)  {
        sendResult(result, getCurrentTimeInternal())
    }
    
    private func getDuration(_ result: @escaping FlutterResult)  {
        sendResult(result, getDurationInternal());
        updateNowPlayingInfo(title: title, artist: artist, duration: lastDuration, elapsedTime:lastCurrentTime)
    }
    
    private func getPlayerBuffer(_ result: @escaping FlutterResult)  {
        if (mPlayerBuffer != nil)
        {
            let channelCount = 1  // given PCMBuffer channel count is 1
            let channels = UnsafeBufferPointer(start: mPlayerBuffer!.floatChannelData, count: channelCount)
            let ch0Data = NSData(bytes: channels[0], length:Int(mPlayerBuffer!.frameCapacity * mPlayerBuffer!.format.streamDescription.pointee.mBytesPerFrame))
            
            
            let channelData = FlutterStandardTypedData(bytes: ch0Data as Data)
            sendResult(result, channelData)
        }
        else{
            let channelData = FlutterStandardTypedData(bytes: NSData() as Data)
            sendResult(result, channelData)
        }
    }
    
    
    private func usePhoneSpeaker(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        let useSpeaker = argsArr["value"] as? Bool ?? false
        
        setUsePhoneSpeaker(useSpeaker)
        sendResult(result, true)
    }
    
    private func setUsePhoneSpeaker(_ enabled: Bool) {
        if mPlayerNode.isPlaying {
            mPlayerNode.stop()
            sendPlayerStatus(SoundStreamStatus.Stopped)
        }
        
        let avAudioSession = AVAudioSession.sharedInstance()
        
        if enabled {
            try? avAudioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
            
            for input in avAudioSession.availableInputs!{
                if input.portType == AVAudioSession.Port.builtInMic || input.portType == AVAudioSession.Port.builtInReceiver {
                    if debugLogging {
                        print(input.portName)
                    }
                    try? avAudioSession.setPreferredInput(input)
                    break
                }
            }
        } else {
            try? avAudioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.none)
            
            for input in avAudioSession.availableInputs!{
                if input.portType == AVAudioSession.Port.bluetoothA2DP || input.portType == AVAudioSession.Port.bluetoothHFP || input.portType == AVAudioSession.Port.bluetoothLE || input.portType == AVAudioSession.Port.headsetMic {
                    if debugLogging {
                        print(input.portName)
                    }
                    try? avAudioSession.setPreferredInput(input)
                    break
                }
            }
        }
        
        if debugLogging {
            print("INPUTS")
            for input in avAudioSession.availableInputs!{
                print(input.portName)
            }
            
            print("OUTPUTS")
            for output in avAudioSession.currentRoute.outputs{
                print(output.portName)
            }
        }
        
        try? avAudioSession.setActive(true)
        
        isUsingSpeaker = enabled
        startEngine()
    }
    
    private func startPlayer(_ result: @escaping FlutterResult) {
        startPlayerInternal()
        result(true)
    }
    
    private func stopPlayer(_ result: @escaping FlutterResult) {
        if mPlayerNode.isPlaying {
            mPlayerNode.stop()
        }
        sendPlayerStatus(SoundStreamStatus.Stopped)
        result(true)
    }
    
    private func pausePlayer(_ result: @escaping FlutterResult) {
        pausePlayerInternal()
        result(true)
    }
    
    private func changePlayerSpeed(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>,
              let speed = argsArr["speed"] as? Float
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to change Player speed",
                                             details: nil ))
            return
        }
        speedControl.rate = speed
        let pitchShift = 1200 * log2(speedControl.rate)
        pitchControl.pitch = -pitchShift // Correct the pitch
        
    }
    
    private func writeChunk(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>,
              let data = argsArr["data"] as? FlutterStandardTypedData
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to write Player buffer",
                                             details: nil ))
            return
        }
        let byteData = [UInt8](data.data)
        pushPlayerChunk(byteData, result)
    }
    
    private func seek(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>,
              let seekTime = argsArr["seekTime"] as? Double
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to seek Player buffer",
                                             details: nil ))
            return
        }
        if (mPlayerBuffer != nil)
        {
            seekInternal(seekTime:seekTime)
        }
        else{
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to seek Player buffer",
                                             details: nil ))
        }
    }
    
    func segment(of buffer: AVAudioPCMBuffer, from startFrame: AVAudioFramePosition, to endFrame: AVAudioFramePosition?) -> AVAudioPCMBuffer? {
        let tmpEndFrame = endFrame ?? AVAudioFramePosition(buffer.frameLength)
        if (tmpEndFrame - startFrame < 0)
        {
            return nil
        }
        let framesToCopy = AVAudioFrameCount(tmpEndFrame - startFrame)
        guard let segment = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: framesToCopy) else { return nil }
        
        let sampleSize = buffer.format.streamDescription.pointee.mBytesPerFrame
        
        let srcPtr = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dstPtr = UnsafeMutableAudioBufferListPointer(segment.mutableAudioBufferList)
        for (src, dst) in zip(srcPtr, dstPtr) {
            memcpy(dst.mData, src.mData?.advanced(by: Int(startFrame) * Int(sampleSize)), Int(framesToCopy) * Int(sampleSize))
        }
        
        segment.frameLength = framesToCopy
        return segment
        
    }
    
    func joinBuffers(buffer1: AVAudioPCMBuffer, buffer2: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer1.frameLength + buffer2.frameLength
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: buffer1.format, frameCapacity: frames) else { return nil }
        
        if let buffer1Data = buffer1.floatChannelData, let newBufferData = newBuffer.floatChannelData {
            for channel in 0..<buffer1.format.channelCount {
                memcpy(newBufferData[Int(channel)], buffer1Data[Int(channel)], Int(buffer1.frameLength * buffer1.format.streamDescription.pointee.mBytesPerFrame))
            }
        }
        
        if let buffer2Data = buffer2.floatChannelData, let newBufferData = newBuffer.floatChannelData {
            for channel in 0..<buffer2.format.channelCount {
                memcpy(newBufferData[Int(channel)] + Int(buffer1.frameLength), buffer2Data[Int(channel)], Int(buffer2.frameLength * buffer2.format.streamDescription.pointee.mBytesPerFrame))
            }
        }
        
        newBuffer.frameLength = frames
        return newBuffer
    }
    
    private func pushPlayerChunk(_ chunk: [UInt8], _ result: @escaping FlutterResult) {
        var buffer:AVAudioPCMBuffer?
        var convertedBuffer:AVAudioPCMBuffer?
        if (self.mPlayerFormat == SoundStreamFormat.PCM)
        {
            buffer = try? bytesToAudioBuffer(chunk)
            if(buffer != nil)
            {
                convertedBuffer = convertBufferFormat(
                    buffer!,
                    from: self.mPlayerInputFormat,
                    to: self.mPlayerOutputFormat
                )
            }
            
        }
        else{
            buffer = try? bytesToMP3AudioBuffer(chunk)
            if(buffer != nil)
            {
                convertedBuffer = buffer
            }
        }
        
        self.mPlayerBuffer = self.mPlayerBuffer != nil && convertedBuffer != nil ? joinBuffers(buffer1: self.mPlayerBuffer!, buffer2: convertedBuffer!) : convertedBuffer
        if (self.mPlayerBuffer != nil)
        {
            let chunkBufferLength = Int(self.mPlayerBuffer!.frameLength)
            self.mPlayerNode.scheduleBuffer(convertedBuffer!,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
                if (chunkBufferLength < Int(self.mPlayerBuffer?.frameLength ?? 0))
                {
                    // we had another chunk
                }
                else{
                    self.sendPlayerStatus(SoundStreamStatus.Stopped)
                    
                }
                
            };
        }
        
        // Update UI here
        result(true)
        
        
    }
    
    
    
    private func convertBufferFormat(_ buffer: AVAudioPCMBuffer, from: AVAudioFormat, to: AVAudioFormat) -> AVAudioPCMBuffer {
        
        let formatConverter =  AVAudioConverter(from: from, to: to)
        let ratio: Float = Float(from.sampleRate)/Float(to.sampleRate)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio))!
        
        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = {inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        formatConverter?.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)
        
        return pcmBuffer
    }
    
    
    private func bytesToAudioBuffer(_ buf: [UInt8]) throws -> AVAudioPCMBuffer? {
        let frameLength = UInt32(buf.count) / mPlayerInputFormat.streamDescription.pointee.mBytesPerFrame
        
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: mPlayerInputFormat, frameCapacity: frameLength)!
        audioBuffer.frameLength = frameLength
        
        let dstLeft = audioBuffer.int16ChannelData![0]
        
        buf.withUnsafeBufferPointer {
            let src = UnsafeRawPointer($0.baseAddress!).bindMemory(to: Int16.self, capacity: Int(frameLength))
            dstLeft.initialize(from: src, count: Int(frameLength))
        }
        
        return audioBuffer
    }
    
    
    private func bytesToMP3AudioBuffer(_ buf: [UInt8]) throws -> AVAudioPCMBuffer? {
        var data = Data(buf)
        
        if mp3Header != nil {
            data = Data(mp3Header!) + data
        } else if buf.count >= 4 {
            mp3Header = Array(buf[0..<4])
        }
        
        return data.convertedTo(mPlayerOutputFormat!)
    }
}

