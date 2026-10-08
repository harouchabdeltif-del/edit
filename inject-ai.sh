#!/usr/bin/env bash
# inject-ai.sh — يحقن وكيل الذكاء الاصطناعي (Agent) مباشرة داخل تطبيق AndroidIDE الرئيسي
# الاستخدام:   bash inject-ai.sh /path/to/AndroidIDE
# مع pkg جديد: bash inject-ai.sh /path/to/AndroidIDE inject com.mycompany.androidide.ai
# للتراجع:     bash inject-ai.sh /path/to/AndroidIDE undo
set -euo pipefail

ROOT="${1:-.}"
ACTION="${2:-inject}"
NEW_APPID="${3:-}"   # اختياري: applicationId جديد باش ما يتضاربش مع التطبيق الأصلي

# --- كشف تلقائي لموديول التطبيق ---
# AndroidIDE الرسمي: الموديول فـ core/app  (settings.gradle.kts → ":core:app")
APP=""
for c in "$ROOT/app" "$ROOT/core/app"; do
  if [ -d "$c/src/main" ]; then APP="$c"; break; fi
done
if [ -z "$APP" ] && [ -d "$ROOT" ]; then
  cands="$(find "$ROOT" -maxdepth 6 -path '*/src/main/AndroidManifest.xml' -not -path '*/build/*' 2>/dev/null \
           | xargs -r grep -l '<application' 2>/dev/null || true)"
  mf="$(printf '%s\n' "$cands" | grep '/app/src/main/' | head -1 || true)"
  [ -n "$mf" ] || mf="$(printf '%s\n' "$cands" | head -1 || true)"
  [ -n "$mf" ] && APP="${mf%/src/main/AndroidManifest.xml}"
fi

if [ -z "$APP" ] || [ ! -d "$APP/src/main" ]; then
  echo "❌ ما لقيتش موديول التطبيق فـ: $ROOT"
  echo "--- pwd: $(pwd)"
  echo "--- محتوى $ROOT:"; ls -la "$ROOT" 2>&1 | head -30 || true
  echo "--- كل المجلدات src/main (عمق 4):"
  find "${ROOT}" -maxdepth 4 -type d -path '*src/main' 2>/dev/null | head -10 || true
  exit 1
fi
echo "📁 موديول التطبيق: $APP"
export APP_DIR="$APP"
PKG_DIR="$APP/src/main/java/com/itsaky/androidide/ai"

# ---------------------------------------------------------------- undo
if [ "$ACTION" = "undo" ]; then
  rm -rf "$PKG_DIR"
  rm -f "$APP"/src/main/res/drawable/ic_ai_*.xml "$APP/src/main/res/raw/ai_keep.xml"
  find "$APP" -name '*.ai-bak' -not -path '*/build/*' | while read -r b; do
    mv -f "$b" "${b%.ai-bak}"; echo "↩️  رجّعت ${b%.ai-bak}"
  done
  echo "✅ تم التراجع"; exit 0
fi

mkdir -p "$PKG_DIR"

# ---------------------------------------------------------------- AiPrefs.kt
cat > "$PKG_DIR/AiPrefs.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.content.Context

class AiPrefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("ai_assistant", Context.MODE_PRIVATE)

    var provider: String
        get() = sp.getString("provider", "openrouter") ?: "openrouter"
        set(v) { sp.edit().putString("provider", v).apply() }

    var model: String
        get() = sp.getString("model", "") ?: ""
        set(v) { sp.edit().putString("model", v).apply() }

    var apiKey: String
        get() = sp.getString("api_key", "") ?: ""
        set(v) { sp.edit().putString("api_key", v).apply() }

    var baseUrl: String
        get() = sp.getString("base_url", "") ?: ""
        set(v) { sp.edit().putString("base_url", v).apply() }

    /** auto | light | dark */
    var theme: String
        get() = sp.getString("theme", "auto") ?: "auto"
        set(v) { sp.edit().putString("theme", v).apply() }

    /** سجل المحادثة (JSON) باش يبقى حتى بعد إغلاق التطبيق. */
    var history: String
        get() = sp.getString("history", "") ?: ""
        set(v) { sp.edit().putString("history", v).apply() }

    /** true = يطلب تأكيدا قبل كل كتابة/تعديل. الحذف دائما يطلب تأكيدا. */
    var askBeforeEdit: Boolean
        get() = sp.getBoolean("ask_before_edit", false)
        set(v) { sp.edit().putBoolean("ask_before_edit", v).apply() }

    fun effectiveModel(): String = model.ifBlank {
        when (provider) {
            "claude" -> "claude-sonnet-5-5"
            "openai" -> "gpt-4o-mini"
            "gemini" -> "gemini-2.5-pro"
            "openrouter" -> "openrouter/auto"
            else -> ""
        }
    }

    companion object {
        val PROVIDERS = listOf("openrouter", "openai", "claude", "gemini", "custom")
        val THEMES = listOf("auto", "light", "dark")
    }
}
KT_EOF

# ---------------------------------------------------------------- AiClient.kt
cat > "$PKG_DIR/AiClient.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** عميل HTTP بسيط بلا أي مكتبة خارجية. يدعم: OpenRouter / OpenAI / Claude / Gemini / أي API متوافق مع OpenAI. */
object AiClient {

    data class Msg(val role: String, val content: String) // role = "user" | "assistant"

    class ApiException(val code: Int, message: String) : RuntimeException(message)

    /** كيعاود الطلب حتى 3 مرات فحالة 429 أو أخطاء السيرفر (5xx). */
    private const val NO_NATIVE =
        "\n\nIMPORTANT: Do NOT use native function/tool calling of the API (no browser, no functions, no python). " +
        "Tools exist ONLY as plain-text <tool .../> tags written inside your normal reply."

    fun complete(p: AiPrefs, system: String, msgs: List<Msg>): String {
        require(p.apiKey.isNotBlank()) { "ضع مفتاح API من الإعدادات" }
        var last: ApiException? = null
        var sys = system
        for (attempt in 0 until 3) {
            try {
                return when (p.provider) {
                    "claude" -> claude(p, sys, msgs)
                    "gemini" -> gemini(p, sys, msgs)
                    else -> openAiCompatible(p, sys, msgs)
                }
            } catch (e: ApiException) {
                // بعض النماذج (مثل gpt-oss) تحاول استدعاء أداة أصلية فيرفضها المزوّد: نعيد الطلب بتذكير صريح
                val nativeTool = e.code == 400 && (e.message ?: "").contains("tool", ignoreCase = true)
                if (!nativeTool && e.code != 429 && e.code < 500) throw e
                if (nativeTool) sys = system + NO_NATIVE
                last = e
                if (attempt < 2) Thread.sleep(if (nativeTool) 400L else 1500L * (attempt + 1))
            }
        }
        throw last ?: IllegalStateException("فشل الطلب")
    }

    /** اختبار سريع للاتصال والمفتاح. */
    fun ping(p: AiPrefs): String =
        complete(p, "Reply with the single word OK.", listOf(Msg("user", "ping"))).trim().take(40)

    private fun openAiCompatible(p: AiPrefs, system: String, msgs: List<Msg>): String {
        val base = p.baseUrl.ifBlank {
            when (p.provider) {
                "openai" -> "https://api.openai.com/v1"
                "openrouter" -> "https://openrouter.ai/api/v1"
                else -> throw IllegalStateException("provider custom خاصو Base URL")
            }
        }.trimEnd('/')
        val arr = JSONArray()
        arr.put(JSONObject().put("role", "system").put("content", system))
        msgs.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
        val body = JSONObject().put("model", p.effectiveModel()).put("messages", arr)
        val res = JSONObject(post("$base/chat/completions", mapOf("Authorization" to "Bearer ${p.apiKey}"), body))
        res.optJSONObject("error")?.let { throw RuntimeException(it.optString("message", "API error")) }
        return res.getJSONArray("choices").getJSONObject(0).getJSONObject("message").optString("content")
    }

    private fun claude(p: AiPrefs, system: String, msgs: List<Msg>): String {
        val base = p.baseUrl.ifBlank { "https://api.anthropic.com" }.trimEnd('/')
        val arr = JSONArray()
        msgs.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
        val body = JSONObject()
            .put("model", p.effectiveModel())
            .put("max_tokens", 12000)
            .put("system", system)
            .put("messages", arr)
        val res = JSONObject(
            post("$base/v1/messages", mapOf("x-api-key" to p.apiKey, "anthropic-version" to "2023-06-01"), body)
        )
        val blocks = res.getJSONArray("content")
        return buildString {
            for (i in 0 until blocks.length()) {
                val b = blocks.getJSONObject(i)
                if (b.optString("type") == "text") append(b.optString("text"))
            }
        }
    }

    private fun gemini(p: AiPrefs, system: String, msgs: List<Msg>): String {
        val base = p.baseUrl.ifBlank { "https://generativelanguage.googleapis.com" }.trimEnd('/')
        val contents = JSONArray()
        msgs.forEach {
            contents.put(
                JSONObject()
                    .put("role", if (it.role == "assistant") "model" else "user")
                    .put("parts", JSONArray().put(JSONObject().put("text", it.content)))
            )
        }
        val body = JSONObject()
            .put("contents", contents)
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
        val res = JSONObject(
            post("$base/v1beta/models/${p.effectiveModel()}:generateContent", mapOf("x-goog-api-key" to p.apiKey), body)
        )
        val parts = res.getJSONArray("candidates").getJSONObject(0).getJSONObject("content").getJSONArray("parts")
        return buildString { for (i in 0 until parts.length()) append(parts.getJSONObject(i).optString("text")) }
    }

