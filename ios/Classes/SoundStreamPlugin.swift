import Flutter
import UIKit
import AVFoundation

public enum SoundStreamErrors: String {
    case FailedToRecord
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
}


public class SoundStreamPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var hasPermission: Bool = false
    private var debugLogging: Bool = false
    
    private let mAudioEngine = AVAudioEngine()
    private var isUsingSpeaker: Bool = false
    
    //========= Player's vars
    private let PLAYER_OUTPUT_SAMPLE_RATE: Double = 44100   // 32Khz
    private let mPlayerBus = 0
    private let mPlayerNode = AVAudioPlayerNode()
    private var mPlayerSampleRate: Double = 44100 // 44Khz
    private var mPlayerOutputFormat: AVAudioFormat!
    private var mPlayerInputFormat: AVAudioFormat!
    private let speedControl = AVAudioUnitVarispeed()
    private var mPlayerBuffer:[UInt8] = []
    private var mp3Header:[UInt8] = []
    
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
        case "hasPermission":
            hasPermission(result)
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
        case "writeChunk":
            writeChunk(call, result)
        case "changePlayerSpeed":
            changePlayerSpeed(call, result)
        case "seek":
            seek(call, result)
        case "checkCurrentTime":
            checkCurrentTime(result)
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
    
    /** ======== Plugin methods ======== **/
    
    private func checkAndRequestPermission(completion callback: @escaping ((Bool) -> Void)) {
        if (hasPermission) {
            callback(hasPermission)
            return
        }
        
        var permission: AVAudioSession.RecordPermission
#if swift(>=4.2)
        permission = AVAudioSession.sharedInstance().recordPermission
#else
        permission = AVAudioSession.sharedInstance().recordPermission()
#endif
        switch permission {
        case .granted:
            print("granted")
            hasPermission = true
            callback(hasPermission)
            break
        case .denied:
            print("denied")
            hasPermission = false
            callback(hasPermission)
            break
        case .undetermined:
            print("undetermined")
            AVAudioSession.sharedInstance().requestRecordPermission() { [unowned self] allowed in
                if allowed {
                    self.hasPermission = true
                    print("undetermined true")
                    callback(self.hasPermission)
                } else {
                    self.hasPermission = false
                    print("undetermined false")
                    callback(self.hasPermission)
                }
            }
            break
        default:
            callback(hasPermission)
            break
        }
    }
    
    private func hasPermission( _ result: @escaping FlutterResult) {
        checkAndRequestPermission { value in
            self.sendResult(result, value)
        }
    }
    
    private func initEngine() {
        mAudioEngine.prepare()
        startEngine()
        
        let avAudioSession = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [AVAudioSession.CategoryOptions.allowBluetooth, AVAudioSession.CategoryOptions.mixWithOthers]
        if #available(iOS 10.0, *) {
            options.insert(AVAudioSession.CategoryOptions.allowBluetoothA2DP)
        }
        try? avAudioSession.setCategory(AVAudioSession.Category.playAndRecord, options: options)
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
    
    private func sendEventMethod(_ name: String, _ data: Any) {
        var eventData: [String: Any] = [:]
        eventData["name"] = name
        eventData["data"] = data
        invokeFlutter("platformEvent", eventData)
    }
    
    
    private func checkCurrentTime(_ result: @escaping FlutterResult)  {
        if let nodeTime: AVAudioTime = mPlayerNode.lastRenderTime, let playerTime: AVAudioTime = mPlayerNode.playerTime(forNodeTime: nodeTime) {
            sendResult(result, Double(Double(playerTime.sampleTime) / playerTime.sampleRate));
            return;
        }
     sendResult(result, 0)
    }
    
    private func getDuration(_ result: @escaping FlutterResult)  {
        if let nodeTime: AVAudioTime = mPlayerNode.lastRenderTime {
            sendResult(result, Double( nodeTime.sampleRate));
            return;
        }
     sendResult(result, 0)
    }
    
    private func getPlayerBuffer(_ result: @escaping FlutterResult)  {
        let channelData = FlutterStandardTypedData(bytes: NSData(bytes: mPlayerBuffer, length: mPlayerBuffer.count) as Data)
        sendResult(result, channelData)
    }
    
    private func initializePlayer(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        
        mPlayerSampleRate = argsArr["sampleRate"] as? Double ?? mPlayerSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mPlayerInputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatFloat32, sampleRate: mPlayerSampleRate, channels: 1, interleaved: true)
        mPlayerBuffer = []
        sendPlayerStatus(SoundStreamStatus.Initialized)
        sendResult(result, true)
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
        
        
    }
    
    private func startPlayer(_ result: @escaping FlutterResult) {
        startEngine()
        if !mPlayerNode.isPlaying {
            mPlayerNode.play()
        }
        sendPlayerStatus(SoundStreamStatus.Playing)
        result(true)
    }
    
    private func stopPlayer(_ result: @escaping FlutterResult) {
        if mPlayerNode.isPlaying {
            mPlayerNode.stop()
        }
        sendPlayerStatus(SoundStreamStatus.Stopped)
        result(true)
    }
    
    private func sendPlayerStatus(_ status: SoundStreamStatus) {
        sendEventMethod("playerStatus", status.rawValue)
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
        
        mPlayerNode.stop()

        let timeToStart = AVAudioTime(sampleTime: Int64(seekTime * mPlayerSampleRate), atRate: mPlayerSampleRate)
        let buffer = try! bytesToAudioBuffer(mPlayerBuffer)
        mPlayerNode.scheduleBuffer(convertBufferFormat(
            buffer,
            from: mPlayerInputFormat,
            to: mPlayerOutputFormat
        ), at: timeToStart, options: [], completionHandler: nil)

        mPlayerNode.play()
    }
    
    private func pushPlayerChunk(_ chunk: [UInt8], _ result: @escaping FlutterResult) {
        guard let buffer = try? bytesToAudioBuffer(chunk) else {
            result(true);
            return
        }
        mPlayerBuffer.append(contentsOf: chunk)
        let chunkBufferLength = mPlayerBuffer.count
        mPlayerNode.scheduleBuffer(buffer,completionCallbackType: AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack) { _ in
            if (chunkBufferLength < self.mPlayerBuffer.count)
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
    
    private func audioBufferToBytes(_ audioBuffer: AVAudioPCMBuffer) -> [UInt8] {
        let srcLeft = audioBuffer.int16ChannelData![0]
        let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
        let numBytes = Int(bytesPerFrame * audioBuffer.frameLength)
        
        // initialize bytes by 0
        var audioByteArray = [UInt8](repeating: 0, count: numBytes)
        
        srcLeft.withMemoryRebound(to: UInt8.self, capacity: numBytes) { srcByteData in
            audioByteArray.withUnsafeMutableBufferPointer {
                $0.baseAddress!.initialize(from: srcByteData, count: numBytes)
            }
        }
        
        return audioByteArray
    }
    
    private func bytesToAudioBuffer(_ buf: [UInt8]) throws -> AVAudioPCMBuffer {
        // Create a temporary file to hold the MP3 data
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
   
        var data = Data(buf)
          
        if !mp3Header.isEmpty {
            data = Data(mp3Header) + data
        } else if buf.count >= 4 {
            mp3Header = Array(buf[0..<4])
        }
        
        try data.write(to: tempURL)

        // Open the MP3 file
        guard let audioFile = try? AVAudioFile(forReading: tempURL) else {
            throw NSError(domain: "Error opening MP3 file", code: 1, userInfo: nil)
        }

        // Create a buffer in PCM format
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: mPlayerOutputFormat!, frameCapacity: UInt32(audioFile.length)) else {
            throw NSError(domain: "Error creating PCM buffer", code: 2, userInfo: nil)
        }

        // Read the entire MP3 file into the buffer
        try audioFile.read(into: audioBuffer)

        // Delete the temporary file
        try FileManager.default.removeItem(at: tempURL)

        return audioBuffer
    }
}

