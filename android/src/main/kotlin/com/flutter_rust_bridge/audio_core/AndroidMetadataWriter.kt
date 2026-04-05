package com.flutter_rust_bridge.audio_core

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.kyant.taglib.Picture
import com.kyant.taglib.PropertyMap
import com.kyant.taglib.TagLib
import java.io.File
import java.util.Locale

internal object AndroidMetadataWriter {
    fun updateMetadata(
        context: Context,
        path: String,
        metadata: Map<String, Any?>,
    ): Boolean {
        try {
            val mergedPropertyMap = buildMergedPropertyMap(context, path, metadata)
            val pictures = parsePictures(metadata["pictures"])

            val writableFile = openWritableFileDescriptor(context, path, metadata)
                ?: throw MetadataWriteException(
                    code = "OPEN_FAILED",
                    message = "Unable to open file descriptor.",
                    details = mapOf("path" to path),
                )

            writableFile.use { pfd ->
                val fd = pfd.detachForTagLib()
                TagLib.savePropertyMap(fd, propertyMap = mergedPropertyMap)

                if (!pictures.isNullOrEmpty()) {
                    val pictureFd = openWritableFileDescriptor(context, path, metadata)
                        ?: throw MetadataWriteException(
                            code = "OPEN_FAILED",
                            message = "Unable to open file descriptor for pictures.",
                            details = mapOf("path" to path),
                        )
                    pictureFd.use { pfdForPictures ->
                        val picturesFd = pfdForPictures.detachForTagLib()
                        TagLib.savePictures(
                            picturesFd,
                            pictures = pictures.toTypedArray(),
                        )
                    }
                }
            }

            return true
        } catch (e: android.app.RecoverableSecurityException) {
            throw e
        } catch (e: SecurityException) {
            throw e
        } catch (e: MetadataWriteException) {
            throw e
        } catch (e: Exception) {
            throw MetadataWriteException(
                code = "WRITE_EXCEPTION",
                message = e.message ?: "Unexpected metadata write failure.",
                details = mapOf(
                    "path" to path,
                    "exception" to e::class.java.name,
                ),
                cause = e,
            )
        }
    }

    private fun buildMergedPropertyMap(
        context: Context,
        path: String,
        metadata: Map<String, Any?>,
    ): PropertyMap {
        val merged = HashMap<String, Array<String>>()
        val currentPropertyMap = readCurrentPropertyMap(context, path, metadata)
        if (currentPropertyMap != null) {
            merged.putAll(currentPropertyMap)
        }

        putTextField(merged, "TITLE", metadata, "title", "TITLE")
        putMultiField(merged, "ARTIST", metadata, "artist", "ARTIST")
        putTextField(merged, "ALBUM", metadata, "album", "ALBUM")
        putMultiField(merged, "ALBUMARTIST", metadata, "albumArtist", "ALBUMARTIST")

        val trackNumber = firstPresent(metadata, "trackNumber", "TRACKNUMBER")
        val trackTotal = firstPresent(metadata, "trackTotal", "TRACKTOTAL")
        if (trackNumber != null) {
            merged["TRACKNUMBER"] = arrayOf(
                if (!trackTotal.isNullOrBlank()) {
                    "${trackNumber.trim()}/${trackTotal.trim()}"
                } else {
                    trackNumber.trim()
                }
            )
        }

        putTextField(merged, "DISCNUMBER", metadata, "discNumber", "DISCNUMBER")
        putTextField(merged, "DATE", metadata, "date", "DATE")

        val year = firstPresent(metadata, "year", "YEAR")
        if (!year.isNullOrBlank()) {
            merged["DATE"] = arrayOf(year.trim())
        }

        putMultiField(merged, "GENRE", metadata, "genres", "genre", "GENRE")
        putMultiField(merged, "COMPOSER", metadata, "composer", "COMPOSER")
        putMultiField(merged, "LYRICIST", metadata, "lyricist", "LYRICIST")
        putMultiField(merged, "PERFORMER", metadata, "performer", "PERFORMER")
        putMultiField(merged, "CONDUCTOR", metadata, "conductor", "CONDUCTOR")
        putMultiField(merged, "REMIXER", metadata, "remixer", "REMIXER")
        putTextField(merged, "COMMENT", metadata, "comment", "COMMENT")
        putTextField(merged, "LYRICS", metadata, "lyrics", "LYRICS")

        return merged
    }

