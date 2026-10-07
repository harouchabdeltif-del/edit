#!/usr/bin/env bash
# inject-ai.sh — يحقن مساعد الذكاء الاصطناعي مباشرة داخل تطبيق AndroidIDE الرئيسي
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
    fun complete(p: AiPrefs, system: String, msgs: List<Msg>): String {
        require(p.apiKey.isNotBlank()) { "ضع مفتاح API من الإعدادات" }
        var last: ApiException? = null
        for (attempt in 0 until 3) {
            try {
                return when (p.provider) {
                    "claude" -> claude(p, system, msgs)
                    "gemini" -> gemini(p, system, msgs)
                    else -> openAiCompatible(p, system, msgs)
                }
            } catch (e: ApiException) {
                if (e.code != 429 && e.code < 500) throw e
                last = e
                if (attempt < 2) Thread.sleep(1500L * (attempt + 1))
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
            .put("max_tokens", 8192)
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
            c.readTimeout = 120_000
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

# ---------------------------------------------------------------- AiChat.kt
cat > "$PKG_DIR/AiChat.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
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
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import java.io.File

object AiChat {

    private val ui = Handler(Looper.getMainLooper())
    private var busy = false
    private var reqId = 0
    private var lastError: String? = null

    private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT

    // ------------------------------------------------------------------ theme
    private class Pal(val dark: Boolean) {
        val bg = if (dark) Color.parseColor("#1C1B22") else Color.WHITE
        val surface = if (dark) Color.parseColor("#2B2A33") else Color.parseColor("#F0EFF5")
        val text = if (dark) Color.parseColor("#ECEBF2") else Color.parseColor("#1B1A20")
        val sub = if (dark) Color.parseColor("#A09FAD") else Color.parseColor("#6C6B78")
        val accent = Color.parseColor("#6200EE")
        val danger = Color.parseColor("#C62828")
        val codeBg = Color.parseColor("#14141A")
        val codeText = Color.parseColor("#E4E4EE")
        val inlineBg = if (dark) Color.parseColor("#3A3946") else Color.parseColor("#E2E0EC")
    }

    private data class Seg(val isCode: Boolean, val text: String, val lang: String = "")

    private fun pal(a: Activity): Pal {
        val night = (a.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        return Pal(
            when (AiPrefs(a).theme) {
                "dark" -> true
                "light" -> false
                else -> night
            }
        )
    }

    // ------------------------------------------------------------------ view helpers
    private fun dp(a: Activity, v: Int) = (v * a.resources.displayMetrics.density).toInt()

    private fun shape(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color); cornerRadius = radius
    }

    private fun ripple(content: Drawable, radius: Float): Drawable =
        RippleDrawable(ColorStateList.valueOf(Color.argb(70, 150, 150, 160)), content, shape(Color.WHITE, radius))

    private fun button(
        a: Activity, label: String, fg: Int, bgc: Int, size: Float, padH: Int, padV: Int, onClick: () -> Unit
    ): TextView {
        val r = dp(a, 18).toFloat()
        return TextView(a).apply {
            text = label; textSize = size; gravity = Gravity.CENTER
            setTextColor(fg)
            setPadding(dp(a, padH), dp(a, padV), dp(a, padH), dp(a, padV))
            background = ripple(shape(bgc, r), r)
            isClickable = true; isFocusable = true
            setOnClickListener { onClick() }
        }
    }

    private fun pill(a: Activity, p: Pal, label: String, filled: Boolean = false, onClick: () -> Unit): TextView =
        button(a, label, if (filled) Color.WHITE else p.text, if (filled) p.accent else p.surface, 13f, 14, 8, onClick)

    private fun weight() = LinearLayout.LayoutParams(0, WRAP, 1f)

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

    // ------------------------------------------------------------------ chat
    fun show(a: Activity) {
        val prefs = AiPrefs(a)
        val p = pal(a)
        val dialog = Dialog(a)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)

        fun toast(s: String, long: Boolean = false) =
            Toast.makeText(a, s, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()

        fun copy(code: String) {
            try {
                val cm = a.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("code", code))
                toast("📋 تنسخ")
            } catch (t: Throwable) { toast("⚠️ ${t.message}", true) }
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
        val send = TextView(a).apply {
            gravity = Gravity.CENTER; textSize = 18f; setTextColor(Color.WHITE)
            background = ripple(shape(p.accent, dp(a, 22).toFloat()), dp(a, 22).toFloat())
            isClickable = true; isFocusable = true
        }
        fun updateSend() { send.text = if (busy) "■" else "➤" }

        // ---- تطبيق الكود على المحرر
        fun doInsert(code: String) {
            val ed = EditorAccess.find(a) ?: run { toast("ما كاين حتى ملف مفتوح"); return }
            try { ed.replaceSelection(code); toast("✅ تم (Undo فالمحرر)") }
            catch (t: Throwable) { toast("⚠️ ${t.message}", true) }
        }

        fun doReplace(code: String) {
            val ed = EditorAccess.find(a) ?: run { toast("ما كاين حتى ملف مفتوح"); return }
            val old = ed.allText()
            AlertDialog.Builder(a)
                .setTitle("استبدال الملف كامل؟")
                .setMessage("${old.lines().size} سطر ← ${code.lines().size} سطر\n(تقدر دير Undo فالمحرر)")
                .setPositiveButton("استبدل") { _, _ ->
                    try { ed.replaceAll(code); toast("✅ تم (Undo فالمحرر)") }
                    catch (t: Throwable) { toast("⚠️ ${t.message}", true) }
                }
                .setNegativeButton("إلغاء", null)
                .show()
        }

        // ---- عناصر الرسائل
        fun codeView(s: Seg): View {
            val box = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                background = shape(p.codeBg, dp(a, 10).toFloat())
                setPadding(dp(a, 8), dp(a, 6), dp(a, 8), dp(a, 8))
            }
            val bar = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            bar.addView(TextView(a).apply {
                text = s.lang.ifBlank { "code" }; setTextColor(Color.parseColor("#8A8A9A")); textSize = 11f
            }, weight())
            val tone = Color.parseColor("#2A2A34")
            fun mini(label: String, f: () -> Unit) {
                bar.addView(
                    button(a, label, p.codeText, tone, 11f, 10, 5, f),
                    LinearLayout.LayoutParams(WRAP, WRAP).apply { marginStart = dp(a, 4) }
                )
            }
            mini("📋 نسخ") { copy(s.text) }
            mini("📥 إدراج") { doInsert(s.text) }
            mini("📄 استبدال") { doReplace(s.text) }

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

        fun bubble(m: AiClient.Msg): View {
            val mine = m.role == "user"
            val col = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                background = shape(if (mine) p.accent else p.surface, dp(a, 16).toFloat())
                setPadding(dp(a, 12), dp(a, 8), dp(a, 12), dp(a, 8))
            }
            if (mine) {
                col.addView(TextView(a).apply {
                    text = m.content; setTextColor(Color.WHITE); textSize = 14f
                    setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_ANY_RTL
                })
            } else {
                for (s in parse(m.content)) {
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

        fun thinking(): View = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = shape(p.surface, dp(a, 16).toFloat())
            setPadding(dp(a, 14), dp(a, 10), dp(a, 14), dp(a, 10))
            addView(ProgressBar(a).apply {
                isIndeterminate = true; indeterminateTintList = ColorStateList.valueOf(p.accent)
            }, LinearLayout.LayoutParams(dp(a, 18), dp(a, 18)))
            addView(TextView(a).apply {
                text = "كنفكر…"; setTextColor(p.sub); textSize = 13f; setPadding(dp(a, 8), 0, 0, 0)
            })
            layoutParams = itemParams(true).apply { marginStart = 0; gravity = Gravity.START }
        }

        fun notice(text: String, color: Int): View = TextView(a).apply {
            this.text = text; setTextColor(color); textSize = 13f; gravity = Gravity.CENTER
            textDirection = View.TEXT_DIRECTION_ANY_RTL
            setPadding(dp(a, 12), dp(a, 24), dp(a, 12), dp(a, 24))
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        }

        fun render() {
            list.removeAllViews()
            if (AiPlugin.history.isEmpty() && !busy) {
                list.addView(notice("اكتب أمرك أو اختار اقتراح من لتحت 👇\nمثال: زيد زر تسجيل الدخول فهاد الملف", p.sub))
            }
            AiPlugin.history.forEach { list.addView(bubble(it)) }
            if (busy) list.addView(thinking())
            lastError?.let { e ->
                list.addView(TextView(a).apply {
                    text = "⚠️ $e"; setTextColor(Color.WHITE); textSize = 13f
                    setTextIsSelectable(true)
                    background = shape(p.danger, dp(a, 12).toFloat())
                    setPadding(dp(a, 12), dp(a, 8), dp(a, 12), dp(a, 8))
                    layoutParams = itemParams(false)
                })
            }
            scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        }

        // ---- الإرسال
        fun ask(prompt: String) {
            if (busy) return
            if (prefs.apiKey.isBlank()) { toast("ضع مفتاح API أولا", true); showSettings(a); return }
            lastError = null
            val ed = EditorAccess.find(a)
            val earlier = AiPlugin.history.takeLast(10)
            AiPlugin.history.add(AiClient.Msg("user", prompt))
            val req = earlier + AiClient.Msg("user", buildPrompt(prompt, ed))
            val system = buildSystem(ed)
            val my = ++reqId
            busy = true; updateSend(); render()
            Thread {
                var reply: String? = null
                var err: String? = null
                try { reply = AiClient.complete(prefs, system, req) } catch (t: Throwable) { err = t.message ?: t.javaClass.simpleName }
                ui.post {
                    if (my != reqId) return@post   // الطلب تلغى
                    busy = false; updateSend()
                    if (reply != null) {
                        AiPlugin.history.add(AiClient.Msg("assistant", reply))
                    } else {
                        if (AiPlugin.history.lastOrNull()?.role == "user") AiPlugin.history.removeAt(AiPlugin.history.lastIndex)
                        lastError = err
                    }
                    AiPlugin.save(a)
                    render()
                }
            }.start()
        }

        fun cancel() {
            reqId++; busy = false
            if (AiPlugin.history.lastOrNull()?.role == "user") AiPlugin.history.removeAt(AiPlugin.history.lastIndex)
            AiPlugin.save(a)
            updateSend(); render()
        }

        // ---- الهيدر
        val header = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val titles = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        titles.addView(TextView(a).apply {
            text = "✨ مساعد الذكاء الاصطناعي"; setTextColor(p.text); textSize = 16f; typeface = Typeface.DEFAULT_BOLD
        })
        titles.addView(TextView(a).apply {
            text = prefs.provider + " · " + prefs.effectiveModel().ifBlank { "—" }
            setTextColor(p.sub); textSize = 11f; setSingleLine(); textDirection = View.TEXT_DIRECTION_LTR
        })
        header.addView(titles, weight())
        header.addView(pill(a, p, "⚙️") { showSettings(a) })
        header.addView(pill(a, p, "🗑") {
            cancel(); AiPlugin.history.clear(); lastError = null; AiPlugin.save(a); render()
        }, LinearLayout.LayoutParams(WRAP, WRAP).apply { marginStart = dp(a, 4) })
        header.addView(pill(a, p, "✖") { dialog.dismiss() },
            LinearLayout.LayoutParams(WRAP, WRAP).apply { marginStart = dp(a, 4) })

        // ---- اقتراحات سريعة
        val chipsRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        fun chip(label: String, onClick: () -> Unit) {
            chipsRow.addView(pill(a, p, label) { onClick() },
                LinearLayout.LayoutParams(WRAP, WRAP).apply { marginEnd = dp(a, 6) })
        }
        chip("🛠 أصلح الملف") {
            ask("أصلح الأخطاء فهاد الملف وعطيني الملف كامل مصحّح فبلوك كود واحد، مع شرح قصير للأخطاء.")
        }
        chip("📖 اشرح الملف") { ask("اشرح ليا هاد الملف باختصار.") }
        chip("🔎 اشرح التحديد") { ask("اشرح ليا الجزء المحدد فقط (Selected text) بالتفصيل.") }
        chip("♻️ حسّن الكود") {
            ask("حسّن جودة وقراءة الكود (التحديد إن وُجد، وإلا الملف) بلا ما تبدّل السلوك، وعطيني النتيجة فبلوك كود واحد.")
        }
        chip("🧪 اختبارات") { ask("كتب ليا اختبارات (unit tests) مناسبة للكود المحدد أو للملف الحالي.") }
        chip("📝 تعليقات") { ask("زيد تعليقات وتوثيق KDoc/Javadoc واضح للكود، وعطيني الملف كامل فبلوك كود واحد.") }
        chip("🩺 حلّل خطأ من الحافظة") {
            val c = clip()
            if (c == null) toast("الحافظة فارغة — انسخ اللوغ أولا")
            else ask("حلّل هاد الخطأ/اللوغ وقلّي السبب والحل:\n```\n${c.take(6000)}\n```")
        }
        val chips = HorizontalScrollView(a).apply {
            addView(chipsRow); isHorizontalScrollBarEnabled = false
        }

        // ---- الإدخال
        val input = EditText(a).apply {
            hint = "اكتب أمرك…"; setTextColor(p.text); setHintTextColor(p.sub)
            background = shape(p.surface, dp(a, 22).toFloat())
            setPadding(dp(a, 14), dp(a, 10), dp(a, 14), dp(a, 10))
            maxLines = 4
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        }
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
            setPadding(dp(a, 12), dp(a, 12), dp(a, 12), dp(a, 12))
            background = shape(p.bg, dp(a, 20).toFloat())
        }
        root.addView(header)
        root.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f).apply { topMargin = dp(a, 8) })
        root.addView(chips, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(a, 6); bottomMargin = dp(a, 8) })
        root.addView(inputRow)

        updateSend(); render()
        dialog.setContentView(root)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        dialog.show()
        dialog.window?.setLayout(
            (a.resources.displayMetrics.widthPixels * 0.95).toInt(),
            (a.resources.displayMetrics.heightPixels * 0.88).toInt()
        )
    }

    // -------------------------------------------------------------- settings
    fun showSettings(a: Activity) {
        val prefs = AiPrefs(a)
        val p = pal(a)
        val dialog = Dialog(a)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)

        fun label(t: String) = TextView(a).apply {
            text = t; setTextColor(p.sub); textSize = 12f; setPadding(0, dp(a, 12), 0, dp(a, 4))
        }
        fun field(h: String, v: String, pass: Boolean = false) = EditText(a).apply {
            hint = h; setText(v); setTextColor(p.text); setHintTextColor(p.sub); setSingleLine()
            background = shape(p.surface, dp(a, 10).toFloat())
            setPadding(dp(a, 12), dp(a, 10), dp(a, 12), dp(a, 10))
            inputType = if (pass) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_TEXT
        }

        val provider = spinner(a, p, AiPrefs.PROVIDERS, prefs.provider)
        val model = field("فارغ = الموديل الافتراضي", prefs.model)
        val key = field("API Key", prefs.apiKey, pass = true)
        val base = field("اختياري (ضروري مع custom)", prefs.baseUrl)
        val theme = spinner(a, p, AiPrefs.THEMES, prefs.theme)

        fun save() {
            prefs.provider = provider.selectedItem.toString()
            prefs.model = model.text.toString().trim()
            prefs.apiKey = key.text.toString().trim()
            prefs.baseUrl = base.text.toString().trim()
            prefs.theme = theme.selectedItem.toString()
        }

        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 16), dp(a, 16), dp(a, 16), dp(a, 16))
            background = shape(p.bg, dp(a, 20).toFloat())
        }
        box.addView(TextView(a).apply {
            text = "⚙️ إعدادات AI"; setTextColor(p.text); textSize = 16f; typeface = Typeface.DEFAULT_BOLD
        })
        box.addView(label("المزوّد")); box.addView(provider)
        box.addView(label("الموديل")); box.addView(model)
        box.addView(label("API Key (كيتخزّن محليا فجهازك فقط)")); box.addView(key)
        box.addView(label("Base URL")); box.addView(base)
        box.addView(label("المظهر")); box.addView(theme)

        val row = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(pill(a, p, "🔌 اختبار") {
            save()
            Toast.makeText(a, "⏳ كنجرب الاتصال…", Toast.LENGTH_SHORT).show()
            Thread {
                val msg = try { AiClient.ping(prefs); "✅ الاتصال شغال" }
                catch (t: Throwable) { "⚠️ ${t.message ?: t.javaClass.simpleName}" }
                a.runOnUiThread { Toast.makeText(a, msg, Toast.LENGTH_LONG).show() }
            }.start()
        }, LinearLayout.LayoutParams(0, WRAP, 1f).apply { marginEnd = dp(a, 8) })
        row.addView(pill(a, p, "💾 حفظ", filled = true) {
            save()
            Toast.makeText(a, "تم الحفظ", Toast.LENGTH_SHORT).show()
            dialog.dismiss()
        }, weight())
        box.addView(row, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(a, 16) })

        dialog.setContentView(ScrollView(a).apply { addView(box) })
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.show()
        dialog.window?.setLayout((a.resources.displayMetrics.widthPixels * 0.92).toInt(), WRAP)
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
                if (all.length > 12000) appendLine("(الملف طويل: تم اقتطاع الجزء الأخير)")
            }
        }
    }

    private fun buildSystem(ed: EditorAccess?): String = buildString {
        appendLine("You are an AI coding assistant embedded inside AndroidIDE (an Android IDE running on Android).")
        appendLine("Reply in the same language the user writes in. Be concise.")
        appendLine("When you output code, give the COMPLETE ready-to-insert code inside ONE fenced code block.")
        appendLine("If the user asks to change only the selected text, return only the replacement for that selection. If the user asks to change the file, return the complete updated file.")
        appendLine("Do not invent files or APIs that are not in the project; if context is missing, say so.")
        val root = projectRoot(ed?.file())
        if (root != null) {
            appendLine("\n## Project: ${root.name}")
            val lines = mutableListOf<String>()
            tree(root, root, 0, lines)
            lines.forEach { appendLine("- $it") }
        }
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
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/** نقطة الدخول: كتتسجل مرة وحدة من Application.onCreate وكتحط زر AI عائم فشاشة المحرر. */
object AiPlugin {

    private const val MAX_HISTORY = 40

    @Volatile private var installed = false
    val history = mutableListOf<AiClient.Msg>()

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
        val d = a.resources.displayMetrics.density
        val fab = TextView(a).apply {
            tag = "ai_fab"; text = "AI"; setTextColor(Color.WHITE); textSize = 15f
            typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; elevation = 10 * d
            alpha = 0.92f
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor("#8E5CFF"), Color.parseColor("#6200EE"))
            ).apply { shape = GradientDrawable.OVAL }
        }
        val size = (54 * d).toInt()
        val lp = FrameLayout.LayoutParams(size, size, Gravity.BOTTOM or Gravity.END)
            .apply { setMargins(0, 0, (16 * d).toInt(), (110 * d).toInt()) }
        content.addView(fab, lp)

        // سحب الزر + ضغطة قصيرة تفتح الشات + يلصق مع أقرب حافة
        var sx = 0f; var sy = 0f; var tx = 0f; var ty = 0f; var moved = false
        fab.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    sx = e.rawX; sy = e.rawY; tx = v.translationX; ty = v.translationY; moved = false
                    v.animate().scaleX(0.9f).scaleY(0.9f).setDuration(80).start()
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
    }
}
KT_EOF

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
