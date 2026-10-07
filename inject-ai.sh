#!/usr/bin/env bash
# inject-ai.sh — يحقن مساعد الذكاء الاصطناعي مباشرة داخل تطبيق AndroidIDE الرئيسي
# الاستخدام:   bash inject-ai.sh /path/to/AndroidIDE
# مع pkg جديد: bash inject-ai.sh /path/to/AndroidIDE inject com.mycompany.androidide.ai
# للتراجع:     bash inject-ai.sh /path/to/AndroidIDE undo
set -euo pipefail

ROOT="${1:-.}"
ACTION="${2:-inject}"
NEW_APPID="${3:-}"   # اختياري: applicationId جديد باش ما يتضاربش مع التطبيق الأصلي
APP="$ROOT/app"
PKG_DIR="$APP/src/main/java/com/itsaky/androidide/ai"

[ -d "$APP/src/main" ] || { echo "❌ ما لقيتش app/src/main فـ: $ROOT"; exit 1; }

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

    fun complete(p: AiPrefs, system: String, msgs: List<Msg>): String {
        require(p.apiKey.isNotBlank()) { "ضع مفتاح API من الإعدادات" }
        return when (p.provider) {
            "claude" -> claude(p, system, msgs)
            "gemini" -> gemini(p, system, msgs)
            else -> openAiCompatible(p, system, msgs)
        }
    }

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
        return res.getJSONArray("choices").getJSONObject(0).getJSONObject("message").optString("content")
    }

    private fun claude(p: AiPrefs, system: String, msgs: List<Msg>): String {
        val base = p.baseUrl.ifBlank { "https://api.anthropic.com" }.trimEnd('/')
        val arr = JSONArray()
        msgs.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
        val body = JSONObject()
            .put("model", p.effectiveModel())
            .put("max_tokens", 4096)
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

    private fun post(url: String, headers: Map<String, String>, body: JSONObject): String {
        val c = URL(url).openConnection() as HttpURLConnection
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
        if (code !in 200..299) throw RuntimeException("HTTP $code: ${text.take(400)}")
        return text
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
import android.app.Dialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import java.io.File

object AiChat {

    private val ui = Handler(Looper.getMainLooper())
    private var busy = false

    private fun dp(a: Activity, v: Int) = (v * a.resources.displayMetrics.density).toInt()

    private fun bg(a: Activity, color: String, r: Int = 12) = GradientDrawable().apply {
        setColor(Color.parseColor(color)); cornerRadius = dp(a, r).toFloat()
    }

    private fun btn(a: Activity, label: String, onClick: () -> Unit) = Button(a).apply {
        text = label; isAllCaps = false; textSize = 12f; minHeight = 0; minimumHeight = 0
        setOnClickListener { onClick() }
    }

    private fun weight() = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)

    // ------------------------------------------------------------------ chat
    fun show(a: Activity) {
        val prefs = AiPrefs(a)
        val dialog = Dialog(a)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)

        val root = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 12), dp(a, 12), dp(a, 12), dp(a, 12))
            background = bg(a, "#FFFFFF", 16)
        }

        val out = TextView(a).apply {
            setTextColor(Color.BLACK); textSize = 14f; setTextIsSelectable(true)
            textDirection = View.TEXT_DIRECTION_ANY_RTL
            setPadding(dp(a, 6), dp(a, 6), dp(a, 6), dp(a, 6))
        }
        val scroll = ScrollView(a).apply { addView(out) }

        fun render() {
            out.text = if (AiPlugin.history.isEmpty()) "اكتب أمرك، مثلا: زيد زر تسجيل الدخول فهاد الملف"
            else AiPlugin.history.joinToString("\n\n") { (if (it.role == "user") "👤 " else "🤖 ") + it.content }
            scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        }

        val header = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        header.addView(TextView(a).apply {
            text = "🤖 مساعد الذكاء الاصطناعي"; setTextColor(Color.BLACK); textSize = 16f; typeface = Typeface.DEFAULT_BOLD
        }, weight())
        header.addView(btn(a, "⚙️") { showSettings(a) })
        header.addView(btn(a, "🗑") { AiPlugin.history.clear(); render() })
        header.addView(btn(a, "✖") { dialog.dismiss() })

        val input = EditText(a).apply {
            hint = "اكتب أمرك…"; setTextColor(Color.BLACK); setHintTextColor(Color.GRAY)
            background = bg(a, "#EEEEEE", 10)
            setPadding(dp(a, 10), dp(a, 8), dp(a, 10), dp(a, 8))
            maxLines = 4
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        }
        val send = btn(a, "🚀 إرسال") {}

        fun lastCode(): String? {
            val r = AiPlugin.history.lastOrNull { it.role == "assistant" }?.content ?: return null
            return Regex("```[A-Za-z0-9_+-]*\\n([\\s\\S]*?)```").find(r)?.groupValues?.get(1)?.trimEnd()
        }

        fun ask(prompt: String) {
            if (busy) return
            if (prefs.apiKey.isBlank()) {
                Toast.makeText(a, "ضع مفتاح API أولا", Toast.LENGTH_LONG).show(); showSettings(a); return
            }
            val ed = EditorAccess.find(a)
            val earlier = AiPlugin.history.takeLast(10)
            AiPlugin.history.add(AiClient.Msg("user", prompt))
            val req = earlier + AiClient.Msg("user", buildPrompt(prompt, ed))
            val system = buildSystem(ed)
            busy = true; send.isEnabled = false
            render(); out.append("\n\n⏳ كنفكر…")
            Thread {
                var reply: String? = null
                var err: String? = null
                try { reply = AiClient.complete(prefs, system, req) } catch (t: Throwable) { err = t.message ?: t.javaClass.simpleName }
                ui.post {
                    busy = false; send.isEnabled = true
                    if (reply != null) AiPlugin.history.add(AiClient.Msg("assistant", reply))
                    else {
                        AiPlugin.history.removeAt(AiPlugin.history.lastIndex)
                        Toast.makeText(a, "⚠️ $err", Toast.LENGTH_LONG).show()
                    }
                    render()
                }
            }.start()
        }

        send.setOnClickListener {
            val t = input.text.toString().trim()
            if (t.isNotEmpty()) { input.text.clear(); ask(t) }
        }

        fun apply(whole: Boolean) {
            val code = lastCode() ?: run { Toast.makeText(a, "ما كاين حتى بلوك كود فآخر رد", Toast.LENGTH_SHORT).show(); return }
            val ed = EditorAccess.find(a) ?: run { Toast.makeText(a, "ما كاين حتى ملف مفتوح", Toast.LENGTH_SHORT).show(); return }
            try {
                if (whole) ed.replaceAll(code) else ed.replaceSelection(code)
                Toast.makeText(a, "✅ تم (تقدر دير Undo فالمحرر)", Toast.LENGTH_SHORT).show()
            } catch (t: Throwable) {
                Toast.makeText(a, "⚠️ ${t.message}", Toast.LENGTH_LONG).show()
            }
        }

        val row1 = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        row1.addView(btn(a, "📥 إدراج بالمؤشر") { apply(false) }, weight())
        row1.addView(btn(a, "📄 استبدال الملف") { apply(true) }, weight())
        val row2 = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        row2.addView(btn(a, "🛠 أصلح الملف") {
            ask("أصلح الأخطاء فهاد الملف وعطيني الملف كامل مصحّح فبلوك كود واحد، مع شرح قصير للأخطاء.")
        }, weight())
        row2.addView(btn(a, "📖 اشرح الملف") { ask("اشرح ليا هاد الملف باختصار.") }, weight())

        root.addView(header)
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(input)
        root.addView(send)
        root.addView(row1)
        root.addView(row2)

        render()
        dialog.setContentView(root)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        dialog.show()
        dialog.window?.setLayout(
            (a.resources.displayMetrics.widthPixels * 0.95).toInt(),
            (a.resources.displayMetrics.heightPixels * 0.85).toInt()
        )
    }

    // -------------------------------------------------------------- settings
    fun showSettings(a: Activity) {
        val prefs = AiPrefs(a)
        val dialog = Dialog(a)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)

        fun label(t: String) = TextView(a).apply { text = t; setTextColor(Color.BLACK); setPadding(0, dp(a, 10), 0, 0) }
        fun field(h: String, v: String, pass: Boolean = false) = EditText(a).apply {
            hint = h; setText(v); setTextColor(Color.BLACK); setHintTextColor(Color.GRAY); setSingleLine()
            inputType = if (pass) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_TEXT
        }

        val adapter = object : ArrayAdapter<String>(a, android.R.layout.simple_spinner_dropdown_item, AiPrefs.PROVIDERS) {
            override fun getView(p: Int, c: View?, g: ViewGroup): View =
                (super.getView(p, c, g) as TextView).apply { setTextColor(Color.BLACK) }
            override fun getDropDownView(p: Int, c: View?, g: ViewGroup): View =
                (super.getDropDownView(p, c, g) as TextView).apply { setTextColor(Color.BLACK); setBackgroundColor(Color.WHITE) }
        }
        val provider = Spinner(a).apply {
            this.adapter = adapter
            setSelection(AiPrefs.PROVIDERS.indexOf(prefs.provider).coerceAtLeast(0))
        }
        val model = field("فارغ = الموديل الافتراضي", prefs.model)
        val key = field("API Key", prefs.apiKey, pass = true)
        val base = field("اختياري (ضروري مع custom)", prefs.baseUrl)

        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 16), dp(a, 16), dp(a, 16), dp(a, 16))
            background = bg(a, "#FFFFFF", 16)
        }
        box.addView(TextView(a).apply { text = "⚙️ إعدادات AI"; setTextColor(Color.BLACK); textSize = 16f; typeface = Typeface.DEFAULT_BOLD })
        box.addView(label("المزوّد")); box.addView(provider)
        box.addView(label("الموديل")); box.addView(model)
        box.addView(label("API Key")); box.addView(key)
        box.addView(label("Base URL")); box.addView(base)
        box.addView(btn(a, "💾 حفظ") {
            prefs.provider = provider.selectedItem.toString()
            prefs.model = model.text.toString().trim()
            prefs.apiKey = key.text.toString().trim()
            prefs.baseUrl = base.text.toString().trim()
            Toast.makeText(a, "تم الحفظ", Toast.LENGTH_SHORT).show()
            dialog.dismiss()
        })

        dialog.setContentView(ScrollView(a).apply { addView(box) })
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.show()
        dialog.window?.setLayout((a.resources.displayMetrics.widthPixels * 0.92).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    // --------------------------------------------------------------- context
    private fun buildPrompt(p: String, ed: EditorAccess?): String = buildString {
        appendLine(p)
        if (ed != null) {
            ed.file()?.let { appendLine("\n## Current file: ${it.path}") }
            ed.selection()?.let { appendLine("\n## Selected text:\n```\n${it.take(4000)}\n```") }
            val all = ed.allText()
            if (all.isNotBlank()) appendLine("\n## Full current file:\n```\n${all.take(12000)}\n```")
        }
    }

    private fun buildSystem(ed: EditorAccess?): String = buildString {
        appendLine("You are an AI coding assistant embedded inside AndroidIDE (an Android IDE running on Android).")
        appendLine("Reply in the same language the user writes in. Be concise.")
        appendLine("When you output code, give the COMPLETE ready-to-insert code inside ONE fenced code block.")
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

    private val skip = setOf("build", ".gradle", ".git", ".idea", ".cxx", "node_modules")

    private fun tree(root: File, dir: File, depth: Int, out: MutableList<String>) {
        if (depth > 6 || out.size >= 100) return
        dir.listFiles()?.sortedBy { it.name }?.forEach { f ->
            if (out.size >= 100 || f.name in skip) return@forEach
            if (f.isDirectory) tree(root, f, depth + 1, out) else out.add(f.relativeTo(root).path)
        }
    }
}
KT_EOF

# ---------------------------------------------------------------- AiPlugin.kt
cat > "$PKG_DIR/AiPlugin.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import android.app.Activity
import android.app.Application
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
import kotlin.math.abs

/** نقطة الدخول: كتتسجل مرة وحدة من Application.onCreate وكتحط زر AI عائم فشاشة المحرر. */
object AiPlugin {

    @Volatile private var installed = false
    val history = mutableListOf<AiClient.Msg>()

    @JvmStatic
    fun install(app: Application) {
        if (installed) return
        installed = true
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

    private fun attachFab(a: Activity) {
        val content = a.findViewById<ViewGroup>(android.R.id.content) ?: return
        if (content.findViewWithTag<View>("ai_fab") != null) return
        val d = a.resources.displayMetrics.density
        val fab = TextView(a).apply {
            tag = "ai_fab"; text = "AI"; setTextColor(Color.WHITE); textSize = 15f
            typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; elevation = 8 * d
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.parseColor("#6200EE")) }
        }
        val size = (52 * d).toInt()
        val lp = FrameLayout.LayoutParams(size, size, Gravity.BOTTOM or Gravity.END)
            .apply { setMargins(0, 0, (16 * d).toInt(), (110 * d).toInt()) }
        content.addView(fab, lp)

        // سحب الزر + ضغطة قصيرة تفتح الشات
        var sx = 0f; var sy = 0f; var tx = 0f; var ty = 0f; var moved = false
        fab.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> { sx = e.rawX; sy = e.rawY; tx = v.translationX; ty = v.translationY; moved = false; true }
                MotionEvent.ACTION_MOVE -> {
                    val mx = e.rawX - sx; val my = e.rawY - sy
                    if (abs(mx) > 12 * d || abs(my) > 12 * d) moved = true
                    if (moved) { v.translationX = tx + mx; v.translationY = ty + my }
                    true
                }
                MotionEvent.ACTION_UP -> { if (!moved) AiChat.show(a); true }
                else -> false
            }
        }
    }
}
KT_EOF

# ---------------------------------------------------------------- patch Application + Manifest
python3 - "$ROOT" "$NEW_APPID" <<'PY_EOF'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
src = root / "app" / "src"
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
        g = root / "app" / name
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
echo "   cd $ROOT && ./gradlew :app:assembleDebug"
echo "   (للتراجع: bash inject-ai.sh $ROOT undo)"