    private fun readCurrentPropertyMap(
        context: Context,
        path: String,
        metadata: Map<String, Any?>,
    ): PropertyMap? {
        val readable = openReadableFileDescriptor(context, path, metadata) ?: return null
        return try {
            readable.use { pfd ->
                val fd = pfd.detachForTagLib()
                TagLib.getMetadata(fd)?.propertyMap
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun openReadableFileDescriptor(
        context: Context,
        path: String,
        metadata: Map<String, Any?>,
    ): ParcelFileDescriptor? {
        return openFileDescriptor(context, path, metadata, mode = "r")
    }

    private fun openWritableFileDescriptor(
        context: Context,
        path: String,
        metadata: Map<String, Any?>,
    ): ParcelFileDescriptor? {
        return openFileDescriptor(context, path, metadata, mode = "rw")
    }

    private fun openFileDescriptor(
        context: Context,
        path: String,
        metadata: Map<String, Any?>,
        mode: String,
    ): ParcelFileDescriptor? {
        fun openTarget(target: String): ParcelFileDescriptor? {
            return if (target.startsWith("content://")) {
                context.contentResolver.openFileDescriptor(Uri.parse(target), mode)
            } else {
                val file = File(target)
                if (!file.exists()) {
                    throw java.io.FileNotFoundException("File does not exist: $target")
                }
                val pfdMode = if (mode.contains("w")) {
                    ParcelFileDescriptor.MODE_READ_WRITE
                } else {
                    ParcelFileDescriptor.MODE_READ_ONLY
                }
                ParcelFileDescriptor.open(file, pfdMode)
            }
        }

        val candidates = buildList {
            add(path)
            metadata["fallbackMediaUri"]
                ?.toString()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.let { add(it) }
        }

        var lastError: Exception? = null
        for (candidate in candidates) {
            try {
                return openTarget(candidate)
            } catch (e: Exception) {
                lastError = e
            }
        }

        if (lastError != null) {
            throw MetadataWriteException(
                code = "OPEN_FAILED",
                message = lastError.message ?: "Unable to open file descriptor.",
                details = mapOf(
                    "path" to path,
                    "mode" to mode,
                    "exception" to lastError.javaClass.name,
                    "fallbackMediaUri" to metadata["fallbackMediaUri"]?.toString(),
                ),
                cause = lastError,
            )
        }

        return null
    }

    private fun putTextField(
        target: PropertyMap,
        tagKey: String,
        metadata: Map<String, Any?>,
        vararg sourceKeys: String,
    ) {
        val value = firstPresent(metadata, *sourceKeys)?.trim()?.takeIf { it.isNotEmpty() } ?: return
        target[tagKey] = arrayOf(value)
    }

    private fun putMultiField(
        target: PropertyMap,
        tagKey: String,
        metadata: Map<String, Any?>,
        vararg sourceKeys: String,
    ) {
        val values = readMultiValues(metadata, *sourceKeys)
        if (values.isNotEmpty()) {
            target[tagKey] = values.toTypedArray()
        }
    }

    private fun readMultiValues(
        metadata: Map<String, Any?>,
        vararg sourceKeys: String,
    ): List<String> {
        for (sourceKey in sourceKeys) {
            val raw = metadata[sourceKey] ?: continue
            when (raw) {
                is Iterable<*> -> {
                    val values = raw.mapNotNull {
                        it?.toString()?.trim()?.takeIf { value -> value.isNotEmpty() }
                    }
                    if (values.isNotEmpty()) return values
                }

                is Array<*> -> {
                    val values = raw.mapNotNull {
                        it?.toString()?.trim()?.takeIf { value -> value.isNotEmpty() }
                    }
                    if (values.isNotEmpty()) return values
                }

                is String -> {
                    val values = raw.split(",")
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                    if (values.isNotEmpty()) return values
                }

                else -> {
                    val text = raw.toString().trim()
                    if (text.isNotEmpty()) {
                        return text.split(",")
                            .map { it.trim() }
                            .filter { value -> value.isNotEmpty() }
                    }
                }
            }
        }
        return emptyList()
    }

    private fun firstPresent(
        metadata: Map<String, Any?>,
        vararg keys: String,
    ): String? {
        for (key in keys) {
            val raw = metadata[key] ?: continue
            val text = when (raw) {
                is String -> raw
                is Number -> raw.toString()
                else -> raw.toString()
            }.trim()
            if (text.isNotEmpty()) return text
        }
        return null
    }

    private fun parsePictures(rawPictures: Any?): List<Picture>? {
        val pictures = rawPictures as? List<*> ?: return null
        if (pictures.isEmpty()) return emptyList()

        return pictures.mapNotNull { raw ->
            val map = raw as? Map<*, *> ?: return@mapNotNull null
            val bytes = when (val value = map["bytes"]) {
                is ByteArray -> value
                is List<*> -> value.mapNotNull { item ->
                    when (item) {
                        is Number -> item.toByte()
                        else -> null
                    }
                }.toByteArray()
                else -> null
            } ?: return@mapNotNull null

            val mimeType = map["mimeType"]?.toString()?.takeIf { it.isNotBlank() }
                ?: "image/jpeg"
            val pictureType = map["pictureType"]?.toString()?.takeIf { it.isNotBlank() }
                ?: "Front cover"
            val description = map["description"]?.toString()?.takeIf { it.isNotBlank() }
                ?: pictureType

            Picture(
                data = bytes,
                mimeType = mimeType,
                description = description,
                pictureType = pictureType,
            )
        }
    }

    private fun ParcelFileDescriptor.detachForTagLib(): Int {
        return dup()?.detachFd() ?: throw MetadataWriteException(
            code = "OPEN_FAILED",
            message = "Unable to detach file descriptor for TagLib.",
            details = emptyMap(),
        )
    }

    private fun List<Number>.toByteArray(): ByteArray {
        val result = ByteArray(size)
        for (i in indices) {
            result[i] = this[i].toByte()
        }
        return result
    }
}