    /** يستخرج رسالة الخطأ الحقيقية من رد الـ API بدل ما نعرض JSON خام. */
    private fun errorMessage(raw: String): String {
        val parsed = try {
            val e = JSONObject(raw).opt("error")
            when (e) {
                is JSONObject -> e.optString("message")
                is String -> e
                else -> ""
            }
        } catch (t: Throwable) { "" }
        return parsed.ifBlank { raw.take(300) }
    }

    private fun post(url: String, headers: Map<String, String>, body: JSONObject): String {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 20_000
            c.readTimeout = 300_000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
            c.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = c.responseCode
            val stream = if (code in 200..299) c.inputStream else c.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (code !in 200..299) throw ApiException(code, "HTTP $code: ${errorMessage(text)}")
            return text
        } finally {
            c.disconnect()
        }
    }
}
KT_EOF

# ---------------------------------------------------------------- EditorAccess.kt
cat > "$PKG_DIR/EditorAccess.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import java.io.File

/**
 * وصول للمحرر (Sora CodeEditor / IDEEditor) عبر reflection،
 * باش الكود يبقى خدّام حتى لو تبدلات أسماء الحقول فـ EditorActivity.
 */
class EditorAccess private constructor(private val v: View) {

    private fun invoke(t: Any, name: String, vararg args: Any?): Any? {
        val m = t.javaClass.methods.firstOrNull { it.name == name && it.parameterTypes.size == args.size }
            ?: throw NoSuchMethodException("${t.javaClass.name}.$name/${args.size}")
        return m.invoke(t, *args)
    }

    private fun call(t: Any?, name: String, vararg args: Any?): Any? =
        if (t == null) null else try { invoke(t, name, *args) } catch (e: Throwable) { null }

    private fun i(o: Any?): Int = (o as? Number)?.toInt() ?: 0

    private val text: Any? get() = call(v, "getText")
    private val cursor: Any? get() = call(v, "getCursor")

    fun allText(): String = text?.toString().orEmpty()

    fun file(): File? = call(v, "getFile") as? File

    fun selection(): String? {
        val c = cursor ?: return null
        if (call(c, "isSelected") != true) return null
        val s = allText()
        val l = i(call(c, "getLeft"))
        val r = i(call(c, "getRight"))
        return if (l in 0 until r && r <= s.length) s.substring(l, r) else null
    }

    /** يدرج الكود فموضع المؤشر (أو يستبدل التحديد). */
    fun replaceSelection(code: String) {
        val c = cursor ?: throw IllegalStateException("ما لقيتش المؤشر")
        val t = text ?: throw IllegalStateException("ما لقيتش النص")
        invoke(
            t, "replace",
            i(call(c, "getLeftLine")), i(call(c, "getLeftColumn")),
            i(call(c, "getRightLine")), i(call(c, "getRightColumn")),
            code
        )
    }

    /** يستبدل محتوى الملف كامل (كيمكن التراجع بـ undo ديال المحرر). */
    fun replaceAll(code: String) {
        val t = text ?: throw IllegalStateException("ما لقيتش النص")
        val last = i(invoke(t, "getLineCount")) - 1
        val col = i(invoke(t, "getColumnCount", last))
        invoke(t, "replace", 0, 0, last, col, code)
    }

    companion object {
        fun find(a: Activity): EditorAccess? {
            val root = a.window?.decorView ?: return null
            var found: View? = null
            fun walk(x: View) {
                if (found != null) return
                if (isEditor(x) && x.isShown) { found = x; return }
                if (x is ViewGroup) for (k in 0 until x.childCount) walk(x.getChildAt(k))
            }
            walk(root)
            return found?.let { EditorAccess(it) }
        }

        private fun isEditor(x: View): Boolean {
            var c: Class<*>? = x.javaClass
            while (c != null) {
                if (c.name == "io.github.rosemoe.sora.widget.CodeEditor") return true
                c = c.superclass
            }
            return false
        }
    }
}
KT_EOF

# ---------------------------------------------------------------- AiAgent.kt
cat > "$PKG_DIR/AiAgent.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.app.Activity
import android.app.AlertDialog
import android.os.Environment
import android.os.Looper
import java.io.File
import java.util.concurrent.CountDownLatch

/**
 * منفّذ الأدوات: النموذج يرسل وسوم <tool .../> والوكيل ينفّذها (قراءة/كتابة/تعديل/إنشاء/حذف/نقل/بحث)
 * داخل مجلد العمل فقط، مع إمكانية التراجع عن آخر تنفيذ.
 */
object AiAgent {

    data class Call(val name: String, val attrs: Map<String, String>, val body: String) {
        val path: String get() = attrs["path"].orEmpty()
    }

    data class StepResult(val call: Call, val ok: Boolean, val text: String)

    class Denied : RuntimeException()

    class Run { val undo = mutableListOf<Pair<File, String?>>() }

    /** مجلد العمل: كل المسارات لازم تكون داخله أو داخل مجلد مشاريع AndroidIDE. */
    class Workspace(val root: File, val projects: File) {
        fun resolve(p: String): File {
            val t = p.trim().ifEmpty { "." }
            val f = if (t.startsWith("/")) File(t) else File(root, t)
            val c = f.canonicalFile
            val ok = listOf(root, projects).any {
                val r = it.canonicalFile
                c == r || c.path.startsWith(r.path + File.separator)
            }
            if (!ok) throw SecurityException("المسار خارج مجلد العمل: $p")
            return c
        }

        fun rel(f: File): String {
            val r = root.canonicalFile.path
            return if (f.path.startsWith(r + File.separator)) f.path.substring(r.length + 1) else f.path
        }
    }

    fun projectsDir(): File = File(Environment.getExternalStorageDirectory(), "AndroidIDEProjects")

    // ------------------------------------------------------------------ parsing
    private val toolRe = Regex("<tool\\s+([^>]*?)\\s*(?:/>|>([\\s\\S]*?)</tool>)")
    private val attrRe = Regex("(\\w+)=\"([^\"]*)\"")
    private val editRe = Regex("<find>([\\s\\S]*?)</find>\\s*<replace>([\\s\\S]*?)</replace>")
    private val resultRe = Regex("<result ok=\"(true|false)\" label=\"([^\"]*)\">\\r?\\n([\\s\\S]*?)\\r?\\n</result>")

    private fun trimNl(s: String) =
        s.removePrefix("\r\n").removePrefix("\n").removeSuffix("\r\n").removeSuffix("\n")

    fun parse(reply: String): List<Call> = toolRe.findAll(reply).map { m ->
        val attrs = attrRe.findAll(m.groupValues[1]).associate { it.groupValues[1] to it.groupValues[2] }
        Call(attrs["name"].orEmpty(), attrs, trimNl(m.groupValues[2]))
    }.toList()

    fun strip(reply: String): String = toolRe.replace(reply, "").trim()

    /** يقصّ محتوى الملفات الكبيرة فالرسائل القديمة باش السياق ما يتضخمش. */
    fun compact(m: AiClient.Msg): AiClient.Msg {
        if (m.role == "assistant" && m.content.contains("<tool")) {
            val c = toolRe.replace(m.content) { r ->
                val body = r.groupValues[2]
                if (body.length > 300) "<tool " + r.groupValues[1] + ">\n[content omitted]\n</tool>" else r.value
            }
            return AiClient.Msg(m.role, c)
        }
        if (isResults(m) && m.content.length > 1500) return AiClient.Msg(m.role, m.content.take(1500) + "\n[…]\n</tool_results>")
        return m
    }

    fun isResults(m: AiClient.Msg) = m.role == "user" && m.content.startsWith("<tool_results>")

    fun parseResults(content: String): List<Triple<Boolean, String, String>> =
        resultRe.findAll(content).map {
            Triple(it.groupValues[1] == "true", it.groupValues[2], it.groupValues[3].lineSequence().firstOrNull().orEmpty())
        }.toList()

    fun describe(c: Call): String {
        val p = c.path.ifBlank { "." }
        return when (c.name) {
            "write_file" -> "كتابة $p"
            "edit_file" -> "تعديل $p"
            "read_file" -> "قراءة $p"
            "list_dir" -> "عرض المجلد $p"
            "create_dir" -> "إنشاء المجلد $p"
            "delete" -> "حذف $p"
            "move" -> "نقل $p"
            "search" -> "بحث «${c.attrs["query"].orEmpty()}»"
            else -> c.name
        }
    }

