package com.rexhep.inkandecho

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NativeAudioDecoder.CHANNEL)
            .setMethodCallHandler { call, result -> NativeAudioDecoder.handle(call, result) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NativeAudioDecoder.STREAM_CHANNEL)
            .setStreamHandler(NativeAudioDecoder.createStreamHandler())
    }
}
