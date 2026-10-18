package io.github.ukpratik.kickfile

import android.app.Activity
import android.app.DownloadManager
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Android file access for kickFile (ADR-005): system pickers without cache copies,
 * chunked reads of content URIs, MediaStore pending items for received files,
 * share-sheet intents and the transfer foreground service.
 */
class KfFiles(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "kickfile/files")
    private val events = EventChannel(messenger, "kickfile/intents")
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val cr: ContentResolver get() = activity.contentResolver

    private val readers = ConcurrentHashMap<Int, InputStream>()
    private val writers = ConcurrentHashMap<Int, Writer>()
    private val ids = AtomicInteger(1)

    private var pending: MethodChannel.Result? = null
    private var pendingKind = ""
    private var sink: EventChannel.EventSink? = null
    private val queued = mutableListOf<Map<String, Any?>>()

    private class Writer(val pfd: ParcelFileDescriptor?, val out: FileOutputStream)

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                queued.forEach { events.success(it) }
                queued.clear()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        readers.values.forEach { runCatching { it.close() } }
        writers.values.forEach { runCatching { it.out.close(); it.pfd?.close() } }
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceName" -> result.success(
                Settings.Global.getString(cr, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL,
            )
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "pickMedia" -> pick(result, "media")
            "pickFiles" -> pick(result, "files")
            "pickFolder" -> pick(result, "folder")
            else -> io.execute { runIo(call, result) }
        }
    }

    // ---------------- pickers ----------------

    private fun pick(result: MethodChannel.Result, kind: String) {
        if (pending != null) {
            result.error("busy", "picker open", null)
            return
        }
        val intent = when (kind) {
            "media" -> ActivityResultContracts.PickMultipleVisualMedia().createIntent(
                activity,
                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
            )
            "folder" -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            else -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
        pending = result
        pendingKind = kind
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pending = null
            result.error("no_picker", e.message, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pending ?: return true
        val kind = pendingKind
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Any>())
            return true
        }
        io.execute {
            try {
                val list: List<Map<String, Any?>> = when (kind) {
                    "folder" -> data.data?.let { walkTree(it) } ?: emptyList()
                    "media" -> ActivityResultContracts.PickMultipleVisualMedia().parseResult(resultCode, data).mapNotNull { describe(it, null) }
                    else -> urisOf(data).mapNotNull { describe(it, null) }
                }
                main.post { result.success(list) }
            } catch (e: Exception) {
                main.post { result.error("pick_failed", e.message, null) }
            }
        }
        return true
    }

    private fun urisOf(data: Intent): List<Uri> {
        val out = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { out.add(it) }
        data.data?.let { if (!out.contains(it)) out.add(it) }
        return out
    }

    /** name, size, mtime, mime for a content URI. Null if it can't be read. */
    private fun describe(uri: Uri, relPath: String?): Map<String, Any?>? {
        var name: String? = null
        var size = -1L
        var mtime = 0L
        try {
            cr.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = c.getString(it) }
                    c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { size = c.getLong(it) }
                    c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED).takeIf { it >= 0 && !c.isNull(it) }
                        ?.let { mtime = c.getLong(it) }
                    if (mtime == 0L) {
                        c.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED).takeIf { it >= 0 && !c.isNull(it) }
                            ?.let { mtime = c.getLong(it) * 1000 }
                    }
                }
            }
        } catch (_: Exception) {
        }
        if (size < 0) size = statSize(uri) ?: return null
        val n = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        return mapOf(
            "kind" to "file",
            "uri" to uri.toString(),
            "relPath" to (relPath ?: n),
            "size" to size,
            "mtime" to mtime,
            "mime" to cr.getType(uri),
        )
    }

    private fun statSize(uri: Uri): Long? = try {
        cr.openFileDescriptor(uri, "r")?.use { it.statSize.takeIf { s -> s >= 0 } }
    } catch (_: Exception) {
        null
    }

    /** A picked folder: every file and folder under it, paths starting with the folder's own name. */
    private fun walkTree(tree: Uri): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootName = queryName(DocumentsContract.buildDocumentUriUsingTree(tree, rootId)) ?: "Folder"
        out.add(mapOf("kind" to "dir", "relPath" to rootName))
        val stack = ArrayDeque<Pair<String, String>>()
        stack.add(rootId to rootName)
        while (stack.isNotEmpty() && out.size <= MAX_ITEMS) {
            val (docId, path) = stack.removeLast()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            cr.query(
                children,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                ),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2)
                    val rel = "$path/$name"
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        out.add(mapOf("kind" to "dir", "relPath" to rel))
                        stack.add(id to rel)
                    } else {
                        out.add(
                            mapOf(
                                "kind" to "file",
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                                "relPath" to rel,
                                "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
                                "mtime" to (if (c.isNull(4)) 0L else c.getLong(4)),
                                "mime" to mime,
                            ),
                        )
                    }
                }
            }
        }
        return out
    }

    private fun queryName(uri: Uri): String? = try {
        cr.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    } catch (_: Exception) {
        null
    }

    // ---------------- I/O (background thread) ----------------

    private fun runIo(call: MethodCall, result: MethodChannel.Result) {
        fun ok(v: Any?) {
            main.post { result.success(v) }
        }
        fun err(code: String, msg: String?) {
            main.post { result.error(code, msg, null) }
        }
        try {
            when (call.method) {
                "stat" -> {
                    val uri = Uri.parse(call.argument<String>("ref"))
                    ok(describe(uri, null)?.let { mapOf("size" to it["size"], "mtime" to it["mtime"]) })
                }
                "openRead" -> {
                    val ref = call.argument<String>("ref")!!
                    val offset = (call.argument<Number>("offset") ?: 0).toLong()
                    val input = openInput(ref) ?: return err("not_found", ref)
                    var left = offset
                    val scratch = ByteArray(64 * 1024)
                    while (left > 0) {
                        val skipped = input.skip(left)
                        if (skipped > 0) {
                            left -= skipped
                            continue
                        }
                        val n = input.read(scratch, 0, minOf(scratch.size.toLong(), left).toInt())
                        if (n < 0) break
                        left -= n
                    }
                    val id = ids.getAndIncrement()
                    readers[id] = input
                    ok(id)
                }
                "read" -> {
                    val input = readers[call.argument<Int>("handle")!!] ?: return err("closed", null)
                    val max = call.argument<Int>("max") ?: CHUNK
                    val buf = ByteArray(max)
                    var filled = 0
                    while (filled < max) {
                        val n = input.read(buf, filled, max - filled)
                        if (n < 0) break
                        filled += n
                    }
                    ok(if (filled == 0) null else if (filled == max) buf else buf.copyOf(filled))
                }
                "closeRead" -> {
                    readers.remove(call.argument<Int>("handle")!!)?.close()
                    ok(null)
                }
                "createTarget" -> ok(createTarget(call.argument("relPath")!!, call.argument("mime")))
                "partialLength" -> ok(partialLength(call.argument("ref")!!))
                "openWrite" -> {
                    val ref = call.argument<String>("ref")!!
                    val offset = (call.argument<Number>("offset") ?: 0).toLong()
                    val w = if (ref.startsWith("content://")) {
                        val pfd = cr.openFileDescriptor(Uri.parse(ref), "rw") ?: return err("not_found", null)
                        Writer(pfd, FileOutputStream(pfd.fileDescriptor))
                    } else {
                        Writer(null, FileOutputStream(File(ref), true))
                    }
                    w.out.channel.truncate(offset)
                    w.out.channel.position(offset)
                    val id = ids.getAndIncrement()
                    writers[id] = w
                    ok(id)
                }
                "write" -> {
                    val w = writers[call.argument<Int>("handle")!!] ?: return err("closed", null)
                    w.out.write(call.argument<ByteArray>("bytes")!!)
                    ok(null)
                }
                "closeWrite" -> {
                    writers.remove(call.argument<Int>("handle")!!)?.let {
                        it.out.flush()
                        runCatching { it.out.fd.sync() }
                        it.out.close()
                        it.pfd?.close()
                    }
                    ok(null)
                }
                "finalize" -> ok(finalizeTarget(call.argument("ref")!!))
                "discard" -> {
                    val ref = call.argument<String>("ref")!!
                    if (ref.startsWith("content://")) runCatching { cr.delete(Uri.parse(ref), null, null) } else File(ref).delete()
                    ok(null)
                }
                "freeBytes" -> ok(StatFs(Environment.getExternalStorageDirectory().path).availableBytes)
                "open" -> {
                    val uri = Uri.parse(call.argument<String>("ref")!!)
                    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, cr.getType(uri) ?: "*/*")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    main.post {
                        try {
                            activity.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                }
                "reveal" -> main.post {
                    try {
                        activity.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "fgStart", "fgUpdate" -> main.post {
                    TransferService.update(activity, call.argument("title") ?: "kickFile", call.argument("text") ?: "", call.argument("progress") ?: -1)
                    result.success(null)
                }
                "fgStop" -> main.post {
                    TransferService.stop(activity)
                    result.success(null)
                }
                else -> main.post { result.notImplemented() }
            }
        } catch (e: IOException) {
            val msg = e.message ?: ""
            err(if (msg.contains("ENOSPC") || msg.contains("No space")) "no_space" else "io", msg)
        } catch (e: Exception) {
            err("io", e.message)
        }
    }

    private fun openInput(ref: String): InputStream? = if (ref.startsWith("content://")) {
        cr.openInputStream(Uri.parse(ref))
    } else {
        File(ref).takeIf { it.exists() }?.inputStream()
    }

    private fun partialLength(ref: String): Long = if (ref.startsWith("content://")) {
        statSize(Uri.parse(ref)) ?: 0L
    } else {
        File(ref).length()
    }

    /**
     * Where a received file goes (US-007): photos → Pictures/kickFile, videos → Movies/kickFile,
     * everything else → Download/kickFile, keeping sub-folders. API 29+: a MediaStore pending item
     * (the final name is resolved by MediaStore, collisions included). API 26–28: a `.kfpart` file.
     */
    private fun createTarget(relPath: String, mimeArg: String?): String {
        val segs = relPath.split('/')
        val name = segs.last()
        val sub = segs.dropLast(1).joinToString("/")
        val mime = mimeArg ?: android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val (collection, base) = when {
                mime.startsWith("image/") -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_PICTURES
                mime.startsWith("video/") -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_MOVIES
                else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_DOWNLOADS
            }
            fun insert(col: Uri, root: String, type: String): Uri? = cr.insert(col, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, type)
                put(MediaStore.MediaColumns.RELATIVE_PATH, listOf(root, "kickFile", sub).filter { it.isNotEmpty() }.joinToString("/"))
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            })
            val uri = (runCatching { insert(collection, base, mime) }.getOrNull()
                ?: insert(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), Environment.DIRECTORY_DOWNLOADS, mime))
                ?: throw IOException("insert failed")
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "kickFile/$sub")
        dir.mkdirs()
        val part = File(dir, ".$name.${System.nanoTime()}.kfpart")
        part.createNewFile()
        return part.absolutePath
    }

    /** Publishes a finished file. Returns a content URI the UI can open later. */
    private fun finalizeTarget(ref: String): String {
        if (ref.startsWith("content://")) {
            val uri = Uri.parse(ref)
            cr.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            return ref
        }
        val part = File(ref)
        val name = part.name.removePrefix(".").substringBeforeLast(".kfpart").substringBeforeLast('.')
        var dest = File(part.parentFile, name)
        var n = 1
        while (dest.exists()) {
            val dot = name.lastIndexOf('.')
            dest = File(part.parentFile, if (dot > 0) "${name.substring(0, dot)} ($n)${name.substring(dot)}" else "$name ($n)")
            n++
        }
        if (!part.renameTo(dest)) throw IOException("rename failed")
        var scanned: Uri? = null
        val latch = CountDownLatch(1)
        MediaScannerConnection.scanFile(activity, arrayOf(dest.absolutePath), null) { _, uri ->
            scanned = uri
            latch.countDown()
        }
        latch.await(5, TimeUnit.SECONDS)
        return scanned?.toString() ?: dest.absolutePath
    }

    // ---------------- share sheet and links (US-009, US-003) ----------------

    fun handleIntent(intent: Intent?) {
        intent ?: return
        val event: Map<String, Any?>? = when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (stream != null) {
                    mapOf("type" to "share", "uris" to listOf(stream.toString()))
                } else {
                    intent.getStringExtra(Intent.EXTRA_TEXT)?.let { mapOf("type" to "text", "text" to it) }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val list = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                list?.let { mapOf("type" to "share", "uris" to it.map(Uri::toString)) }
            }
            Intent.ACTION_VIEW -> intent.data?.takeIf { it.scheme == "kickfile" }?.let { mapOf("type" to "link", "uri" to it.toString()) }
            else -> null
        }
        event ?: return
        // Consume it so a config change doesn't deliver it twice.
        intent.action = null
        if (event["type"] == "share") {
            io.execute {
                val uris = event["uris"] as List<*>
                val items = uris.mapNotNull { describe(Uri.parse(it as String), null) }
                main.post {
                    emit(
                        if (items.isEmpty() && uris.isNotEmpty()) mapOf("type" to "share_failed")
                        else mapOf("type" to "share", "items" to items, "skipped" to uris.size - items.size),
                    )
                }
            }
        } else {
            emit(event)
        }
    }

    private fun emit(e: Map<String, Any?>) {
        val s = sink
        if (s != null) s.success(e) else queued.add(e)
    }

    companion object {
        private const val REQUEST_PICK = 4742
        private const val CHUNK = 1 shl 20
        private const val MAX_ITEMS = 10000
    }
}