    fun formatResults(rs: List<StepResult>): String = buildString {
        appendLine("<tool_results>")
        rs.forEach { r ->
            appendLine("<result ok=\"${r.ok}\" label=\"${describe(r.call).replace('"', '\'')}\">")
            appendLine(r.text)
            appendLine("</result>")
        }
        append("</tool_results>")
    }

    // ------------------------------------------------------------------ undo
    private val stack = ArrayDeque<List<Pair<File, String?>>>()

    fun end(r: Run) {
        if (r.undo.isEmpty()) return
        synchronized(stack) {
            stack.addLast(r.undo.toList())
            while (stack.size > 10) stack.removeFirst()
        }
    }

    /** يجب استدعاؤها من الـ UI thread. */
    fun undoLast(a: Activity): String {
        val last = synchronized(stack) { stack.removeLastOrNull() } ?: return "لا يوجد تنفيذ سابق للتراجع عنه"
        var n = 0
        for ((f, old) in last.asReversed()) {
            try {
                if (old == null) f.delete() else put(a, f, old)
                n++
            } catch (t: Throwable) { /* نكمّل الباقي */ }
        }
        return "تم التراجع عن $n ملف"
    }

    private fun remember(run: Run, f: File, old: String?) {
        if (run.undo.none { it.first == f }) run.undo.add(f to old)
    }

    // ------------------------------------------------------------------ UI-thread helpers
    private fun <T> onUi(a: Activity, f: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return f()
        val latch = CountDownLatch(1)
        var res: Result<T>? = null
        a.runOnUiThread { res = runCatching(f); latch.countDown() }
        latch.await()
        return res!!.getOrThrow()
    }

    private fun confirm(a: Activity, title: String, msg: String): Boolean {
        val latch = CountDownLatch(1)
        var yes = false
        a.runOnUiThread {
            AlertDialog.Builder(a).setTitle(title).setMessage(msg)
                .setPositiveButton("تنفيذ") { _, _ -> yes = true; latch.countDown() }
                .setNegativeButton("رفض") { _, _ -> latch.countDown() }
                .setOnCancelListener { latch.countDown() }
                .show()
        }
        latch.await()
        return yes
    }

    private fun guard(a: Activity, ask: Boolean, title: String, what: String) {
        if (ask && !confirm(a, title, what)) throw Denied()
    }

    private fun sameFile(ed: EditorAccess, f: File): Boolean =
        try { ed.file()?.canonicalFile == f.canonicalFile } catch (t: Throwable) { false }

    /** يكتب على القرص، ولو الملف مفتوح فالمحرر يحدّثه هو كذلك. */
    private fun put(a: Activity, f: File, text: String) {
        f.parentFile?.mkdirs()
        f.writeText(text)
        onUi(a) {
            val ed = EditorAccess.find(a)
            if (ed != null && sameFile(ed, f)) ed.replaceAll(text)
        }
    }

    /** النص الحالي: من المحرر إن كان الملف مفتوحا (قد يحتوي تعديلات غير محفوظة)، وإلا من القرص. */
    private fun current(a: Activity, f: File): String? {
        val fromEditor: String? = onUi(a) {
            val ed = EditorAccess.find(a)
            if (ed != null && sameFile(ed, f)) ed.allText() else null
        }
        if (fromEditor != null) return fromEditor
        if (!f.isFile) return null
        require(f.length() <= 2_000_000) { "الملف كبير جدا" }
        return f.readText()
    }

    private fun cap(s: String) = if (s.length > 12000) s.take(12000) + "\n…[تم الاقتطاع]" else s

    // ------------------------------------------------------------------ tools
    fun execute(a: Activity, run: Run, ws: Workspace, c: Call, ask: Boolean): StepResult =
        try {
            StepResult(c, true, cap(dispatch(a, run, ws, c, ask)))
        } catch (d: Denied) {
            StepResult(c, false, "رفض المستخدم هذا الإجراء. لا تكرّره؛ اسأله ماذا يريد.")
        } catch (t: Throwable) {
            StepResult(c, false, t.message ?: t.javaClass.simpleName)
        }

    private val skipDirs = setOf("build", ".gradle", ".git", ".idea", ".cxx", ".kotlin", "node_modules")
    private val binExt = setOf(
        "png", "jpg", "jpeg", "webp", "gif", "jar", "aar", "apk", "so", "zip",
        "ttf", "otf", "mp3", "mp4", "class", "dex", "keystore", "jks"
    )

    private fun dispatch(a: Activity, run: Run, ws: Workspace, c: Call, ask: Boolean): String = when (c.name) {

        "list_dir" -> {
            val d = ws.resolve(c.path)
            if (!d.isDirectory) throw IllegalArgumentException("ليس مجلدا: ${c.path}")
            val items = d.listFiles()?.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() })) ?: emptyList()
            if (items.isEmpty()) "(فارغ)"
            else items.take(300).joinToString("\n") { if (it.isDirectory) it.name + "/" else it.name }
        }

        "read_file" -> {
            val f = ws.resolve(c.path)
            current(a, f) ?: throw IllegalArgumentException("الملف غير موجود: ${c.path}")
        }

        "write_file" -> {
            val f = ws.resolve(c.path)
            require(!f.isDirectory) { "هذا مجلد وليس ملفا: ${c.path}" }
            val old = current(a, f)
            guard(a, ask, "كتابة ملف", ws.rel(f))
            remember(run, f, old)
            put(a, f, c.body)
            (if (old == null) "تم إنشاء " else "تم تحديث ") + ws.rel(f) + " (" + c.body.lines().size + " سطر)"
        }

        "edit_file" -> {
            val f = ws.resolve(c.path)
            val orig = current(a, f) ?: throw IllegalArgumentException("الملف غير موجود: ${c.path}")
            val edits = editRe.findAll(c.body).toList()
            require(edits.isNotEmpty()) { "edit_file يحتاج <find> و <replace>" }
            var text = orig
            for ((i, m) in edits.withIndex()) {
                val find = trimNl(m.groupValues[1])
                val rep = trimNl(m.groupValues[2])
                require(find.isNotEmpty()) { "تعديل رقم ${i + 1}: <find> فارغ" }
                val first = text.indexOf(find)
                require(first >= 0) { "تعديل رقم ${i + 1}: النص غير موجود بالضبط فالملف — اقرأ الملف من جديد وانسخ النص حرفيا" }
                require(text.indexOf(find, first + 1) < 0) { "تعديل رقم ${i + 1}: النص يتكرر أكثر من مرة — زد سياقا أكثر" }
                text = text.substring(0, first) + rep + text.substring(first + find.length)
            }
            guard(a, ask, "تعديل ملف", ws.rel(f))
            remember(run, f, orig)
            put(a, f, text)
            "تم تعديل " + ws.rel(f) + " (" + edits.size + " تعديل)"
        }

        "create_dir" -> {
            val d = ws.resolve(c.path)
            guard(a, ask, "إنشاء مجلد", ws.rel(d))
            if (d.isDirectory || d.mkdirs()) "تم إنشاء " + ws.rel(d) else throw IllegalStateException("تعذّر إنشاء المجلد")
        }

        "delete" -> {
            val f = ws.resolve(c.path)
            require(f.exists()) { "غير موجود: ${c.path}" }
            require(f != ws.root.canonicalFile && f != ws.projects.canonicalFile) { "لا يمكن حذف مجلد العمل نفسه" }
            if (!confirm(a, "حذف", ws.rel(f))) throw Denied()
            if (f.isFile && f.length() < 1_000_000) remember(run, f, try { f.readText() } catch (t: Throwable) { null })
            if (f.deleteRecursively()) "تم حذف " + ws.rel(f) else throw IllegalStateException("تعذّر الحذف")
        }

        "move" -> {
            val src = ws.resolve(c.path)
            val dst = ws.resolve(c.attrs["to"].orEmpty())
            require(src.exists()) { "غير موجود: ${c.path}" }
            require(!dst.exists()) { "الوجهة موجودة مسبقا" }
            guard(a, ask, "نقل", ws.rel(src) + "\n← " + ws.rel(dst))
            dst.parentFile?.mkdirs()
            if (!src.renameTo(dst)) {
                src.copyRecursively(dst)
                src.deleteRecursively()
            }
            "تم النقل إلى " + ws.rel(dst)
        }

        "search" -> {
            val q = c.attrs["query"].orEmpty()
            require(q.isNotBlank()) { "query مطلوب" }
            val base = ws.resolve(c.path.ifBlank { "." })
            val out = mutableListOf<String>()
            fun walk(f: File) {
                if (out.size >= 60) return
                if (f.isDirectory) {
                    if (f.name in skipDirs) return
                    f.listFiles()?.forEach { walk(it) }
                } else if (f.extension.lowercase() !in binExt && f.length() < 500_000) {
                    try {
                        f.useLines { lines ->
                            lines.forEachIndexed { i, l ->
                                if (out.size < 60 && l.contains(q, ignoreCase = true)) out.add(ws.rel(f) + ":" + (i + 1) + ": " + l.trim().take(200))
                            }
                        }
                    } catch (t: Throwable) { /* ملف غير نصي */ }
                }
            }
            walk(base)
            if (out.isEmpty()) "لا نتائج" else out.joinToString("\n")
        }

        else -> throw IllegalArgumentException("أداة غير معروفة: ${c.name}")
    }
}

KT_EOF

# ---------------------------------------------------------------- AiChat.kt
cat > "$PKG_DIR/AiChat.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.chip.Chip
import java.io.File

object AiChat {

    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var busy = false
    @Volatile private var reqId = 0
    @Volatile private var lastError: String? = null
    private var onChange: (() -> Unit)? = null

    private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    private const val MAX_STEPS = 20

    private fun notifyChange() { ui.post { onChange?.invoke() } }

