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


public class SoundStreamPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var debugLogging: Bool = false
    
    private let mAudioEngine = AVAudioEngine()
    private var isUsingSpeaker: Bool = false
    
    //========= Player's vars
    private let PLAYER_OUTPUT_SAMPLE_RATE: Double = 44100
    private let mPlayerBus = 0
    private let mPlayerNode = AVAudioPlayerNode()
    private var mPlayerSampleRate: Double = 16000
    private var mPlayerOutputFormat: AVAudioFormat!
    private var mPlayerInputFormat: AVAudioFormat!
    private let speedControl = AVAudioUnitVarispeed()
    private var mPlayerBuffer:AVAudioPCMBuffer?
    private var mp3Header:[UInt8]?
    private var playerStatus: SoundStreamStatus = SoundStreamStatus.Unset
    // Add a property to store the start frame of the current segment
    private var startFrameOfCurrentSegment: AVAudioFramePosition = 0
    private var lastCurrentTime:Double = 0.0
    private var lastDuration:Double = 0.0
    private var nowPlayingInfo = [String : Any]()
    
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
        var options: AVAudioSession.CategoryOptions = [AVAudioSession.CategoryOptions.allowBluetooth, AVAudioSession.CategoryOptions.mixWithOthers,AVAudioSession.CategoryOptions.allowBluetoothA2DP]
      
        try? avAudioSession.setCategory(AVAudioSession.Category.playback, options: options)
        try? avAudioSession.setMode(AVAudioSession.Mode.default)
        
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
        mAudioEngine.attach(speedControl)
        
        mAudioEngine.connect(mPlayerNode, to: speedControl, format: mPlayerOutputFormat)
        mAudioEngine.connect(speedControl, to: mAudioEngine.mainMixerNode, format: mPlayerOutputFormat)
        
        UIApplication.shared.beginReceivingRemoteControlEvents()
        setupRemoteTransportControls()
        
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
            
            return .success
            
            // return .commandFailed
        }
        commandCenter.skipForwardCommand.addTarget{ [unowned self] event in
            
            return .success
            
            //return .commandFailed
        }
    }
    
    private func startPlayerInternal() {
        startEngine()
        if !mPlayerNode.isPlaying {
            if (playerStatus == SoundStreamStatus.Paused)
            {
                ///Skip
            }
            else if (playerStatus == SoundStreamStatus.Stopped && mPlayerBuffer != nil && Double(mPlayerBuffer!.frameLength) > PLAYER_OUTPUT_SAMPLE_RATE * 4){
                /// Start over
                let bufferSegment = segment(of: mPlayerBuffer!, from: Int64(0), to: nil)
                let chunkBufferLength = Int(mPlayerBuffer!.frameLength)
                startFrameOfCurrentSegment = AVAudioFramePosition(0)
                mPlayerNode.scheduleBuffer(bufferSegment!,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
                    if (chunkBufferLength < Int(self.mPlayerBuffer!.frameLength))
                    {
                        // we had another chunk
                    }
                    else{
                        self.sendPlayerStatus(SoundStreamStatus.Stopped)
                    }
                    
                };
            }
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
    
    
    func updateNowPlayingInfo(title: String, artist: String, duration: TimeInterval, elapsedTime: TimeInterval) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        
        nowPlayingInfoCenter.nowPlayingInfo =  nowPlayingInfo
        if #available(iOS 13.0, *) {
            switch (playerStatus)
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
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.stopped
                break
            case SoundStreamStatus.Unset:
                nowPlayingInfoCenter.playbackState = MPNowPlayingPlaybackState.unknown
                break
            }
        } else {
            // Fallback on earlier versions
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
        playerStatus = status /// keep last status
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
        mPlayerSampleRate = argsArr["sampleRate"] as? Double ?? mPlayerSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mPlayerInputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mPlayerSampleRate, channels: 1, interleaved: true)
        
        sendPlayerStatus(SoundStreamStatus.Initialized)
        sendResult(result, true)
    }
    
    private func getCurrentTime(_ result: @escaping FlutterResult)  {
        if (playerStatus == SoundStreamStatus.Paused)
        {
            // Fake previous time, as whilst paused, time is 0
            sendResult(result, lastCurrentTime)
            updateNowPlayingInfo(title: "Sample Title", artist: "Sample Artist", duration: lastDuration, elapsedTime:lastCurrentTime)
            return
        }
        
        if let nodeTime = mPlayerNode.lastRenderTime, let playerTime = mPlayerNode.playerTime(forNodeTime: nodeTime) {
            let currentTime = (Double(startFrameOfCurrentSegment) + Double(playerTime.sampleTime)) / PLAYER_OUTPUT_SAMPLE_RATE
            lastCurrentTime = currentTime
            sendResult(result, currentTime)
        } else {
            sendResult(result, Double(0.0))
        }
    }
    
    private func getDuration(_ result: @escaping FlutterResult)  {
        if (mPlayerBuffer != nil)
        {
            let duration = Double(Double(mPlayerBuffer!.frameLength) / Double(mPlayerSampleRate))
            lastDuration = duration
            sendResult(result, duration);
        }
        else
        {
            lastDuration = 0
            sendResult(result, Double(0.0));
        }
        updateNowPlayingInfo(title: "Sample Title", artist: "Sample Artist", duration: lastDuration, elapsedTime:lastCurrentTime)
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
            mPlayerNode.stop()
            
            let bufferSegment = segment(of: mPlayerBuffer!, from: Int64(seekTime * PLAYER_OUTPUT_SAMPLE_RATE), to: nil)
            let chunkBufferLength = Int(mPlayerBuffer!.frameLength)
            startFrameOfCurrentSegment = AVAudioFramePosition(Int64(seekTime * PLAYER_OUTPUT_SAMPLE_RATE))
            mPlayerNode.scheduleBuffer(bufferSegment!,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
                if (chunkBufferLength < Int(self.mPlayerBuffer!.frameLength))
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
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to seek Player buffer",
                                             details: nil ))
        }
    }
    
    func segment(of buffer: AVAudioPCMBuffer, from startFrame: AVAudioFramePosition, to endFrame: AVAudioFramePosition?) -> AVAudioPCMBuffer? {
        let tmpEndFrame = endFrame ?? AVAudioFramePosition(buffer.frameLength)
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
        guard let buffer = try? bytesToAudioBuffer(chunk) else {
            result(true);
            return
        }
        
        let convertedBuffer = convertBufferFormat(
            buffer,
            from: mPlayerInputFormat,
            to: mPlayerOutputFormat
        )
        mPlayerBuffer = mPlayerBuffer != nil ? joinBuffers(buffer1: mPlayerBuffer!, buffer2: convertedBuffer) : convertedBuffer
        
        let chunkBufferLength = Int(mPlayerBuffer!.frameLength)
        mPlayerNode.scheduleBuffer(convertedBuffer,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
            if (chunkBufferLength < Int(self.mPlayerBuffer!.frameLength))
            {
                // we had another chunk
            }
            else{
                self.sendPlayerStatus(SoundStreamStatus.Stopped)
            }
            
        };
        
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
    
    /// MP3 STUFF NOT USED ATM
    var tmpData = Data()
    
    func mp3ChunkToPcm(mp3Data: Data) -> Data? {
        var sourceFormat = AudioStreamBasicDescription(
            mSampleRate: 44100.0,
            mFormatID: kAudioFormatMPEGLayer3,
            mFormatFlags: AudioFormatFlags(0),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1152,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)
        
        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: 44100.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        
        var audioConverter: AudioConverterRef?
        AudioConverterNew(&sourceFormat, &destinationFormat, &audioConverter)
        
        var pcmBuffer = Data(count: mp3Data.count * 6) // Estimated buffer size
        var pcmBufferUsed = 0
        
        let inputDataProc: AudioConverterComplexInputDataProc = {
            inAudioConverter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
            
            let mp3DataPointer = Unmanaged<NSData>.fromOpaque(inUserData!).takeUnretainedValue()
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: mp3DataPointer.bytes)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(mp3DataPointer.length)
            ioData.pointee.mBuffers.mNumberChannels = 1
            
            return noErr
        }
        
        pcmBuffer.withUnsafeMutableBytes { buffer in
            var ioOutputDataPackets: UInt32 = 1
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(mp3Data.count * 6),
                    mData: buffer.baseAddress
                )
            )
            
            let status = AudioConverterFillComplexBuffer(
                audioConverter!,
                inputDataProc,
                Unmanaged.passRetained(mp3Data as NSData).toOpaque(),
                &ioOutputDataPackets,
                UnsafeMutablePointer<AudioBufferList>(&bufferList),
                nil
            )
            
            if status == noErr {
                pcmBufferUsed = Int(bufferList.mBuffers.mDataByteSize)
            }
        }
        
        AudioConverterDispose(audioConverter!)
        
        return pcmBuffer.subdata(in: 0..<pcmBufferUsed)
    }
    
    private func bytesToMP3AudioBuffer(_ buf: [UInt8]) throws -> AVAudioPCMBuffer? {
        // Create a temporary file to hold the MP3 data
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        
        var data = Data(buf)
        
        if mp3Header != nil {
            data = Data(mp3Header!) + data
        } else if buf.count >= 4 {
            mp3Header = Array(buf[0..<4])
        }
        print(tmpData.count)
        let cache = Int(mPlayerSampleRate) * 2
        if (tmpData.count > cache)
        {
            try tmpData.write(to: tempURL)
            
            // Open the MP3 file
            guard let audioFile = try? AVAudioFile(forReading: tempURL) else {
                throw NSError(domain: "Error opening MP3 file", code: 1, userInfo: nil)
            }
            
            // Create a buffer in PCM format
            guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: mPlayerOutputFormat!, frameCapacity: UInt32(tmpData.count)) else {
                throw NSError(domain: "Error creating PCM buffer", code: 2, userInfo: nil)
            }
            
            // Copy the PCM data to the buffer
            tmpData.withUnsafeBytes { rawBufferPointer in
                let mutableRawBufferPointer = rawBufferPointer.bindMemory(to: Float.self)
                audioBuffer.floatChannelData?.pointee.update(from: mutableRawBufferPointer.baseAddress!, count: Int(audioBuffer.frameCapacity))
            }
            
            return audioBuffer
        }
        else{
            tmpData = tmpData + data;
            
            return nil
        }
    }
}

