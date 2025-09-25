package com.iranzipjc.gfcallapp

import dev.fluttercommunity.plus.androidalarmmanager.AndroidAlarmManagerPlugin
import io.flutter.embedding.android.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.PluginRegistry.PluginRegistrantCallback
import io.flutter.plugins.GeneratedPluginRegistrant

class Application : FlutterApplication(), PluginRegistrantCallback {
    override fun onCreate() {
        super.onCreate()
        AndroidAlarmManagerPlugin.setPluginRegistrant(this)
    }

    override fun registerWith(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
    }
}