    // ------------------------------------------------------------------ theme
    /** الألوان كتتجاب من theme ديال التطبيق نفسو (Material) باش المساعد يكون منسجم معاه 100%. */
    private class Pal(val dark: Boolean, private val a: Activity?, private val useApp: Boolean) {
        private fun c(names: List<String>, fb: Int): Int {
            if (a == null || !useApp) return fb
            for (n in names) {
                try {
                    val id = a.resources.getIdentifier(n, "attr", a.packageName)
                    if (id == 0) continue
                    val tv = TypedValue()
                    if (a.theme.resolveAttribute(id, tv, true) &&
                        tv.type >= TypedValue.TYPE_FIRST_COLOR_INT && tv.type <= TypedValue.TYPE_LAST_COLOR_INT
                    ) return tv.data
                } catch (t: Throwable) { /* نجرب اسم آخر */ }
            }
            return fb
        }

        private fun hex(d: String, l: String) = Color.parseColor(if (dark) d else l)

        val bg = c(listOf("colorSurfaceContainerHigh", "colorSurface"), hex("#1C1B22", "#FFFFFF"))
        val surface = c(listOf("colorSurfaceContainerHighest", "colorSurfaceVariant"), hex("#2B2A33", "#F0EFF5"))
        val text = c(listOf("colorOnSurface"), hex("#ECEBF2", "#1B1A20"))
        val sub = c(listOf("colorOnSurfaceVariant"), hex("#A09FAD", "#6C6B78"))
        val line = c(listOf("colorOutlineVariant", "colorOutline"), hex("#3A3946", "#D8D6E2"))
        val accent = c(listOf("colorPrimary"), Color.parseColor("#6200EE"))
        val onAccent = c(listOf("colorOnPrimary"), Color.WHITE)
        val accentBox = c(listOf("colorPrimaryContainer"), hex("#3B2A7A", "#E6DEFF"))
        val onAccentBox = c(listOf("colorOnPrimaryContainer"), hex("#EADDFF", "#21005D"))
        val danger = c(listOf("colorError"), Color.parseColor("#C62828"))
        val onDanger = c(listOf("colorOnError"), Color.WHITE)
        val codeBg = Color.parseColor("#0F1015")
        val codeText = Color.parseColor("#E4E4EE")
        val inlineBg = line
    }

    private data class Seg(val isCode: Boolean, val text: String, val lang: String = "")

    private fun pal(a: Activity): Pal {
        val night = (a.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val theme = AiPrefs(a).theme
        val dark = when (theme) {
            "dark" -> true
            "light" -> false
            else -> night
        }
        return Pal(dark, a, theme == "auto")
    }

    /** ألوان الزر العائم: نفس ألوان FAB ديال Material 3 (primary container). */
    fun fabStyle(a: Activity): IntArray {
        val p = pal(a)
        return intArrayOf(p.accentBox, p.onAccentBox)
    }

    /** أيقونات vector كيصاوبها السكريبت فـ res/drawable. */
    fun icon(a: Activity, name: String): Drawable? {
        for (pkg in listOf(a.packageName, "com.itsaky.androidide")) {
            val id = a.resources.getIdentifier(name, "drawable", pkg)
            if (id != 0) return a.getDrawable(id)?.mutate()
        }
        return null
    }

    // ------------------------------------------------------------------ view helpers
    private fun dp(a: Activity, v: Int) = (v * a.resources.displayMetrics.density).toInt()

    private fun shape(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color); cornerRadius = radius
    }

    private fun outlined(color: Int, radius: Float, line: Int, w: Int) = GradientDrawable().apply {
        setColor(color); cornerRadius = radius; setStroke(w.coerceAtLeast(1), line)
    }

    private fun ripple(content: Drawable, radius: Float): Drawable =
        RippleDrawable(ColorStateList.valueOf(Color.argb(70, 150, 150, 160)), content, shape(Color.WHITE, radius))

