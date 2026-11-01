package com.example.aiyue_music

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingNotificationPermission: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aiyue/folders")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                            result.success(true)
                        } else if (pendingNotificationPermission != null) {
                            result.error("BUSY", "通知权限请求正在进行", null)
                        } else {
                            pendingNotificationPermission = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7022)
                        }
                    }
                    "pick" -> {
                        if (pending != null) {
                            result.error("BUSY", "文件夹选择器已打开", null)
                        } else {
                            pending = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                                }, 7021)
                            } catch (e: Exception) {
                                pending = null
                                result.error("PICK_FAILED", e.message, null)
                            }
                        }
                    }
                    "scan" -> {
                        val value = call.argument<String>("uri")
                        if (value == null) result.error("INVALID_URI", "缺少文件夹 URI", null)
                        else scan(Uri.parse(value), result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 7022) return
        val result = pendingNotificationPermission ?: return
        pendingNotificationPermission = null
        result.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7021) return
        val result = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            scan(uri, result)
        } catch (e: Exception) {
            result.error("PERMISSION", "无法读取所选文件夹，请重新授权：${e.message}", null)
        }
    }

    private fun scan(tree: Uri, result: MethodChannel.Result) {
        worker.execute {
            try {
                val songs = mutableListOf<Map<String, String>>()
                val visited = mutableSetOf<String>()
                val directories = java.util.ArrayDeque<String>()
                directories.add(DocumentsContract.getTreeDocumentId(tree))
                while (directories.isNotEmpty()) {
                    val id = directories.removeFirst()
                    if (!visited.add(id)) continue
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                    val cursor = contentResolver.query(children, arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    ), null, null, null) ?: error("文件提供方无法读取目录")
                    cursor.use {
                        while (it.moveToNext()) {
                            val childId = it.getString(0)
                            val name = it.getString(1) ?: ""
                            val mime = it.getString(2)
                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) directories.add(childId)
                            else if (name.endsWith(".mp3", ignoreCase = true)) {
                                songs.add(mapOf("path" to DocumentsContract.buildDocumentUriUsingTree(tree, childId).toString(), "name" to name))
                            }
                        }
                    }
                }
                songs.sortBy { it["name"]?.lowercase() }
                val document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                var name = "本地音乐"
                contentResolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                runOnUiThread { result.success(mapOf("uri" to tree.toString(), "name" to name, "tracks" to songs)) }
            } catch (e: Exception) {
                runOnUiThread { result.error("SCAN_FAILED", "无法读取文件夹，请重新选择授权：${e.message}", null) }
            }
        }
    }
}
