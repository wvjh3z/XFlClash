package com.follow.clash

import com.follow.clash.common.AccessControlMode
import com.follow.clash.models.SharedState
import com.follow.clash.service.models.AccessControlProps
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import com.google.gson.Gson
import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking

/** Plain-JVM probe: real SharedState/Gson/state machine; native I/O stops at QuickSetup. */
private class ForwardingHost(
    override val scope: CoroutineScope,
    private val stored: SharedState,
) : ServiceStateHost {
    override val runtime: ServiceRuntime? = null
    override val homeDirPath = "/isolated/fixture"
    override val sdkInt = 34
    var forwarded: String? = null
    var setupCalls = 0
    var startCalls = 0
    override fun log(message: String) {}
    override fun showToast(message: String) {}
    override fun updateNotificationParams(params: NotificationParams) {}
    override fun loadSharedState() = stored
    override fun isVpnPermissionGranted() = true
    override fun isLocalNetworkPermissionGranted() = true
    override fun tile(): TileGateway? = null
    override fun app(): AppGateway? = null
    override fun notifyStopped() {}
    override suspend fun quickSetup(initParams: String, setupParams: String): Result<String> {
        setupCalls++
        forwarded = setupParams
        return Result.failure(IllegalStateException("probe stops before VPN startup"))
    }
    override suspend fun startService(options: VpnOptions): Boolean {
        startCalls++
        error("must not start native services")
    }
    override suspend fun stopService() {}
}

object LegacySetupForwardingProbe {
    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val gson = Gson()
        val records = mutableListOf<Map<String, Any>>()
        for (legacy in listOf(true, false)) for (skip in listOf(true, false)) {
            val name = (if (legacy) "legacy" else "current") + (if (skip) "-true" else "-false")
            val url = "https://$name.invalid/204"
            val fields = "\"test-url\":\"$url\",\"skip-cert-verify\":$skip"
            val params = if (legacy) "{\"selected-map\":{\"G\":\"node\"},$fields}"
                else "{\"selected-map\":{\"G\":\"node\"},\"options\":{$fields}}"
            val initial = SharedState(
                vpnOptions = VpnOptions(true, 7890, false, false,
                    AccessControlProps(false, AccessControlMode.ACCEPT_SELECTED, emptyList(), emptyList()),
                    false, true, emptyList(), "gvisor", emptyList()),
                setupParams = JsonParser.parseString(params).asJsonObject,
            )
            val saved = gson.toJson(initial)
            val restored = gson.fromJson(saved, SharedState::class.java)
            val host = ForwardingHost(this, restored)
            ServiceStateMachine(host).handleStartAction()
            check(host.setupCalls == 1 && host.startCalls == 0)
            val forwarded = checkNotNull(host.forwarded)
            check(JsonParser.parseString(forwarded) == JsonParser.parseString(params))
            records += mapOf("name" to name, "url" to url, "skip" to skip,
                "forwarded" to forwarded, "setupCalls" to host.setupCalls,
                "nativeStartCalls" to host.startCalls)
        }
        File(args.single()).writeText(gson.toJson(records))
        println("4 persisted SharedState -> no-engine handleStartAction -> QuickSetup payloads captured; no native services started")
    }
}