    private fun iconButton(
        a: Activity, name: String, desc: String, fg: Int, bgc: Int, sizeDp: Int, onClick: () -> Unit
    ): ImageView {
        val oval = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(bgc) }
        val mask = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) }
        return ImageView(a).apply {
            setImageDrawable(icon(a, name))
            imageTintList = ColorStateList.valueOf(fg)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            val pad = dp(a, sizeDp) * 28 / 100
            setPadding(pad, pad, pad, pad)
            background = RippleDrawable(ColorStateList.valueOf(Color.argb(60, 150, 150, 160)), oval, mask)
            contentDescription = desc
            isClickable = true; isFocusable = true
            setOnClickListener { onClick() }
        }
    }

    private fun materialButton(a: Activity, p: Pal, label: String, filled: Boolean, onClick: () -> Unit): MaterialButton =
        MaterialButton(a).apply {
            text = label
            setAllCaps(false)
            cornerRadius = dp(a, 20)
            if (filled) {
                backgroundTintList = ColorStateList.valueOf(p.accent)
                setTextColor(p.onAccent)
            } else {
                backgroundTintList = ColorStateList.valueOf(Color.TRANSPARENT)
                setTextColor(p.accent)
                strokeWidth = dp(a, 1)
                strokeColor = ColorStateList.valueOf(p.line)
            }
            setOnClickListener { onClick() }
        }

    private fun spinner(a: Activity, p: Pal, items: List<String>, selected: String): Spinner {
        val ad = object : ArrayAdapter<String>(a, android.R.layout.simple_spinner_dropdown_item, items) {
            override fun getView(pos: Int, v: View?, g: ViewGroup): View =
                (super.getView(pos, v, g) as TextView).apply { setTextColor(p.text) }
            override fun getDropDownView(pos: Int, v: View?, g: ViewGroup): View =
                (super.getDropDownView(pos, v, g) as TextView).apply { setTextColor(p.text); setBackgroundColor(p.surface) }
        }
        return Spinner(a).apply {
            adapter = ad
            setSelection(items.indexOf(selected).coerceAtLeast(0))
        }
    }

    /** يضبط BottomSheetDialog: يتمدد لأعلى الشاشة، بلا حالة مطوية، والخلفية ديال المحتوى هي اللي كتبان. */
    private fun setupSheet(a: Activity, dialog: BottomSheetDialog, content: View, topOffsetDp: Int) {
        dialog.setContentView(content)
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        val off = dp(a, topOffsetDp)
        (content.parent as? View)?.let { sheet ->
            sheet.setBackgroundColor(Color.TRANSPARENT)
            // ارتفاع الـ sheet = ارتفاع النافذة - الهامش العلوي (يتغير مع الكيبورد) باش خانة الكتابة تبقى ظاهرة
            (sheet.parent as? View)?.addOnLayoutChangeListener { _, _, t, _, b, _, _, _, _ ->
                val h = (b - t) - off
                if (h > 0 && sheet.layoutParams.height != h) {
                    sheet.layoutParams.height = h
                    sheet.requestLayout()
                }
            }
        }
        dialog.behavior.apply {
            skipCollapsed = true
            isFitToContents = false
            expandedOffset = off
            state = BottomSheetBehavior.STATE_EXPANDED
        }
    }

    private fun sheetBackground(a: Activity, p: Pal) = GradientDrawable().apply {
        setColor(p.bg)
        val r = dp(a, 28).toFloat()
        cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
    }

    // ------------------------------------------------------------------ markdown (خفيف)
    private fun parse(s: String): List<Seg> {
        val out = mutableListOf<Seg>()
        val re = Regex("```([A-Za-z0-9_+#.-]*)[ \\t]*\\r?\\n([\\s\\S]*?)```")
        var last = 0
        for (m in re.findAll(s)) {
            if (m.range.first > last) out.add(Seg(false, s.substring(last, m.range.first)))
            out.add(Seg(true, m.groupValues[2].trimEnd(), m.groupValues[1]))
            last = m.range.last + 1
        }
        if (last < s.length) out.add(Seg(false, s.substring(last)))
        return out.filter { it.isCode || it.text.isNotBlank() }
    }

    /** عناوين # ، **bold** ، `inline code` ، ونقط القوائم. */
    private fun md(p: Pal, s: String): CharSequence {
        val sb = SpannableStringBuilder()
        val inline = Regex("\\*\\*(.+?)\\*\\*|`([^`]+)`")
        val head = Regex("^#{1,6}\\s+(.*)$")
        val bullet = Regex("^\\s*[-*]\\s+")
        val lines = s.trim().split("\n")
        lines.forEachIndexed { idx, raw ->
            var line = raw
            var header = false
            val hm = head.find(line)
            if (hm != null) { line = hm.groupValues[1]; header = true }
            else if (bullet.containsMatchIn(line)) line = line.replace(bullet, "• ")
            val start = sb.length
            var last = 0
            for (m in inline.findAll(line)) {
                sb.append(line.substring(last, m.range.first))
                val st = sb.length
                if (m.groups[1] != null) {
                    sb.append(m.groupValues[1])
                    sb.setSpan(StyleSpan(Typeface.BOLD), st, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                } else {
                    sb.append(m.groupValues[2])
                    sb.setSpan(TypefaceSpan("monospace"), st, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    sb.setSpan(BackgroundColorSpan(p.inlineBg), st, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                last = m.range.last + 1
            }
            sb.append(line.substring(last))
            if (header) {
                sb.setSpan(StyleSpan(Typeface.BOLD), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                sb.setSpan(RelativeSizeSpan(1.1f), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            if (idx < lines.lastIndex) sb.append("\n")
        }
        return sb
    }

    // ------------------------------------------------------------------ chat sheet
    fun show(a: Activity) {
        val prefs = AiPrefs(a)
        val p = pal(a)
        val dialog = BottomSheetDialog(a)

        fun toast(s: String, long: Boolean = false) =
            Toast.makeText(a, s, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()

        fun copy(code: String) {
            try {
                val cm = a.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("code", code))
                toast("تم النسخ")
            } catch (t: Throwable) { toast("تعذّر التنفيذ: ${t.message}", true) }
        }

        fun clip(): String? = try {
            val cm = a.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val c = cm.primaryClip
            if (c == null || c.itemCount == 0) null
            else c.getItemAt(0).coerceToText(a)?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        } catch (t: Throwable) { null }

        val list = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(a, 4), 0, dp(a, 4))
        }
        val scroll = ScrollView(a).apply { addView(list); isVerticalScrollBarEnabled = false }
        val send = iconButton(a, "ic_ai_send", "إرسال", p.onAccent, p.accent, 44) { }
        fun updateSend() {
            send.setImageDrawable(icon(a, if (busy) "ic_ai_stop" else "ic_ai_send"))
            send.contentDescription = if (busy) "إيقاف" else "إرسال"
        }

        // ---- تطبيق الكود على المحرر
        fun doInsert(code: String) {
            val ed = EditorAccess.find(a) ?: run { toast("ما كاين حتى ملف مفتوح"); return }
            try { ed.replaceSelection(code); toast("تم التطبيق — يمكنك التراجع من المحرر") }
            catch (t: Throwable) { toast("تعذّر التنفيذ: ${t.message}", true) }
        }

        fun doReplace(code: String) {
            val ed = EditorAccess.find(a) ?: run { toast("ما كاين حتى ملف مفتوح"); return }
            val old = ed.allText()
            AlertDialog.Builder(a)
                .setTitle("استبدال الملف كامل؟")
                .setMessage("${old.lines().size} سطر ← ${code.lines().size} سطر\n(تقدر دير Undo فالمحرر)")
                .setPositiveButton("استبدل") { _, _ ->
                    try { ed.replaceAll(code); toast("تم التطبيق — يمكنك التراجع من المحرر") }
                    catch (t: Throwable) { toast("تعذّر التنفيذ: ${t.message}", true) }
                }
                .setNegativeButton("إلغاء", null)
                .show()
        }

        // ---- عناصر الرسائل
        fun codeView(s: Seg): View {
            val box = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                background = shape(p.codeBg, dp(a, 12).toFloat())
                setPadding(dp(a, 10), dp(a, 6), dp(a, 10), dp(a, 8))
            }
            val bar = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            bar.addView(TextView(a).apply {
                text = s.lang.ifBlank { "code" }; setTextColor(Color.parseColor("#8A8A9A")); textSize = 11f
            }, LinearLayout.LayoutParams(0, WRAP, 1f))
            fun mini(label: String, f: () -> Unit) {
                bar.addView(TextView(a).apply {
                    text = label; textSize = 11f; setTextColor(p.codeText); gravity = Gravity.CENTER
                    setPadding(dp(a, 10), dp(a, 5), dp(a, 10), dp(a, 5))
                    background = ripple(shape(Color.parseColor("#2A2A34"), dp(a, 14).toFloat()), dp(a, 14).toFloat())
                    isClickable = true; isFocusable = true
                    setOnClickListener { f() }
                }, LinearLayout.LayoutParams(WRAP, WRAP).apply { marginStart = dp(a, 4) })
            }
            mini("نسخ") { copy(s.text) }
            mini("إدراج") { doInsert(s.text) }
            mini("استبدال") { doReplace(s.text) }

            val tv = TextView(a).apply {
                text = s.text; setTextColor(p.codeText); textSize = 12f; typeface = Typeface.MONOSPACE
                setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_LTR
                setHorizontallyScrolling(true)
                setPadding(0, dp(a, 6), 0, 0)
            }
            val hs = HorizontalScrollView(a).apply {
                addView(tv); isHorizontalScrollBarEnabled = false; layoutDirection = View.LAYOUT_DIRECTION_LTR
            }
            box.addView(bar)
            box.addView(hs)
            return box
        }

        fun itemParams(mine: Boolean) = LinearLayout.LayoutParams(if (mine) WRAP else MATCH, WRAP).apply {
            gravity = if (mine) Gravity.END else Gravity.START
            bottomMargin = dp(a, 8)
            if (mine) { marginStart = dp(a, 40) } else { marginEnd = dp(a, 16) }
        }

        /** بطاقة نشاط الوكيل: كل أداة نفّذها (✓ نجحت / ✗ فشلت). */
        fun activity(m: AiClient.Msg): View {
            val col = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                background = outlined(Color.TRANSPARENT, dp(a, 14).toFloat(), p.line, dp(a, 1))
                setPadding(dp(a, 12), dp(a, 8), dp(a, 12), dp(a, 8))
            }
            AiAgent.parseResults(m.content).forEach { (ok, label, detail) ->
                col.addView(TextView(a).apply {
                    text = (if (ok) "✓  " else "✗  ") + label + (if (!ok && detail.isNotBlank()) "\n    " + detail.take(160) else "")
                    textSize = 12.5f
                    setTextColor(if (ok) p.sub else p.danger)
                    textDirection = View.TEXT_DIRECTION_ANY_RTL
                    setPadding(0, dp(a, 2), 0, dp(a, 2))
                })
            }
            col.layoutParams = itemParams(false)
            return col
        }

        fun bubble(m: AiClient.Msg): View? {
            if (AiAgent.isResults(m)) return if (AiAgent.parseResults(m.content).isEmpty()) null else activity(m)
            val mine = m.role == "user"
            val body = if (mine) m.content else AiAgent.strip(m.content)
            if (body.isBlank()) return null
            val col = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                background = shape(if (mine) p.accentBox else p.surface, dp(a, 18).toFloat())
                setPadding(dp(a, 12), dp(a, 8), dp(a, 12), dp(a, 8))
            }
            if (mine) {
                col.addView(TextView(a).apply {
                    text = body; setTextColor(p.onAccentBox); textSize = 14f
                    setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_ANY_RTL
                })
            } else {
                for (s in parse(body)) {
                    if (s.isCode) {
                        col.addView(codeView(s), LinearLayout.LayoutParams(MATCH, WRAP).apply {
                            topMargin = dp(a, 4); bottomMargin = dp(a, 4)
                        })
                    } else {
                        col.addView(TextView(a).apply {
                            text = md(p, s.text); setTextColor(p.text); textSize = 14f
                            setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_ANY_RTL
                        })
                    }
                }
            }
            col.layoutParams = itemParams(mine)
            return col
        }

        fun working(): View = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = shape(p.surface, dp(a, 16).toFloat())
            setPadding(dp(a, 14), dp(a, 10), dp(a, 14), dp(a, 10))
            addView(ProgressBar(a).apply {
                isIndeterminate = true; indeterminateTintList = ColorStateList.valueOf(p.accent)
            }, LinearLayout.LayoutParams(dp(a, 18), dp(a, 18)))
            addView(TextView(a).apply {
                text = "جارٍ العمل…"; setTextColor(p.sub); textSize = 13f; setPadding(dp(a, 8), 0, 0, 0)
            })
            layoutParams = itemParams(false).apply { marginEnd = 0 }
        }

        fun notice(text: String): View = TextView(a).apply {
            this.text = text; setTextColor(p.sub); textSize = 13f; gravity = Gravity.CENTER
            textDirection = View.TEXT_DIRECTION_ANY_RTL
            setPadding(dp(a, 12), dp(a, 24), dp(a, 12), dp(a, 24))
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        }

        fun render() {
            list.removeAllViews()
            if (AiPlugin.history.isEmpty() && !busy) {
                list.addView(notice("أنا وكيل برمجي: أعطني أمرا وأنا أنفّذه.\nمثال: أنشئ مشروع أندرويد جديد باسم Notes مع شاشة رئيسية\nأو: أضف زر تسجيل الدخول في هذا الملف"))
            }
            AiPlugin.history.forEach { m -> bubble(m)?.let { list.addView(it) } }
            if (busy) list.addView(working())
            lastError?.let { e ->
                list.addView(TextView(a).apply {
                    text = "تعذّر إتمام الطلب\n$e"; setTextColor(p.onDanger); textSize = 13f
                    setTextIsSelectable(true)
                    background = shape(p.danger, dp(a, 14).toFloat())
                    setPadding(dp(a, 12), dp(a, 8), dp(a, 12), dp(a, 8))
                    layoutParams = itemParams(false)
                })
            }
            scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        }

        // ---- الإرسال / الإيقاف
        fun ask(prompt: String) {
            if (busy) return
            if (prefs.apiKey.isBlank()) { toast("ضع مفتاح API أولا", true); showSettings(a); return }
            startRun(a, prompt)
        }

        fun cancel() {
            reqId++; busy = false
            val last = AiPlugin.history.lastOrNull()
            if (last != null && last.role == "user" && !AiAgent.isResults(last)) AiPlugin.history.removeAt(AiPlugin.history.lastIndex)
            AiPlugin.save(a)
            updateSend(); render()
        }

        // ---- الهيدر
        val header = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val titles = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        titles.addView(TextView(a).apply {
            text = "مساعد الذكاء الاصطناعي"; setTextColor(p.text); textSize = 18f; typeface = Typeface.DEFAULT_BOLD
        })
        titles.addView(TextView(a).apply {
            text = prefs.provider + " · " + prefs.effectiveModel().ifBlank { "—" }
            setTextColor(p.sub); textSize = 11f; setSingleLine(); textDirection = View.TEXT_DIRECTION_LTR
        })
        val avatar = iconButton(a, "ic_ai_sparkle", "", p.onAccentBox, p.accentBox, 40) { }
        avatar.isClickable = false
        val more = iconButton(a, "ic_ai_more", "المزيد", p.sub, Color.TRANSPARENT, 40) { }
        more.setOnClickListener { v ->
            val pm = PopupMenu(a, v)
            pm.menu.add(0, 1, 0, "الإعدادات")
            pm.menu.add(0, 2, 1, "محادثة جديدة")
            pm.menu.add(0, 3, 2, "تراجع عن آخر تنفيذ")
            pm.setOnMenuItemClickListener { item ->
                when (item.itemId) {
                    1 -> showSettings(a)
                    2 -> { cancel(); AiPlugin.history.clear(); lastError = null; AiPlugin.save(a); render() }
                    3 -> toast(AiAgent.undoLast(a), true)
                }
                true
            }
            pm.show()
        }
        val close = iconButton(a, "ic_ai_close", "إغلاق", p.sub, Color.TRANSPARENT, 40) { dialog.dismiss() }
        header.addView(avatar, LinearLayout.LayoutParams(dp(a, 40), dp(a, 40)).apply { marginEnd = dp(a, 12) })
        header.addView(titles, LinearLayout.LayoutParams(0, WRAP, 1f))
        header.addView(more, LinearLayout.LayoutParams(dp(a, 40), dp(a, 40)))
        header.addView(close, LinearLayout.LayoutParams(dp(a, 40), dp(a, 40)))

        // ---- اقتراحات سريعة (Material Chips)
        val input = EditText(a).apply {
            hint = "اكتب أمرك…"; setTextColor(p.text); setHintTextColor(p.sub)
            background = shape(p.surface, dp(a, 24).toFloat())
            setPadding(dp(a, 16), dp(a, 10), dp(a, 16), dp(a, 10))
            maxLines = 4; textSize = 14f
            textDirection = View.TEXT_DIRECTION_ANY_RTL
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        }
        val chipsRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        fun chip(label: String, onClick: () -> Unit) {
            chipsRow.addView(Chip(a).apply {
                text = label; setTextColor(p.text); isCheckable = false
                setOnClickListener { onClick() }
            }, LinearLayout.LayoutParams(WRAP, WRAP).apply { marginEnd = dp(a, 6) })
        }
        chip("مشروع جديد") {
            input.setText("أنشئ مشروع أندرويد جديد باسم ")
            input.setSelection(input.text.length); input.requestFocus()
        }
        chip("أصلح الملف") { ask("أصلح الأخطاء في الملف المفتوح وطبّق الإصلاح مباشرة.") }
        chip("اشرح الملف") { ask("اشرح لي هذا الملف باختصار.") }
        chip("حسّن الكود") { ask("حسّن جودة وقراءة الكود (التحديد إن وُجد، وإلا الملف) دون تغيير السلوك، وطبّق التعديل مباشرة.") }
        chip("اختبارات") { ask("اكتب اختبارات unit tests مناسبة للملف الحالي وأنشئها في مكانها الصحيح بالمشروع.") }
        chip("تعليقات") { ask("أضف توثيق KDoc/Javadoc واضحا للملف الحالي وطبّقه مباشرة.") }
        chip("حلّل خطأ من الحافظة") {
            val c = clip()
            if (c == null) toast("الحافظة فارغة — انسخ اللوغ أولا")
            else ask("حلّل هذا الخطأ/اللوغ، وقل لي السبب، ثم أصلحه في المشروع إن أمكن:\n```\n${c.take(6000)}\n```")
        }
        val chips = HorizontalScrollView(a).apply { addView(chipsRow); isHorizontalScrollBarEnabled = false }

        send.setOnClickListener {
            if (busy) { cancel(); return@setOnClickListener }
            val t = input.text.toString().trim()
            if (t.isNotEmpty()) { input.text.clear(); ask(t) }
        }
        val inputRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        inputRow.addView(input, LinearLayout.LayoutParams(0, WRAP, 1f).apply { marginEnd = dp(a, 8) })
        inputRow.addView(send, LinearLayout.LayoutParams(dp(a, 44), dp(a, 44)))

        // ---- التجميع
        val root = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 16), dp(a, 10), dp(a, 16), dp(a, 12))
            background = sheetBackground(a, p)
        }
        root.addView(View(a).apply { background = shape(p.line, dp(a, 2).toFloat()) },
            LinearLayout.LayoutParams(dp(a, 32), dp(a, 4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(a, 10) })
        root.addView(header)
        root.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f).apply { topMargin = dp(a, 8) })
        root.addView(chips, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(a, 6); bottomMargin = dp(a, 8) })
        root.addView(inputRow)

        onChange = { updateSend(); render() }
        dialog.setOnDismissListener { onChange = null }
        updateSend(); render()
        setupSheet(a, dialog, root, 56)
        dialog.show()
    }

    // ------------------------------------------------------------ agent loop
    private fun startRun(a: Activity, prompt: String) {
        val prefs = AiPrefs(a)
        lastError = null
        val ed = EditorAccess.find(a)
        val ws = AiAgent.Workspace(projectRoot(ed?.file()) ?: AiAgent.projectsDir(), AiAgent.projectsDir())
        val system = buildSystem(ed, ws)
        val first = buildPrompt(prompt, ed)
        val runStart = AiPlugin.history.size
        AiPlugin.history.add(AiClient.Msg("user", prompt))
        val my = ++reqId
        busy = true
        notifyChange()

        Thread {
            var err: String? = null
            val run = AiAgent.Run()
            try {
                var step = 0
                while (my == reqId) {
                    val snap = AiPlugin.history.toList()
                    val cut = runStart.coerceAtMost(snap.size)
                    val older = snap.subList(0, cut).takeLast(10).dropWhile { it.role != "user" }.map { AiAgent.compact(it) }
                    val cur = snap.subList(cut, snap.size).toMutableList()
                    if (cur.isNotEmpty()) cur[0] = AiClient.Msg("user", first)
                    val reply = AiClient.complete(prefs, system, older + cur)
                    if (my != reqId) break
                    AiPlugin.history.add(AiClient.Msg("assistant", reply))
                    notifyChange()

                    val calls = AiAgent.parse(reply)
                    if (calls.isEmpty()) break
                    step++
                    if (step > MAX_STEPS) {
                        AiPlugin.history.add(AiClient.Msg("user", "<tool_results>\n</tool_results>"))
                        AiPlugin.history.add(AiClient.Msg("assistant", "توقفت بعد $MAX_STEPS خطوة. اكتب «تابع» لإكمال العمل."))
                        break
                    }
                    val results = calls.map { AiAgent.execute(a, run, ws, it, prefs.askBeforeEdit) }
                    if (my != reqId) break
                    AiPlugin.history.add(AiClient.Msg("user", AiAgent.formatResults(results)))
                    notifyChange()
                }
            } catch (t: Throwable) {
                err = t.message ?: t.javaClass.simpleName
            }
            AiAgent.end(run)
            ui.post {
                if (my == reqId) {
                    busy = false
                    if (err != null) {
                        val last = AiPlugin.history.lastOrNull()
                        if (AiPlugin.history.size == runStart + 1 && last != null && last.role == "user") {
                            AiPlugin.history.removeAt(AiPlugin.history.lastIndex)
                        }
                        lastError = err
                    }
                    AiPlugin.save(a)
                    onChange?.invoke()
                }
            }
        }.start()
    }

    // -------------------------------------------------------------- settings
    fun showSettings(a: Activity) {
        val prefs = AiPrefs(a)
        val p = pal(a)
        val dialog = BottomSheetDialog(a)

        fun label(t: String) = TextView(a).apply {
            text = t; setTextColor(p.sub); textSize = 12f; setPadding(0, dp(a, 14), 0, dp(a, 4))
        }
        fun field(h: String, v: String, pass: Boolean = false) = EditText(a).apply {
            hint = h; setText(v); setTextColor(p.text); setHintTextColor(p.sub); setSingleLine()
            background = shape(p.surface, dp(a, 12).toFloat())
            setPadding(dp(a, 14), dp(a, 12), dp(a, 14), dp(a, 12))
            inputType = if (pass) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_TEXT
        }

        val modes = listOf("تلقائي — ينفّذ مباشرة", "اسأل قبل كل تعديل")
        val provider = spinner(a, p, AiPrefs.PROVIDERS, prefs.provider)
        val model = field("فارغ = الموديل الافتراضي", prefs.model)
        val key = field("API Key", prefs.apiKey, pass = true)
        val base = field("اختياري (ضروري مع custom)", prefs.baseUrl)
        val mode = spinner(a, p, modes, if (prefs.askBeforeEdit) modes[1] else modes[0])
        val theme = spinner(a, p, AiPrefs.THEMES, prefs.theme)

        fun save() {
            prefs.provider = provider.selectedItem.toString()
            prefs.model = model.text.toString().trim()
            prefs.apiKey = key.text.toString().trim()
            prefs.baseUrl = base.text.toString().trim()
            prefs.askBeforeEdit = mode.selectedItemPosition == 1
            prefs.theme = theme.selectedItem.toString()
        }

        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 20), dp(a, 10), dp(a, 20), dp(a, 20))
            background = sheetBackground(a, p)
        }
        box.addView(View(a).apply { background = shape(p.line, dp(a, 2).toFloat()) },
            LinearLayout.LayoutParams(dp(a, 32), dp(a, 4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(a, 12) })
        box.addView(TextView(a).apply {
            text = "إعدادات المساعد"; setTextColor(p.text); textSize = 18f; typeface = Typeface.DEFAULT_BOLD
        })
        box.addView(label("المزوّد")); box.addView(provider)
        box.addView(label("الموديل")); box.addView(model)
        box.addView(label("API Key (كيتخزّن محليا فجهازك فقط)")); box.addView(key)
        box.addView(label("Base URL")); box.addView(base)
        box.addView(label("وضع التنفيذ (الحذف دائما يطلب تأكيدا)")); box.addView(mode)
        box.addView(label("المظهر")); box.addView(theme)

        val row = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(materialButton(a, p, "اختبار الاتصال", false) {
            save()
            Toast.makeText(a, "⏳ كنجرب الاتصال…", Toast.LENGTH_SHORT).show()
            Thread {
                val msg = try { AiClient.ping(prefs); "الاتصال ناجح" }
                catch (t: Throwable) { "فشل الاتصال: ${t.message ?: t.javaClass.simpleName}" }
                a.runOnUiThread { Toast.makeText(a, msg, Toast.LENGTH_LONG).show() }
            }.start()
        }, LinearLayout.LayoutParams(0, WRAP, 1f).apply { marginEnd = dp(a, 8) })
        row.addView(materialButton(a, p, "حفظ", true) {
            save()
            Toast.makeText(a, "تم الحفظ", Toast.LENGTH_SHORT).show()
            dialog.dismiss()
        }, LinearLayout.LayoutParams(0, WRAP, 1f))
        box.addView(row, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(a, 20) })

        val sc = ScrollView(a).apply { addView(box); isVerticalScrollBarEnabled = false }
        setupSheet(a, dialog, sc, 96)
        dialog.show()
    }

    // --------------------------------------------------------------- context
    private fun buildPrompt(p: String, ed: EditorAccess?): String = buildString {
        appendLine(p)
        if (ed != null) {
            ed.file()?.let { appendLine("\n## Current file: ${it.path}") }
            ed.selection()?.let { appendLine("\n## Selected text:\n```\n${it.take(4000)}\n```") }
            val all = ed.allText()
            if (all.isNotBlank()) {
                appendLine("\n## Full current file:\n```\n${all.take(12000)}\n```")
                if (all.length > 12000) appendLine("(الملف طويل: تم اقتطاع الجزء الأخير — استعمل read_file لقراءته كاملا)")
            }
        }
    }

    private val AGENT_RULES = """
You are an autonomous coding AGENT embedded inside AndroidIDE (an Android IDE running on the phone).
The user gives short commands and you EXECUTE them with tools. Never just describe what to do when you can do it.
Reply in the same language the user writes in. Keep chat text short.

## Tools
Emit tool calls as tag blocks in your reply (several per reply are allowed; they run in order).
The results come back in the next message inside <tool_results>. Continue until the task is fully done,
then reply with a SHORT summary and NO tool tags.

<tool name="list_dir" path="dir"/>
<tool name="read_file" path="file"/>
<tool name="write_file" path="file">
complete file content, raw (no code fence, no escaping)
</tool>
<tool name="edit_file" path="file">
<find>exact existing text (copy it verbatim, must be unique in the file)</find>
<replace>new text</replace>
</tool>
<tool name="create_dir" path="dir"/>
<tool name="move" path="from" to="to"/>
<tool name="delete" path="file-or-dir"/>
<tool name="search" query="text" path="dir"/>

## Rules
- Paths are relative to the workspace root, or absolute inside the projects folder (both given below).
- To create a NEW project, use absolute paths under the projects folder and write every file the project needs
  (settings.gradle.kts, build.gradle.kts, app/build.gradle.kts, gradle.properties, AndroidManifest.xml,
  MainActivity, layouts/values). Tell the user once that the Gradle wrapper must be added/synced by the IDE.
- Use edit_file for small changes in existing files, write_file for new files or full rewrites.
  Always write COMPLETE files: never placeholders such as "rest of the code unchanged".
- read_file before editing a file you have not seen. The currently open file is included in the first message.
- Do not paste into the chat the code you already wrote with tools.
- If the request is ambiguous, pick the most reasonable option and proceed; ask only when truly blocked.
- If the user only wants an explanation or review, answer in text without tools.
- If the user asks for a snippet only, return ONE fenced code block with the complete ready-to-insert code.
- Do not invent APIs or files that are not in the project; verify with list_dir/search/read_file.
- NEVER claim that you created or changed anything unless a <tool_results> block confirmed it. Do the work with tools first.
- NEVER use the API's native function calling. Tools are ONLY the plain-text <tool .../> tags above.
- After write/edit, if something may break (imports, manifest entries, dependencies), fix it in the same run.
"""

    private fun buildSystem(ed: EditorAccess?, ws: AiAgent.Workspace): String = buildString {
        appendLine(AGENT_RULES.trim())
        appendLine("\n## Workspace root: ${ws.root.path}")
        appendLine("## Projects folder: ${ws.projects.path}")
        appendLine("\n## Files in workspace:")
        val lines = mutableListOf<String>()
        tree(ws.root, ws.root, 0, lines)
        lines.forEach { appendLine("- $it") }
        if (lines.isEmpty()) appendLine("(empty)")
    }

    private fun projectRoot(f: File?): File? {
        val first = f?.parentFile
        var d = first
        while (d != null) {
            if (File(d, "settings.gradle").exists() || File(d, "settings.gradle.kts").exists()) return d
            d = d.parentFile
        }
        return first
    }

    private val skip = setOf("build", ".gradle", ".git", ".idea", ".cxx", ".kotlin", "node_modules")
    private val skipExt = setOf(
        "png", "jpg", "jpeg", "webp", "gif", "jar", "aar", "apk", "so", "zip",
        "ttf", "otf", "mp3", "mp4", "class", "dex", "keystore", "jks"
    )

    private fun tree(root: File, dir: File, depth: Int, out: MutableList<String>) {
        if (depth > 6 || out.size >= 100) return
        dir.listFiles()?.sortedBy { it.name }?.forEach { f ->
            if (out.size >= 100 || f.name in skip) return@forEach
            if (f.isDirectory) tree(root, f, depth + 1, out)
            else if (f.extension.lowercase() !in skipExt) out.add(f.relativeTo(root).path)
        }
    }
}

