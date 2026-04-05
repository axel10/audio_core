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
            // Step 1:
            // Build the final tag map that will be written back to the file.
            // We do not write only the changed fields blindly. Instead, we first
            // read the current tags from the file and merge the new values on top.
            // That keeps any fields we do not explicitly edit from being lost.
            val mergedPropertyMap = buildMergedPropertyMap(context, path, metadata)

            // Step 2:
            // Pictures are handled separately because TagLib exposes a dedicated
            // savePictures() API. That mirrors the Metadator app's approach.
            val pictures = parsePictures(metadata["pictures"])

            // Step 3:
            // Open the audio file as a writable ParcelFileDescriptor.
            // TagLib works with integer file descriptors, so we later detach the
            // FD from the ParcelFileDescriptor and hand it to TagLib directly.
            val writableFile = openWritableFileDescriptor(context, path, metadata)
                ?: throw MetadataWriteException(
                    code = "OPEN_FAILED",
                    message = "Unable to open file descriptor.",
                    details = mapOf("path" to path),
                )

            writableFile.use { pfd ->
                // Step 4:
                // Convert the ParcelFileDescriptor into a raw fd for TagLib.
                // The duplicate() call gives TagLib its own handle so the wrapper
                // can be closed safely without affecting the original descriptor.
                val fd = pfd.detachForTagLib()

                // Step 5:
                // Write the text metadata (title, artist, album, lyrics, etc.).
                // The property keys are the TagLib keys, such as TITLE or ARTIST.
                TagLib.savePropertyMap(fd, propertyMap = mergedPropertyMap)

                if (!pictures.isNullOrEmpty()) {
                    // Step 6:
                    // Artwork is written in a second pass. If no artwork was selected,
                    // we simply leave the existing embedded pictures untouched.
                    val pictureFd = openWritableFileDescriptor(context, path, metadata)
                        ?: throw MetadataWriteException(
                            code = "OPEN_FAILED",
                            message = "Unable to open file descriptor for pictures.",
                            details = mapOf("path" to path),
                        )
                    pictureFd.use { pfdForPictures ->
                        val picturesFd = pfdForPictures.detachForTagLib()

                        // Step 7:
                        // Each picture is converted into TagLib's Picture model and then
                        // saved to the file as embedded artwork.
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
        // Start with the existing tags from the file so we preserve fields that
        // are not part of the current edit session.
        val merged = HashMap<String, Array<String>>()
        val currentPropertyMap = readCurrentPropertyMap(context, path, metadata)
        if (currentPropertyMap != null) {
            merged.putAll(currentPropertyMap)
        }

        // These helpers map our Flutter-side keys to TagLib keys.
        // If a field is absent in metadata, the existing value stays untouched.
        putTextField(merged, "TITLE", metadata, "title", "TITLE")
        putMultiField(merged, "ARTIST", metadata, "artist", "ARTIST")
        putTextField(merged, "ALBUM", metadata, "album", "ALBUM")
        putMultiField(merged, "ALBUMARTIST", metadata, "albumArtist", "ALBUMARTIST")

        // Track number and total tracks are often stored together as "3/12".
        // TagLib and many tag readers understand that representation.
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
        val date = firstPresent(metadata, "date", "DATE")
        if (!date.isNullOrBlank()) {
            // Keep the more specific date when it is available.
            merged["DATE"] = arrayOf(date.trim())
        } else {
            // Some callers only provide a numeric year, so we normalize it to DATE.
            val year = firstPresent(metadata, "year", "YEAR")
            if (!year.isNullOrBlank()) {
                merged["DATE"] = arrayOf(year.trim())
            }
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
        // Read mode is only used to obtain the current state of the tags.
        // If this fails for any reason, we still allow the write to continue
        // with the fields we were given from Flutter.
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
            // When the active playback path is a temporary/local alias, the media
            // library URI is a fallback that can still be approved for writing.
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
        // For single-value tags, write a one-element array because TagLib's
        // property map format stores every field as Array<String>.
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
        // Support both Flutter lists and comma-separated strings so callers can
        // pass either structure without caring about the native storage format.
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
        // Pictures are passed from Flutter as a list of maps:
        // { bytes, mimeType, pictureType, description }.
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
        // TagLib expects a raw integer fd. We duplicate the descriptor first so
        // the ParcelFileDescriptor can be closed independently after detaching.
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
