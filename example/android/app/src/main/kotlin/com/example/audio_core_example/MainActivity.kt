package com.example.audio_core_example

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class MainActivity : AudioServiceActivity() {
    private val mediaLibraryChannelName = "audio_core.media_library"
    private val permissionRequestCode = 4892
    private var pendingPermissionResult: Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaLibraryChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureAudioPermission" -> handleEnsureAudioPermission(result)
                    "scanAudioLibrary" -> handleScanAudioLibrary(result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != permissionRequestCode) return

        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }

        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    private fun handleEnsureAudioPermission(result: Result) {
        if (hasAudioPermission()) {
            result.success(true)
            return
        }

        if (pendingPermissionResult != null) {
            result.error(
                "PERMISSION_PENDING",
                "An audio permission request is already in progress.",
                null,
            )
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            requiredPermissions(),
            permissionRequestCode,
        )
    }

    private fun handleScanAudioLibrary(result: Result) {
        if (!hasAudioPermission()) {
            result.error(
                "PERMISSION_DENIED",
                "Audio library permission has not been granted.",
                null,
            )
            return
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.RELATIVE_PATH,
            MediaStore.Audio.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DATA,
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"
        val items = mutableListOf<Map<String, Any?>>()

        contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            null,
            sortOrder,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val displayNameIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val titleIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val relativePathIndex = cursor.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
            val bucketNameIndex = cursor.getColumnIndex(MediaStore.Audio.Media.BUCKET_DISPLAY_NAME)
            val mimeTypeIndex = cursor.getColumnIndex(MediaStore.Audio.Media.MIME_TYPE)
            val dateAddedIndex = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_ADDED)
            val dataIndex = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                val contentUri = Uri.withAppendedPath(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    id.toString(),
                ).toString()
                val relativePath = if (relativePathIndex >= 0) cursor.getString(relativePathIndex) else null
                val dataPath = if (dataIndex >= 0) cursor.getString(dataIndex) else null
                val folderPath = relativePath?.takeIf { it.isNotBlank() }
                    ?: dataPath?.substringBeforeLast('/', missingDelimiterValue = "")
                    ?: ""

                items.add(
                    mapOf(
                        "id" to id.toString(),
                        "uri" to contentUri,
                        "title" to cursor.getString(titleIndex),
                        "displayName" to cursor.getString(displayNameIndex),
                        "artist" to cursor.getString(artistIndex),
                        "album" to cursor.getString(albumIndex),
                        "durationMs" to cursor.getLong(durationIndex),
                        "relativePath" to folderPath,
                        "bucketDisplayName" to if (bucketNameIndex >= 0) cursor.getString(bucketNameIndex) else null,
                        "mimeType" to if (mimeTypeIndex >= 0) cursor.getString(mimeTypeIndex) else null,
                        "dateAddedSeconds" to if (dateAddedIndex >= 0) cursor.getLong(dateAddedIndex) else null,
                    ),
                )
            }
        }

        result.success(items)
    }

    private fun hasAudioPermission(): Boolean {
        val permission = requiredPermissions()
        return permission.all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }
}