KT_EOF

# ---------------------------------------------------------------- AiPlugin.kt
cat > "$PKG_DIR/AiPlugin.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.res.ColorStateList
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.graphics.Rect
import android.widget.FrameLayout
import com.google.android.material.floatingactionbutton.FloatingActionButton
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.abs

/** نقطة الدخول: كتتسجل مرة وحدة من Application.onCreate وكتحط زر AI عائم (Material FAB) فشاشة المحرر. */
object AiPlugin {

    private const val MAX_HISTORY = 80

    @Volatile private var installed = false
    val history: MutableList<AiClient.Msg> = CopyOnWriteArrayList()

    @JvmStatic
    fun install(app: Application) {
        if (installed) return
        installed = true
        load(app)
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) { if (a.javaClass.simpleName.contains("Editor")) attachFab(a) }
            override fun onActivityCreated(a: Activity, s: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, o: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }

    // ------------------------------------------------------------ history persistence
    fun load(ctx: Context) {
        try {
            val raw = AiPrefs(ctx).history
            if (raw.isBlank()) return
            val arr = JSONArray(raw)
            history.clear()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                history.add(AiClient.Msg(o.getString("role"), o.getString("content")))
            }
        } catch (t: Throwable) { /* سجل تالف: نتجاهله */ }
    }

    fun save(ctx: Context) {
        try {
            while (history.size > MAX_HISTORY) history.removeAt(0)
            val arr = JSONArray()
            history.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
            AiPrefs(ctx).history = arr.toString()
        } catch (t: Throwable) { /* ما نكسرو التطبيق بسبب الحفظ */ }
    }

    // ------------------------------------------------------------ floating button
    private fun attachFab(a: Activity) {
        val content = a.findViewById<ViewGroup>(android.R.id.content) ?: return
        if (content.findViewWithTag<View>("ai_fab") != null) return
        try {
            val d = a.resources.displayMetrics.density
            val st = AiChat.fabStyle(a)
            // FloatingActionButton من Material: يأخذ شكل وظلال وحركة التطبيق تلقائيا
            val fab = FloatingActionButton(a).apply {
                tag = "ai_fab"
                contentDescription = "مساعد الذكاء الاصطناعي"
                backgroundTintList = ColorStateList.valueOf(st[0])
                imageTintList = ColorStateList.valueOf(st[1])
                setImageDrawable(AiChat.icon(a, "ic_ai_sparkle"))
            }
            val lp = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.END
            ).apply {
                bottomMargin = (110 * d).toInt()
                marginEnd = (16 * d).toInt()
            }
            content.addView(fab, lp)

            // لو كاين FAB آخر ظاهر فالشاشة (مثل أزرار لوحة السجلات) نخبّيو الزر ديالنا باش ما يتداخلوش
            val check = Runnable {
                val hide = otherFabOnScreen(content, fab)
                val want = if (hide) View.GONE else View.VISIBLE
                if (fab.visibility != want) fab.visibility = want
            }
            content.viewTreeObserver.addOnGlobalLayoutListener {
                content.removeCallbacks(check)
                content.postDelayed(check, 120)
            }

            // سحب الزر + ضغطة قصيرة تفتح الشات + يلصق مع أقرب حافة
            var sx = 0f; var sy = 0f; var tx = 0f; var ty = 0f; var moved = false
            fab.setOnTouchListener { v, e ->
                when (e.action) {
                    MotionEvent.ACTION_DOWN -> {
                        sx = e.rawX; sy = e.rawY; tx = v.translationX; ty = v.translationY; moved = false
                        v.animate().scaleX(0.92f).scaleY(0.92f).setDuration(80).start()
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val mx = e.rawX - sx; val my = e.rawY - sy
                        if (abs(mx) > 12 * d || abs(my) > 12 * d) moved = true
                        if (moved) { v.translationX = tx + mx; v.translationY = ty + my }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                        if (!moved) {
                            AiChat.show(a)
                        } else {
                            val pw = content.width.toFloat()
                            val ph = content.height.toFloat()
                            val left = v.left.toFloat()
                            val top = v.top.toFloat()
                            val cx = left + v.translationX + v.width / 2f
                            val edge = 8 * d
                            val targetX = if (cx < pw / 2f) edge else pw - v.width - edge
                            val targetY = (top + v.translationY).coerceIn(edge, (ph - v.height - edge).coerceAtLeast(edge))
                            v.animate().translationX(targetX - left).translationY(targetY - top).setDuration(180).start()
                        }
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                        true
                    }
                    else -> false
                }
            }
        } catch (t: Throwable) { /* ما نكسرو شاشة المحرر إلا وقع مشكل فالـ theme */ }
    }

    private fun otherFabOnScreen(x: View, self: View): Boolean {
        if (x === self || x.visibility != View.VISIBLE) return false
        if (x.javaClass.name.contains("FloatingActionButton") && x.isShown && x.getGlobalVisibleRect(Rect())) return true
        if (x is ViewGroup) for (i in 0 until x.childCount) if (otherFabOnScreen(x.getChildAt(i), self)) return true
        return false
    }
}

