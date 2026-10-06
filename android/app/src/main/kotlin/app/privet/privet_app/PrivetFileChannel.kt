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
 *   - pickFiles()             -> ACTION_OPEN_DOCUMENT (multi) -> [(path, uri)]
 *   - clearSendCache()        -> drop stale send-cache sessions
 *
 * The pickers' `onActivityResult` are forwarded here by MainActivity.
 */
class PrivetFileChannel(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "privet/file"
        private const val REQUEST_PICK_DIRECTORY = 0x1001
        private const val REQUEST_PICK_FILES = 0x1002
        private val session = AtomicLong(System.currentTimeMillis())
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingFilesResult: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyContentUri" -> copyContentUri(call.argument<String>("uri"), result)
                "openContentUri" -> openContentUri(call.argument<String>("uri"), result)
                "checkContentUri" -> checkContentUri(call.argument<String>("uri"), result)
                "pickDirectory" -> pickDirectory(result)
                "pickFiles" -> pickFiles(result)
                "clearSendCache" -> clearSendCache(result)
                else -> result.notImplemented()
            }
        }
    }

    /// Forwarded from MainActivity.onActivityResult for both pickers.
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQUEST_PICK_DIRECTORY -> onDirectoryResult(resultCode, data)
            REQUEST_PICK_FILES -> onFilesResult(resultCode, data)
            else -> return
        }
    }

    private fun onDirectoryResult(resultCode: Int, data: Intent?) {
        val pr = pendingResult
        pendingResult = null
        val uri = data?.takeIf { resultCode == Activity.RESULT_OK }?.data
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

    /// Multi-select file picker result.
    ///
    /// Every selected URI is kept as the file's identity and returned verbatim
    /// alongside the staging copy the daemon will read. The `data` URI (single
    /// select) and `clipData` (multi select) paths both have to be handled: the
    /// system only fills `clipData` when more than one item was chosen.
    ///
    /// The grant asked for at pick time is persistable, so the URI stays
    /// readable across an app or device restart — which is what lets history
    /// keep reporting the user's real file as reachable. A provider that refuses
    /// the persistable grant is logged and skipped: it degrades that one file to
    /// the old (one-shot grant) behaviour rather than failing the whole pick.
    private fun onFilesResult(resultCode: Int, data: Intent?) {
        val pr = pendingFilesResult
        pendingFilesResult = null
        val uris = selectedUris(resultCode, data)
        if (uris.isEmpty()) {
            pr?.success(emptyList<Map<String, Any?>>()) // user cancelled
            return
        }
        Thread {
            val picked = uris.map { uri ->
                val staged = try {
                    persistReadGrant(uri)
                    stageContentUri(uri)?.absolutePath
                } catch (e: Exception) {
                    // One unreadable file must not cost the user the whole
                    // selection, and it must not take the app down either.
                    Log.w("PrivetSAF", "Could not stage $uri", e)
                    null
                }
                mapOf(
                    // Verbatim, never normalised: this is the handle history
                    // probes with `checkContentUri` after a restart.
                    "uri" to uri.toString(),
                    // Null when the copy failed; index is still the selection's
                    // index, so callers keep the pairing they were promised.
                    "path" to staged
                )
            }
            activity.runOnUiThread { pr?.success(picked) }
        }.start()
    }

    /// Asks for a grant that outlives this process. Providers are allowed to
    /// refuse, so the failure is logged and the pick continues.
    private fun persistReadGrant(uri: Uri) {
        try {
            activity.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: Exception) {
            Log.w(
                "PrivetSAF",
                "Persistable read grant denied for $uri; " +
                    "this file falls back to a one-shot grant", e)
        }
    }

    private fun selectedUris(resultCode: Int, data: Intent?): List<Uri> {
        if (resultCode != Activity.RESULT_OK) return emptyList()
        val intent = data ?: return emptyList()
        val clip = intent.clipData
        if (clip != null) {
            val out = ArrayList<Uri>(clip.itemCount)
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { out.add(it) }
            }
            if (out.isNotEmpty()) return out
        }
        // Single select (and providers that omit clipData) report via `data`.
        return listOfNotNull(intent.data)
    }

    private fun copyContentUri(uri: String?, result: MethodChannel.Result) {
        if (uri == null) {
            result.error("NO_URI", "uri required", null)
            return
        }
        try {
            val staged = stageContentUri(Uri.parse(uri))
                ?: throw IllegalStateException("could not open $uri")
            result.success(staged.absolutePath)
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

    /// Multi-select file picker.
    ///
    /// This replaces `file_picker`'s file path on Android: that plugin launches
    /// the same `ACTION_OPEN_DOCUMENT` intent but without
    /// `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` and never calls
    /// `takePersistableUriPermission`, so the `content://` URI history records is
    /// only readable until the app (or the device) restarts. Asking for a
    /// persistable grant and taking it per URI is what makes that reference
    /// outlive the process.
    private fun pickFiles(result: MethodChannel.Result) {
        pendingFilesResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        activity.startActivityForResult(intent, REQUEST_PICK_FILES)
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

    /// Copies a `content://` document into a fresh send-cache session file.
    /// Returns null when the provider cannot be opened or read, so callers can
    /// tell "staged" from "not staged" instead of handing back a path to a file
    /// that was never written.
    private fun stageContentUri(uri: Uri): File? {
        val name = fileName(uri.toString()) ?: "file_${System.currentTimeMillis()}"
        val out = newSessionFile(name)
        activity.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(out).use { o -> input.copyTo(o) }
        } ?: return null
        return out
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
