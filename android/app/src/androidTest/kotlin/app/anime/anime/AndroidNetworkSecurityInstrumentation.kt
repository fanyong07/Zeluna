package app.anime.anime

import android.app.Activity
import android.app.Instrumentation
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.security.NetworkSecurityPolicy

class AndroidNetworkSecurityInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val results = Bundle()

        try {
            val context = targetContext
            val policy = NetworkSecurityPolicy.getInstance()

            check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
                "The target application is debuggable"
            }
            check(!policy.isCleartextTrafficPermitted) {
                "Cleartext traffic is globally permitted"
            }
            check(!policy.isCleartextTrafficPermitted("localtest.me")) {
                "Cleartext traffic is permitted for localtest.me"
            }
            results.putString("stream", "Release network security assertions passed\n")
            finish(Activity.RESULT_OK, results)
        } catch (error: Throwable) {
            results.putString("stream", "Release network security assertion failed: $error\n")
            finish(Activity.RESULT_CANCELED, results)
        }
    }
}
