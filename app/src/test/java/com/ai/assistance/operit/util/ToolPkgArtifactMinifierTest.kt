package com.ai.assistance.operit.util

import com.ai.assistance.operit.core.tools.packTool.ToolPkgManifest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolPkgArtifactMinifierTest {
    @Test
    fun `market origin invocation keeps metadata encoded`() {
        val invocation =
            ToolPkgArtifactMinifier.buildMarketOriginInvocation(
                ToolPkgManifest(
                    toolpkgId = "market_flow_toolpkg",
                    version = "1.0.0",
                    main = "main.js",
                    author = listOf("Original Author")
                )
            )

        assertTrue(invocation.startsWith("ToolPkg._m("))
        assertFalse(invocation.contains("Operit"))
        assertFalse(invocation.contains("Original Author"))
        assertFalse(invocation.contains("market_flow_toolpkg"))
    }
}