KT_EOF

# ---------------------------------------------------------------- أيقونات vector + keep (للـ release)
RES="$APP/src/main/res"
mkdir -p "$RES/drawable" "$RES/raw"
mkicon() { # name pathData
  cat > "$RES/drawable/$1.xml" <<ICON_EOF
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF" android:pathData="$2"/>
</vector>
ICON_EOF
}
mkicon ic_ai_sparkle "M12,2l2.4,6.6L21,11l-6.6,2.4L12,20l-2.4,-6.6L3,11l6.6,-2.4zM19,16l0.9,2.1L22,19l-2.1,0.9L19,22l-0.9,-2.1L16,19l2.1,-0.9z"
mkicon ic_ai_send "M2.01,21L23,12L2.01,3L2,10l15,2l-15,2z"
mkicon ic_ai_stop "M7,7h10v10H7z"
mkicon ic_ai_close "M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12z"
mkicon ic_ai_more "M12,8c1.1,0 2,-0.9 2,-2s-0.9,-2 -2,-2s-2,0.9 -2,2s0.9,2 2,2zM12,10c-1.1,0 -2,0.9 -2,2s0.9,2 2,2s2,-0.9 2,-2s-0.9,-2 -2,-2zM12,16c-1.1,0 -2,0.9 -2,2s0.9,2 2,2s2,-0.9 2,-2s-0.9,-2 -2,-2z"
cat > "$RES/raw/ai_keep.xml" <<'KEEP_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:tools="http://schemas.android.com/tools"
    tools:keep="@drawable/ic_ai_*" />
