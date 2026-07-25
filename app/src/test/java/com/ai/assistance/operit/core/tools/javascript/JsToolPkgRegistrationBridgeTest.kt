package com.ai.assistance.operit.core.tools.javascript

import org.junit.Assert.assertTrue
import org.junit.Test

class JsToolPkgRegistrationBridgeTest {
    @Test
    fun `registration bridge exposes encoded marketplace capture through main execution`() {
        val bridge = buildToolPkgRegistrationBridgeScript()

        assertTrue(bridge.contains("function captureMarketOrigin(encoded, key)"))
        assertTrue(bridge.contains("registerToolPkgMarketOrigin"))
        assertTrue(bridge.contains("_m: captureMarketOrigin"))
    }
}
