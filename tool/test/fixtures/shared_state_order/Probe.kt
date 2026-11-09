package com.follow.clash

import com.follow.clash.models.SharedState
import com.follow.clash.plugins.ServicePlugin
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.JsonDeserializer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private class Reply : MethodChannel.Result {
    val done = CountDownLatch(1)
    var value: Any? = null
    override fun success(result: Any?) { value = result; done.countDown() }
    override fun error(code: String, message: String?, details: Any?) = error("Unexpected channel error: $code")
    override fun notImplemented() = error("Unexpected method")
    fun await() { check(done.await(5, TimeUnit.SECONDS)) { "Reply timed out" } }
}

object Probe {
    @JvmStatic
    fun main(args: Array<String>) {
        val mode = args[0]
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val plain = Gson()
        val controlled = GsonBuilder().registerTypeAdapter(SharedState::class.java,
            JsonDeserializer<SharedState> { json, _, _ ->
                val state = plain.fromJson(json, SharedState::class.java)
                if (mode == "reordered" && state.currentProfileName == "older") {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS)) { "Old parse not released" }
                }
                state
            }).create()
        val plugin = ServicePlugin()
        val binding = FlutterPlugin.FlutterPluginBinding(object : BinaryMessenger {})
        plugin.onAttachedToEngine(binding)
        ServicePlugin::class.java.getDeclaredField("gson").apply {
            isAccessible = true
            set(plugin, controlled)
        }
        fun send(text: String): Reply = Reply().also {
            plugin.onMethodCall(MethodCall("syncState", text), it)
        }
        fun currentName(): String {
            val machine = ServiceState::class.java.getDeclaredField("machine").apply {
                isAccessible = true
            }.get(null)
            return (machine.javaClass.getDeclaredField("sharedState").apply {
                isAccessible = true
            }.get(machine) as SharedState).currentProfileName
        }
        try {
            val old = send("""{"currentProfileName":"older"}""")
            if (mode == "reordered") check(entered.await(5, TimeUnit.SECONDS)) else old.await()
            val newer = send("""{"currentProfileName":"newer"}""")
            newer.await()
            val beforeRelease = currentName()
            if (mode == "reordered") { release.countDown(); old.await() }
            if (mode == "invalid") {
                val invalid = send("{")
                invalid.await()
                check(invalid.value == "Invalid shared state")
            }
            val actual = currentName()
            check(old.value == "" && newer.value == "")
            val result = mapOf("mode" to mode, "before_release" to beforeRelease,
                "actual" to actual, "expected" to "newer", "passed" to (actual == "newer"))
            File(args[1]).writeText(plain.toJson(result))
            println(plain.toJson(result))
            check(actual == "newer") { "Older syncState overwrote the newer payload" }
        } finally {
            release.countDown()
            plugin.onDetachedFromEngine(binding)
        }
    }
}
