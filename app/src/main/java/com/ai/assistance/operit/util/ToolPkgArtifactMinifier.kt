package com.ai.assistance.operit.util

import android.content.Context
import com.ai.assistance.operit.core.tools.packTool.ToolPkgArchiveParser
import com.ai.assistance.operit.core.tools.packTool.ToolPkgManifest
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Produces standard ToolPkg and script artifacts with executable JavaScript AST-minified. */
object ToolPkgArtifactMinifier {
    private const val MARKET_ORIGIN_CAPTURE_METHOD = "_m"
    private const val MARKET_ORIGIN_XOR_KEY = 0x5A

    fun minifyArtifactFile(context: Context, sourceFile: File, isToolPkg: Boolean): ByteArray {
        return ToolPkgJsAstMinifier(context).use { minifier ->
            if (isToolPkg) {
                minifyToolPkgArchive(sourceFile, minifier)
            } else {
                minifyScriptFile(sourceFile, minifier)
            }
        }
    }

    private fun minifyScriptFile(sourceFile: File, minifier: ToolPkgJsAstMinifier): ByteArray {
        return minifyJavaScriptBytes(sourceFile.readBytes(), sourceFile.name, minifier)
    }

    private fun minifyToolPkgArchive(sourceFile: File, minifier: ToolPkgJsAstMinifier): ByteArray {
        val manifestPreview =
            ToolPkgArchiveParser.readToolPkgManifestPreview { sourceFile.inputStream() }
                ?: throw IllegalArgumentException("manifest.hjson or manifest.json not found")
        val manifestBasePath = manifestPreview.entryName.substringBeforeLast('/', missingDelimiterValue = "")
        val manifestEntryName =
            ToolPkgArchiveParser.normalizeZipEntryPath(manifestPreview.entryName)
                ?: throw IllegalArgumentException("Invalid toolpkg manifest entry name")
        val executableEntryNames = linkedSetOf<String>()
        val resourceEntryRoots = linkedSetOf<String>()

        val mainEntryName =
            ToolPkgArchiveParser.resolveManifestRelativeZipEntryPath(
            manifestBasePath,
            manifestPreview.manifest.main
        ) ?: throw IllegalArgumentException("manifest.main is required")
        executableEntryNames.add(mainEntryName)
        val marketOriginInvocation = buildMarketOriginInvocation(manifestPreview.manifest)
        manifestPreview.manifest.subpackages.forEach { subpackage ->
            ToolPkgArchiveParser.resolveManifestRelativeZipEntryPath(manifestBasePath, subpackage.entry)
                ?.let(executableEntryNames::add)
        }
        manifestPreview.manifest.resources.forEach { resource ->
            ToolPkgArchiveParser.resolveManifestRelativeResourcePath(manifestBasePath, resource.path)
                ?.let(resourceEntryRoots::add)
        }

        val outputBytes = ByteArrayOutputStream()
        ZipFile(sourceFile).use { archive ->
            ZipOutputStream(outputBytes).use { zipOutput ->
                val entries = archive.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    val copiedEntry = ZipEntry(entry.name).apply {
                        time = entry.time
                        comment = entry.comment
                    }
                    zipOutput.putNextEntry(copiedEntry)
                    if (!entry.isDirectory) {
                        val normalizedName = ToolPkgArchiveParser.normalizeZipEntryPath(entry.name)
                        val originalBytes = archive.getInputStream(entry).use { input -> input.readBytes() }
                        val outputEntryBytes =
                            if (
                                normalizedName != null &&
                                    normalizedName != manifestEntryName &&
                                    shouldMinifyToolPkgEntry(
                                        normalizedName,
                                        executableEntryNames,
                                        resourceEntryRoots
                                    )
                            ) {
                                minifyJavaScriptBytes(
                                    bytes = originalBytes,
                                    entryName = normalizedName,
                                    minifier = minifier,
                                    appendedSource =
                                        if (normalizedName == mainEntryName) {
                                            marketOriginInvocation
                                        } else {
                                            null
                                        }
                                )
                            } else {
                                originalBytes
                            }
                        zipOutput.write(outputEntryBytes)
                    }
                    zipOutput.closeEntry()
                }
            }
        }
        return outputBytes.toByteArray()
    }

    private fun minifyJavaScriptBytes(
        bytes: ByteArray,
        entryName: String,
        minifier: ToolPkgJsAstMinifier,
        appendedSource: String? = null
    ): ByteArray {
        val source = bytes.toString(StandardCharsets.UTF_8) +
            appendedSource?.let { "\n$it\n" }.orEmpty()
        val minified = minifyJavaScriptSourcePreservingMetadata(source, entryName, minifier)
        return minified.toByteArray(StandardCharsets.UTF_8)
    }

    /** Keeps market origin out of plain text while letting main initialization report it. */
    internal fun buildMarketOriginInvocation(manifest: ToolPkgManifest): String {
        val payload =
            buildJsonObject {
                put("market", "Operit")
                put("toolpkgId", manifest.toolpkgId)
                put("version", manifest.version)
                put("author", JsonArray(manifest.author.map { value -> JsonPrimitive(value) }))
            }
                .toString()
        val asciiPayload = buildString {
            payload.forEach { character ->
                if (character.code < 0x80) {
                    append(character)
                } else {
                    append("\\u")
                    append(character.code.toString(16).padStart(4, '0'))
                }
            }
        }
        val encoded =
            asciiPayload.toByteArray(StandardCharsets.UTF_8)
                .map { byte -> (byte.toInt() and 0xFF) xor MARKET_ORIGIN_XOR_KEY }
        val encodedJson = JsonArray(encoded.map { value -> JsonPrimitive(value) })
        return "ToolPkg.$MARKET_ORIGIN_CAPTURE_METHOD($encodedJson,$MARKET_ORIGIN_XOR_KEY);"
    }

    private fun minifyJavaScriptSourcePreservingMetadata(
        source: String,
        entryName: String,
        minifier: ToolPkgJsAstMinifier
    ): String {
        val split = splitLeadingMetadataBlock(source)
        if (split != null) {
            val body = split.body.trim()
            require(body.isNotEmpty()) { "JavaScript body after METADATA is empty for $entryName" }
            return split.metadataBlock + minifier.minify(body, entryName)
        }
        return minifier.minify(source, entryName)
    }

    private fun splitLeadingMetadataBlock(source: String): MetadataSplit? {
        val trimmed = source.trimStart()
        val leadingWhitespaceSize = source.length - trimmed.length
        if (!trimmed.startsWith("/*")) return null

        val commentBody = trimmed.substring(2)
        val label = commentBody.trimStart()
        if (!startsWithMetadataLabel(label)) return null

        val commentEnd = trimmed.indexOf("*/")
        if (commentEnd < 0) return null

        val metadataEnd = leadingWhitespaceSize + commentEnd + 2
        return MetadataSplit(
            metadataBlock = source.substring(0, metadataEnd),
            body = source.substring(metadataEnd)
        )
    }

    private fun startsWithMetadataLabel(commentBody: String): Boolean {
        if (!commentBody.startsWith("METADATA")) return false
        val afterLabel = commentBody.substring("METADATA".length)
        val first = afterLabel.firstOrNull() ?: return true
        return first.isWhitespace() || first == '*'
    }

    private fun shouldMinifyToolPkgEntry(
        normalizedName: String,
        executableEntryNames: Set<String>,
        resourceEntryRoots: Set<String>
    ): Boolean {
        if (resourceEntryRoots.any { root -> normalizedName == root || normalizedName.startsWith("$root/") }) {
            return false
        }
        if (executableEntryNames.contains(normalizedName)) return true
        val extension = normalizedName.substringAfterLast('.', missingDelimiterValue = "").lowercase()
        return extension in setOf("js", "mjs", "cjs", "ts", "jsx", "tsx")
    }

    private data class MetadataSplit(
        val metadataBlock: String,
        val body: String
    )
}
