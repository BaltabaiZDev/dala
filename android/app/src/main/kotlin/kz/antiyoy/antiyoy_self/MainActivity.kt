package kz.antiyoy.antiyoy_self

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract as Docs
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val contentWorker = Executors.newSingleThreadExecutor()
    private var pendingFolder: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dala/content_folders").setMethodCallHandler { call, result ->
            if (call.method == "choose") {
                if (pendingFolder != null) { result.error("busy", "Folder picker is already open", null); return@setMethodCallHandler }
                pendingFolder = result
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                }, 4821)
                return@setMethodCallHandler
            }
            if (call.method !in listOf("read", "write", "remove")) { result.notImplemented(); return@setMethodCallHandler }
            contentWorker.execute {
                try {
                    val tree = Uri.parse(requireNotNull(call.argument<String>("tree")))
                    val root = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
                    val buckets = listOf("mods", "maps").associateWith { name ->
                        children(tree, root).firstOrNull { it.name == name && it.directory }?.uri
                            ?: requireNotNull(Docs.createDocument(contentResolver, root, Docs.Document.MIME_TYPE_DIR, name))
                    }
                    val value: Any? = when (call.method) {
                        "read" -> {
                            val files = HashMap<String, ByteArray>()
                            for ((bucket, parent) in buckets) {
                                for (file in children(tree, parent)) {
                                    if (file.directory || !file.name.endsWith(if (bucket == "mods") ".dalamod" else ".dalamap", true)) continue
                                    require(files.size < 100) { "Too many content packages" }
                                    files["$bucket/${file.name}"] = if (file.size > 16 * 1024 * 1024) ByteArray(0) else
                                        contentResolver.openInputStream(file.uri)!!.use { input ->
                                            val output = java.io.ByteArrayOutputStream()
                                            val buffer = ByteArray(8192)
                                            while (true) {
                                                val n = input.read(buffer)
                                                if (n < 0) break
                                                require(output.size() + n <= 16 * 1024 * 1024) { "Content package too large" }
                                                output.write(buffer, 0, n)
                                            }
                                            output.toByteArray()
                                        }
                                }
                            }
                            files
                        }
                        else -> {
                            val path = requireNotNull(call.argument<String>("path")).split('/')
                            require(path.size == 2 && path[0] in buckets && path[1].isNotEmpty() && path[1] != ".." && !path[1].contains('\\'))
                            val parent = buckets.getValue(path[0])
                            val existing = children(tree, parent).firstOrNull { it.name == path[1] && !it.directory }
                            if (call.method == "remove") {
                                if (existing != null) require(Docs.deleteDocument(contentResolver, existing.uri))
                            } else if (existing == null) {
                                val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
                                require(bytes.size <= 16 * 1024 * 1024)
                                val file = requireNotNull(Docs.createDocument(contentResolver, parent, "application/octet-stream", path[1]))
                                try { contentResolver.openOutputStream(file, "wt")!!.use { it.write(bytes) } }
                                catch (e: Exception) { Docs.deleteDocument(contentResolver, file); throw e }
                            }
                            null
                        }
                    }
                    runOnUiThread { result.success(value) }
                } catch (e: Exception) { runOnUiThread { result.error("content_folder", e.message, null) } }
            }
        }
    }

    private data class Entry(val name: String, val uri: Uri, val directory: Boolean, val size: Long)
    private fun children(tree: Uri, parent: Uri): List<Entry> {
        val uri = Docs.buildChildDocumentsUriUsingTree(tree, Docs.getDocumentId(parent))
        val columns = arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE)
        val entries = ArrayList<Entry>()
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                entries.add(Entry(cursor.getString(1), Docs.buildDocumentUriUsingTree(tree, cursor.getString(0)), cursor.getString(2) == Docs.Document.MIME_TYPE_DIR, cursor.getLong(3)))
            }
        }
        return entries
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4821) return
        val pending = pendingFolder ?: return
        pendingFolder = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { pending.success(null); return }
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            pending.success(uri.toString())
        } catch (e: Exception) { pending.error("content_folder", e.message, null) }
    }

    override fun onDestroy() {
        pendingFolder?.success(null)
        pendingFolder = null
        contentWorker.shutdown()
        super.onDestroy()
    }
}
