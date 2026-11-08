package ai.arce.app

import ai.arce.app.bridge.EngineBridge
import ai.arce.app.bridge.NotifyBridge
import ai.arce.app.bridge.SystemBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var engineBridge: EngineBridge? = null
    private var notifyBridge: NotifyBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        engineBridge = EngineBridge(applicationContext, messenger)
        SystemBridge(applicationContext, messenger)
        // the permission to notify is asked on this screen, so this bridge is given the Activity (weakly)
        notifyBridge?.detach()
        notifyBridge = NotifyBridge(this, messenger)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notifyBridge?.onPermissionResult(requestCode)
    }

    override fun onDestroy() {
        // keep the model loaded across a configuration change; free it only when the app is really closing
        if (isFinishing) engineBridge?.close()
        notifyBridge?.detach()
        notifyBridge = null
        super.onDestroy()
    }
}
