package com.ai.assistance.operit.core.tools.packTool

import com.ai.assistance.operit.core.tools.javascript.JsEngine
import com.ai.assistance.operit.core.tools.javascript.ToolPkgMainRegistrationCapture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

class ToolPkgMainRegistrationScriptParserTest {
    @Test
    fun `matching marketplace origin is kept after main registration execution`() {
        val engine = mock<JsEngine>()
        whenever(
            engine.executeToolPkgMainRegistrationFunction(
                script = any(),
                functionName = any(),
                params = any()
            )
        ).thenReturn(
            ToolPkgMainRegistrationCapture(
                marketOrigin =
                    ToolPkgMarketOrigin(
                        market = " Operit ",
                        toolpkgId = " market_flow_toolpkg ",
                        version = " 1.0.0 ",
                        author = listOf(" Operit ", " Original Author ")
                    )
            )
        )

        val result =
            ToolPkgMainRegistrationScriptParser.parse(
                script = "function registerToolPkg() {}",
                toolPkgId = "market_flow_toolpkg",
                mainScriptPath = "main.js",
                jsEngine = engine
            )

        val registration = (result as ToolPkgMainRegistrationParseResult.Success).registration
        assertEquals(
            ToolPkgMarketOrigin(
                market = "Operit",
                toolpkgId = "market_flow_toolpkg",
                version = "1.0.0",
                author = listOf("Operit", "Original Author")
            ),
            registration.marketOrigin
        )
    }

    @Test
    fun `different toolpkg id does not produce a marketplace notice`() {
        val engine = mock<JsEngine>()
        whenever(
            engine.executeToolPkgMainRegistrationFunction(
                script = any(),
                functionName = any(),
                params = any()
            )
        ).thenReturn(
            ToolPkgMainRegistrationCapture(
                marketOrigin =
                    ToolPkgMarketOrigin(
                        market = "Operit",
                        toolpkgId = "other_toolpkg",
                        version = "1.0.0",
                        author = listOf("Operit")
                    )
            )
        )

        val result =
            ToolPkgMainRegistrationScriptParser.parse(
                script = "function registerToolPkg() {}",
                toolPkgId = "market_flow_toolpkg",
                mainScriptPath = "main.js",
                jsEngine = engine
            )

        val registration = (result as ToolPkgMainRegistrationParseResult.Success).registration
        assertNull(registration.marketOrigin)
    }
}