KEEP_EOF

# ---------------------------------------------------------------- إزالة LeakCanary (تطبيق "Leaks")
echo "🧹 كنقلّب على LeakCanary..."
LC_USES="$(grep -rIl -i 'leakcanary' "$ROOT" --include='*.kt' --include='*.java' --include='*.xml' \
  --exclude-dir=build --exclude-dir=.git --exclude-dir=.gradle 2>/dev/null \
  | grep -v '/src/debug/res/values/leakcanary_config.xml' || true)"
LC_BLD="$(grep -rIl -i 'leakcanary' "$ROOT" --include='*.kts' --include='*.gradle' --include='*.toml' \
  --exclude-dir=build --exclude-dir=.git --exclude-dir=.gradle 2>/dev/null || true)"
if [ -z "$LC_USES" ] && [ -n "$LC_BLD" ]; then
  for f in $LC_BLD; do
    [ -f "$f.ai-bak" ] || cp "$f" "$f.ai-bak"
    sed -i '/leakcanary/Id' "$f"
    echo "🗑️  حيّدت LeakCanary من $f"
  done
else
  if [ -n "$LC_USES" ]; then
    echo "⚠️ LeakCanary مستعمل فالكود، غنخبّي الأيقونة فقط:"; echo "$LC_USES"
  fi
  LCD="$APP/src/debug/res/values"; mkdir -p "$LCD"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<resources>' \
    '    <bool name="leak_canary_add_launcher_icon">false</bool>' '</resources>' > "$LCD/leakcanary_config.xml"
fi

# ---------------------------------------------------------------- patch Application + Manifest
python3 - "$ROOT" "$NEW_APPID" <<'PY_EOF'
import re, sys, os, pathlib

root = pathlib.Path(sys.argv[1])
app_dir = pathlib.Path(os.environ["APP_DIR"])
src = app_dir / "src"
MARK = "com.itsaky.androidide.ai.AiPlugin"

# 1) Application class ------------------------------------------------------
cands = []
for p in src.rglob("*"):
    if p.suffix not in (".kt", ".java") or "/ai/" in str(p):
        continue
    t = p.read_text(errors="ignore")
    if re.search(r":\s*\w*Application\w*\s*\(\)|extends\s+\w*Application\b", t) and "onCreate" in t:
        cands.append((p, t))

cands.sort(key=lambda c: (0 if "IDEApplication" in c[0].name else 1, str(c[0])))
if not cands:
    print("⚠️  ما لقيتش كلاس Application. زيد هاد السطر يدويا فـ Application.onCreate():")
    print("    com.itsaky.androidide.ai.AiPlugin.install(this)")
else:
    p, t = cands[0]
    if MARK in t:
        print(f"ℹ️  {p.name} مبدّل من قبل")
    else:
        is_kt = p.suffix == ".kt"
        m = re.search(r"(override\s+fun\s+onCreate\s*\(\s*\)\s*\{|void\s+onCreate\s*\(\s*\)\s*\{)", t)
        if not m:
            print(f"⚠️  ما لقيتش onCreate() فـ {p}. زيد السطر يدويا.")
        else:
            sup = re.compile(r"super\.onCreate\(\)[ \t]*;?").search(t, m.end())
            pos = sup.end() if sup else m.end()
            snippet = (
                "\n        runCatching { com.itsaky.androidide.ai.AiPlugin.install(this) }"
                if is_kt else
                "\n        try { com.itsaky.androidide.ai.AiPlugin.install(this); } catch (Throwable ignored) {}"
            )
            (p.parent / (p.name + ".ai-bak")).write_text(t)
            p.write_text(t[:pos] + snippet + t[pos:])
            print(f"✅ بدّلت {p.relative_to(root)}")

# 3) applicationId (اختياري) -------------------------------------------------
new_id = sys.argv[2] if len(sys.argv) > 2 else ""
if new_id:
    for name in ("build.gradle.kts", "build.gradle"):
        g = app_dir / name
        if g.exists():
            t = g.read_text()
            m = re.search(r'applicationId\s*=?\s*["\']([^"\']+)["\']', t)
            if not m:
                print(f"⚠️  ما لقيتش applicationId فـ {name} (يمكن كيجي من BuildConfig/convention plugin)")
            else:
                (g.parent / (name + ".ai-bak")).write_text(t)
                t = t[:m.start(1)] + new_id + t[m.end(1):]
                g.write_text(t)
                print(f"✅ applicationId: {m.group(1)} → {new_id}")
            break

# 2) INTERNET permission -----------------------------------------------------
mf = src / "main" / "AndroidManifest.xml"
if mf.exists():
    t = mf.read_text()
    if "android.permission.INTERNET" in t:
        print("ℹ️  صلاحية INTERNET موجودة")
    else:
        (mf.parent / "AndroidManifest.xml.ai-bak").write_text(t)
        t = re.sub(r"(<manifest[^>]*>)",
                   r'\1\n    <uses-permission android:name="android.permission.INTERNET"/>', t, count=1)
        mf.write_text(t)
        print("✅ زدت صلاحية INTERNET")
PY_EOF

echo
echo "✅ تمّ الحقن. دابا بني التطبيق:"
rel="${APP#"$ROOT"/}"; GPATH=":${rel//\//:}"
echo "   cd $ROOT && ./gradlew ${GPATH}:assembleDebug"
echo "   (للتراجع: bash inject-ai.sh $ROOT undo)"
