package nz.co.rdev.sound_stream

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.*
import android.media.AudioRecord.OnRecordPositionUpdateListener
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer
import java.util.Timer
import kotlin.concurrent.timerTask

enum class SoundStreamErrors {
  FailedToRecord,
  FailedToPlay,
  FailedToStop,
  FailedToWriteBuffer,
  Unknown,
}

enum class SoundStreamStatus {
  Unset,
  Initialized,
  Playing,
  Stopped,
}

/** SoundStreamPlugin */
class SoundStreamPlugin :
    FlutterPlugin,
    MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener,
    ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var methodChannel: MethodChannel

  private val logTag = "SoundStreamPlugin"
  private val audioRecordPermissionCode = 14887
  private var currentActivity: Activity? = null
  private var pluginContext: Context? = null
  private var permissionToRecordAudio: Boolean = false
  private var activeResult: Result? = null
  private var debugLogging: Boolean = false

  // ========= Recorder's vars
  private val mRecordFormat = AudioFormat.ENCODING_PCM_16BIT
  private var mRecordSampleRate = 16000 // 16Khz
  private var mRecorderBufferSize = 8192
  private var mPeriodFrames = 8192
  private var audioData: ShortArray? = null
  private var mRecorder: AudioRecord? = null
  private var mListener: OnRecordPositionUpdateListener? = null

  // ========= Player's vars
  private var mAudioTrack: AudioTrack? = null
  private var mAudioManager: AudioManager? = null
  private var mPlayerSampleRate = 16000 // 16Khz
  private var mPlayerBufferSize = 10240
  private var mPlayerBuffer = emptyArray<ShortArray>()
  private var mPlayerTimer: Timer? = null
  private var mPlayerFormat: AudioFormat =
      AudioFormat.Builder()
          .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
          .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
          .setSampleRate(mPlayerSampleRate)
          .build()

  /** ======== Basic Plugin initialization ======== */
  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    pluginContext = flutterPluginBinding.applicationContext;
    methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "sound_stream")
    methodChannel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {

    try {
      when (call.method) {
        "hasPermission" -> hasPermission(result)
        "usePhoneSpeaker" -> usePhoneSpeaker(call, result)
        "initializeRecorder" -> initializeRecorder(call, result)
        "startRecording" -> startRecording(result)
        "stopRecording" -> stopRecording(result)
        "initializePlayer" -> initializePlayer(call, result)
        "startPlayer" -> startPlayer(result)
        "stopPlayer" -> stopPlayer(result)
        "getPlayerBuffer" -> getPlayerBuffer(call, result)
        "writeChunk" -> writeChunk(call, result)
        "seek" -> seek(call, result)
        "changePlayerSpeed" -> changePlayerSpeed(call, result)
        "checkCurrentTime" -> checkCurrentTime(call, result)
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.e(logTag, "Unexpected exception", e)
      result.error(SoundStreamErrors.Unknown.name, "Unexpected exception", e.localizedMessage)
    }
  }

  override fun onDetachedFromActivity() {
//        currentActivity
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    mListener?.onMarkerReached(null)
    mListener?.onPeriodicNotification(null)
    mListener = null
    mRecorder?.stop()
    mRecorder?.release()
    mRecorder = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    currentActivity = binding.activity
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    currentActivity = binding.activity
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    //        currentActivity = null
  }

  /** ======== Plugin methods ======== */
  private fun hasRecordPermission(): Boolean {
    if (permissionToRecordAudio) return true

    val localContext = pluginContext
    permissionToRecordAudio =
        localContext != null &&
            ContextCompat.checkSelfPermission(localContext, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
    return permissionToRecordAudio
  }

  private fun hasPermission(result: Result) {
    result.success(hasRecordPermission())
  }

  private fun requestRecordPermission() {
    val localActivity = currentActivity
    if (!hasRecordPermission() && localActivity != null) {
      debugLog("requesting RECORD_AUDIO permission")
      ActivityCompat.requestPermissions(
          localActivity,
          arrayOf(Manifest.permission.RECORD_AUDIO),
          audioRecordPermissionCode
      )
    }
  }

  override fun onRequestPermissionsResult(
      requestCode: Int,
      permissions: Array<out String>,
      grantResults: IntArray
  ): Boolean {
    when (requestCode) {
      audioRecordPermissionCode -> {

          permissionToRecordAudio =
              grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED

        completeInitializeRecorder()
        return true
      }
    }
    return false
  }

  private fun initializeRecorder( call: MethodCall,  result: Result) {
    initAudioManager()
    mRecordSampleRate = call.argument<Int>("sampleRate") ?: mRecordSampleRate
    debugLogging = call.argument<Boolean>("showLogs") ?: false
    mPeriodFrames =
        AudioRecord.getMinBufferSize(mRecordSampleRate, AudioFormat.CHANNEL_IN_MONO, mRecordFormat)
    mRecorderBufferSize = mPeriodFrames * 2
    audioData = ShortArray(mPeriodFrames)
    activeResult = result

    val localContext = pluginContext
    if (null == localContext) {
      completeInitializeRecorder()
      return
    }
    permissionToRecordAudio =
        ContextCompat.checkSelfPermission(localContext, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    if (!permissionToRecordAudio) {
      requestRecordPermission()
    } else {
      debugLog("has permission, completing")
      completeInitializeRecorder()
    }

    debugLog("leaving initializeIfPermitted")
  }

  private fun initRecorder() {
    if (mRecorder?.state == AudioRecord.STATE_INITIALIZED) {
      return
    }
    mRecorder =
        AudioRecord(
            MediaRecorder.AudioSource.MIC,
            mRecordSampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            mRecordFormat,
            mRecorderBufferSize
        )

      mListener = createRecordListener()
      mRecorder?.positionNotificationPeriod = mPeriodFrames
      mRecorder?.setRecordPositionUpdateListener(mListener)

  }

  private fun completeInitializeRecorder() {

    debugLog("completeInitialize")
    val initResult: HashMap<String, Any> = HashMap()

    if (permissionToRecordAudio) {
      mRecorder?.release()
      initRecorder()
      initResult["isMeteringEnabled"] = true
      sendRecorderStatus(SoundStreamStatus.Initialized)
    }

    initResult["success"] = permissionToRecordAudio
    debugLog("sending result")
    activeResult?.success(initResult)
    debugLog("leaving complete")
    activeResult = null
  }

  private fun sendEventMethod(name: String, data: Any) {
    val eventData: HashMap<String, Any> = HashMap()
    eventData["name"] = name
    eventData["data"] = data
    methodChannel.invokeMethod("platformEvent", eventData)
  }

  private fun debugLog(msg: String) {
    if (debugLogging) {
      Log.d(logTag, msg)
    }
  }

  private fun startRecording(result: Result) {
    try {
      if (mRecorder?.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
        result.success(true)
        return
      }
      initRecorder()
      mRecorder!!.startRecording()
      sendRecorderStatus(SoundStreamStatus.Playing)
      result.success(true)
    } catch (e: IllegalStateException) {
      debugLog("record() failed")
      result.error(
          SoundStreamErrors.FailedToRecord.name,
          "Failed to start recording",
          e.localizedMessage
      )
    }
  }

  private fun stopRecording(result: Result) {
    try {
      if (mRecorder!!.recordingState == AudioRecord.RECORDSTATE_STOPPED) {
        result.success(true)
        return
      }
      mRecorder!!.stop()
      sendRecorderStatus(SoundStreamStatus.Stopped)
      result.success(true)
    } catch (e: IllegalStateException) {
      debugLog("record() failed")
      result.error(
          SoundStreamErrors.FailedToRecord.name,
          "Failed to start recording",
          e.localizedMessage
      )
    }
  }

  private fun sendRecorderStatus(status: SoundStreamStatus) {
    sendEventMethod("recorderStatus", status.name)
  }

  private fun initAudioManager() {
    if (mAudioManager != null) return
    mAudioManager = currentActivity?.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  }

  private fun startTimer() {
    mPlayerTimer = Timer()

    mPlayerTimer?.schedule(timerTask {
      val timestamp = AudioTimestamp()
      mAudioTrack?.getTimestamp(timestamp)

      val framePosition = timestamp.framePosition.toInt()
      val bufferFrames = mPlayerBuffer.sumBy { it.size }

      if (framePosition >= bufferFrames) {
        // AudioTrack has finished playing
        println("AudioTrack has finished playing")
        val handler = Handler(Looper.getMainLooper())

        handler.postDelayed({
          val delayedFrames = mPlayerBuffer.sumBy { it.size }
          if (delayedFrames == bufferFrames) {
            println("AudioTrack has finished playing")
            sendPlayerStatus(SoundStreamStatus.Stopped)
            stopTimer()
          }
        }, 500) //


      }
    }, 0, 500) // Run every second
  }

  private fun stopTimer() {
    mPlayerTimer?.cancel()
    mPlayerTimer = null
  }

  private fun initializePlayer(call: MethodCall, result: Result) {
    initAudioManager()
    stopTimer()
    mPlayerBuffer = emptyArray()
    mPlayerSampleRate = call.argument<Int>("sampleRate") ?: mPlayerSampleRate
    debugLogging = call.argument<Boolean>("showLogs") ?: false
    mPlayerFormat =
        AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .setSampleRate(mPlayerSampleRate)
            .build()

    mPlayerBufferSize =
        AudioTrack.getMinBufferSize(
            mPlayerSampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

    if (mAudioTrack?.state == AudioTrack.STATE_INITIALIZED) {
      mAudioTrack?.release()
    }

    val audioAttributes =
        AudioAttributes.Builder()
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .setLegacyStreamType(AudioManager.STREAM_MUSIC)
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)

            .build()
    mAudioTrack =
        AudioTrack(
            audioAttributes,
            mPlayerFormat,
            mPlayerBufferSize * 4,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )
    mAudioManager?.mode = AudioManager.MODE_NORMAL
    /// Reset playback speed?
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val playbackParams = PlaybackParams()
      playbackParams.speed = 1.0f
      mAudioTrack?.playbackParams = playbackParams
    }

    result.success(true)
    sendPlayerStatus(SoundStreamStatus.Initialized)
  }

  private fun usePhoneSpeaker(call: MethodCall, result: Result) {
    val useSpeaker = call.argument<Boolean>("value") ?: false
    mAudioManager?.mode =
        if (useSpeaker) AudioManager.MODE_IN_COMMUNICATION else AudioManager.MODE_NORMAL
    result.success(true)
  }

  private fun checkCurrentTime(call: MethodCall, result: Result){
    val audioTimestamp = AudioTimestamp()
    val success = mAudioTrack?.getTimestamp(audioTimestamp)
    if (success == true) {
      debugLog(audioTimestamp.framePosition.toString());
      val framePosition = audioTimestamp.framePosition
      val timeInSeconds = framePosition.toDouble() / mPlayerSampleRate
      result.success(timeInSeconds)
    } else {
      // getTimestamp failed
      result.error("internal","getTimeStampFailed",null);
    }
  }

  private fun getPlayerBuffer(call: MethodCall, result: Result){
    val flatArray = mPlayerBuffer.flatMap { it.toList() }

    val byteBuffer = ByteBuffer.allocate(flatArray.size * 2)
    byteBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(flatArray.toShortArray())

    result.success(byteBuffer.array());
  }

  private fun changePlayerSpeed(call: MethodCall, result: Result) {
    val speed = call.argument<Double>("speed")
    if (speed != null) {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        val playbackParams = PlaybackParams()
        playbackParams.speed = speed.toFloat()
        mAudioTrack?.playbackParams = playbackParams
      }
      result.success(true)
    } else {
      result.error(
              SoundStreamErrors.FailedToWriteBuffer.name,
              "Failed to change Player speed",
              "'speed' is null"
      )
    }
  }

  private fun seek(call: MethodCall, result: Result) {
    val seekTime = call.argument<Double>("seekTime")
    if (seekTime != null) {
      val channels = 1

      val offsetInShorts = (seekTime * mPlayerSampleRate * channels).toInt()

      mAudioTrack?.pause()
      mAudioTrack?.flush();
      mAudioTrack!!.play()
      var currentPosition = 0
      mPlayerBuffer.forEach {

        /// Seek position by writting to mAudioTrack
        /// If current position is before offset, just skip
        /// Then if is current shortArray entry, start from offsetInShorts
        /// And then just continue feeding buffer

        if (currentPosition + it.size < offsetInShorts) {
        /// Skip
        }
        else if (currentPosition + it.size > offsetInShorts && currentPosition + it.size < offsetInShorts + it.size)
        {
          mAudioTrack?.write(it, offsetInShorts, it.size)
        }
        else{
          mAudioTrack?.write(it, 0, it.size)
        }

        currentPosition += it.size
        
      }


      result.success(true)
    } else {
      result.error(
              SoundStreamErrors.FailedToWriteBuffer.name,
              "Failed to seek Player ",
              "'seekTime' is null"
      )
    }
  }
  private fun writeChunk(call: MethodCall, result: Result) {
    val data = call.argument<ByteArray>("data")
    if (data != null) {
      pushPlayerChunk(data, result)
    } else {
      result.error(
          SoundStreamErrors.FailedToWriteBuffer.name,
          "Failed to write Player buffer",
          "'data' is null"
      )
    }
  }

  private fun pushPlayerChunk(chunk: ByteArray, result: Result) {
    try {
      val buffer = ByteBuffer.wrap(chunk)
      val shortBuffer = ShortBuffer.allocate(chunk.size / 2)
      shortBuffer.put(buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer())
      val shortChunk = shortBuffer.array()

      mAudioTrack?.write(shortChunk, 0, shortChunk.size)
      mPlayerBuffer += shortChunk
      result.success(true)
    } catch (e: Exception) {
      result.error(
          SoundStreamErrors.FailedToWriteBuffer.name,
          "Failed to write Player buffer",
          e.localizedMessage
      )
    }
  }

  private fun startPlayer(result: Result) {
    try {
      if (mAudioTrack?.state == AudioTrack.PLAYSTATE_PLAYING) {
        result.success(true)
        return
      }

      mAudioTrack!!.play()
      startTimer()
      sendPlayerStatus(SoundStreamStatus.Playing)
      result.success(true)
    } catch (e: Exception) {
      result.error(
          SoundStreamErrors.FailedToPlay.name,
          "Failed to start Player",
          e.localizedMessage
      )
    }
  }

  private fun stopPlayer(result: Result) {
    try {
      if (mAudioTrack?.state == AudioTrack.STATE_INITIALIZED) {
        mAudioTrack?.stop()
      }
      stopTimer()
      sendPlayerStatus(SoundStreamStatus.Stopped)
      result.success(true)
    } catch (e: Exception) {
      result.error(SoundStreamErrors.FailedToStop.name, "Failed to stop Player", e.localizedMessage)
    }
  }

  private fun sendPlayerStatus(status: SoundStreamStatus) {
    sendEventMethod("playerStatus", status.name)
  }

  private fun createRecordListener(): OnRecordPositionUpdateListener {
    return object : OnRecordPositionUpdateListener {
      override fun onMarkerReached(recorder: AudioRecord) {
        recorder.read(audioData!!, 0, mRecorderBufferSize)
      }

      override fun onPeriodicNotification(recorder: AudioRecord) {
        val data = audioData!!
        val shortOut = recorder.read(data, 0, mPeriodFrames)
        // this condistion to prevent app crash from happening in Android Devices
        // See issues: https://github.com/CasperPas/flutter-sound-stream/issues/25
        if (shortOut < 1) {
          return
        }
        // https://flutter.io/platform-channels/#codec
        // convert short to int because of platform-channel's limitation
        val byteBuffer = ByteBuffer.allocate(shortOut * 2)
        byteBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(data)

        sendEventMethod("dataPeriod", byteBuffer.array())
      }
    }
  }
}
