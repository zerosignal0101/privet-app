package app.privet.privet_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * SAF file operations for the daemon flow.
 *
 * The daemon only reads real filesystem paths, so any `content://` URI must be
 * copied to the send-cache first. Exposes:
 *   - copyContentUri(uri)     -> cached real path
 *   - openContentUri(uri)     -> launch system viewer
 *   - checkContentUri(uri)    -> permission still held?
 *   - pickDirectory()         -> ACTION_OPEN_DOCUMENT_TREE -> cached root path
 *   - clearSendCache()        -> drop stale send-cache sessions
 *
 * The directory picker's `onActivityResult` is forwarded here by MainActivity.
 */
class PrivetFileChannel(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "privet/file"
        private const val REQUEST_PICK_DIRECTORY = 0x1001
        private val session = AtomicLong(System.currentTimeMillis())
    }

    private var pendingResult: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyContentUri" -> copyContentUri(call.argument<String>("uri"), result)
                "openContentUri" -> openContentUri(call.argument<String>("uri"), result)
                "checkContentUri" -> checkContentUri(call.argument<String>("uri"), result)
                "pickDirectory" -> pickDirectory(result)
                "clearSendCache" -> clearSendCache(result)
                else -> result.notImplemented()
            }
        }
    }

    /// Forwarded from MainActivity.onActivityResult for the directory picker.
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_DIRECTORY) return
        val pr = pendingResult
        pendingResult = null
        val uri = data?.data
        if (uri == null) {
            pr?.success(null) // user cancelled
            return
        }
        // Copy on a background thread to avoid an ANR; deliver the result on the
        // main thread (MethodChannel requirement).
        Thread {
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                val root = copyDirToCache(uri)
                activity.runOnUiThread { pr?.success(root) }
            } catch (e: Exception) {
                Log.e("PrivetSAF", "pickDirectory error", e)
                activity.runOnUiThread { pr?.error("SAF_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun copyContentUri(uri: String?, result: MethodChannel.Result) {
        if (uri == null) {
            result.error("NO_URI", "uri required", null)
            return
        }
        try {
            val name = fileName(uri) ?: "file_${System.currentTimeMillis()}"
            val out = newSessionFile(name)
            activity.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
                FileOutputStream(out).use { o -> input.copyTo(o) }
            }
            result.success(out.absolutePath)
        } catch (e: Exception) {
            Log.e("PrivetSAF", "copyContentUri failed", e)
            result.error("COPY_ERROR", e.message, null)
        }
    }

    private fun openContentUri(uri: String?, result: MethodChannel.Result) {
        if (uri == null) {
            result.success(false)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(uri), activity.contentResolver.getType(Uri.parse(uri)))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            Log.e("PrivetSAF", "openContentUri failed", e)
            result.success(false)
        }
    }

    private fun checkContentUri(uri: String?, result: MethodChannel.Result) {
        if (uri == null) {
            result.success(false)
            return
        }
        try {
            val fd = activity.contentResolver.openFileDescriptor(Uri.parse(uri), "r")
            fd?.use { result.success(true) } ?: result.success(false)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        activity.startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
    }

    private fun clearSendCache(result: MethodChannel.Result) {
        try {
            val root = File(activity.cacheDir, "privet/send-cache")
            root.listFiles()?.forEach { it.deleteRecursively() }
            result.success(null)
        } catch (e: Exception) {
            Log.e("PrivetSAF", "clearSendCache failed", e)
            result.error("IO_ERROR", e.message, null)
        }
    }

    /// Enumerate a SAF tree URI and copy all files to a fresh session dir,
    /// preserving relative paths. Returns the top-level folder path to send.
    private fun copyDirToCache(treeUri: Uri): String {
        val sessionDir = File(activity.cacheDir, "privet/send-cache/${session.incrementAndGet()}")
        sessionDir.mkdirs()
        val rootDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val folderName = Uri.decode(rootDocId.substringAfter(':').substringAfterLast('/'))
            .ifEmpty { "folder" }
        val rootOut = File(sessionDir, folderName)
        rootOut.mkdirs()

        val stack = ArrayDeque<Triple<String, String, File>>()
        stack.addLast(Triple(treeUri.toString(), rootDocId, rootOut))
        val visited = mutableSetOf<String>()

        while (stack.isNotEmpty()) {
            val (currentTree, currentDocId, outDir) = stack.removeLast()
            val key = "$currentTree|$currentDocId"
            if (key in visited) continue
            visited.add(key)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                Uri.parse(currentTree), currentDocId
            )
            val cursor = activity.contentResolver.query(childrenUri, null, null, null, null)
            cursor?.use { c ->
                val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val docIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                while (c.moveToNext()) {
                    val mime = if (mimeIdx >= 0) c.getString(mimeIdx) else null
                    val docId = if (docIdx >= 0) c.getString(docIdx) else null
                    val name = (if (nameIdx >= 0) c.getString(nameIdx) else null)
                        ?: docId ?: "unknown"
                    if (DocumentsContract.Document.MIME_TYPE_DIR == mime) {
                        stack.addLast(Triple(currentTree, docId ?: "unknown", File(outDir, name)))
                    } else {
                        val fileUri = DocumentsContract.buildDocumentUriUsingTree(
                            Uri.parse(currentTree), docId
                        )
                        val outFile = File(outDir, name)
                        outFile.parentFile?.mkdirs()
                        try {
                            activity.contentResolver.openInputStream(fileUri)?.use { input ->
                                FileOutputStream(outFile).use { o -> input.copyTo(o) }
                            }
                        } catch (e: Exception) {
                            Log.w("PrivetSAF", "Failed to copy $name: ${e.message}")
                        }
                    }
                }
            }
        }
        return rootOut.absolutePath
    }

    private fun newSessionFile(name: String): File {
        val dir = File(activity.cacheDir, "privet/send-cache/${session.incrementAndGet()}")
        dir.mkdirs()
        return File(dir, name)
    }

    private fun fileName(uri: String): String? {
        return try {
            val cursor = activity.contentResolver.query(Uri.parse(uri), null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val idx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return it.getString(idx)
                }
            }
            Uri.parse(uri).lastPathSegment
        } catch (_: Exception) {
            Uri.parse(uri).lastPathSegment
        }
    }
}
