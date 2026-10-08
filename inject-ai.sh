#!/usr/bin/env bash
# inject-ai.sh — يحقن وكيل الذكاء الاصطناعي (Agent) مباشرة داخل تطبيق AndroidIDE الرئيسي
# v3: كل المزوّدين بالمفتاح فقط + جلب الموديلات + Custom كامل + سكرول مصلّح + وكيل ينفّذ مباشرة + واجهة جديدة
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

/**
 * الإعدادات. المفتاح والموديل والعنوان كيتخزنوا لكل مزوّد على حدة،
 * وبالتالي تبديل المزوّد ما كيضيّع حتى مفتاح.
 */
class AiPrefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("ai_assistant", Context.MODE_PRIVATE)

    init { migrate() }

    /** ترحيل الإعدادات القديمة (مفتاح واحد) إلى النظام الجديد (مفتاح لكل مزوّد). */
    private fun migrate() {
        if (sp.getBoolean("migrated_v2", false)) return
        val e = sp.edit()
        if (sp.contains("api_key")) {
            val pr = sp.getString("provider", "openrouter") ?: "openrouter"
            e.putString("key_$pr", sp.getString("api_key", "") ?: "")
            e.putString("model_$pr", sp.getString("model", "") ?: "")
            e.putString("base_$pr", sp.getString("base_url", "") ?: "")
        }
        e.putBoolean("migrated_v2", true).apply()
    }

    private fun str(k: String): String = sp.getString(k, "") ?: ""
    private fun put(k: String, v: String) { sp.edit().putString(k, v).apply() }

    var provider: String
        get() = sp.getString("provider", "openrouter") ?: "openrouter"
        set(v) { put("provider", v) }

    // ---- قيم خاصة بكل مزوّد
    fun keyFor(id: String): String = str("key_$id")
    fun setKeyFor(id: String, v: String) = put("key_$id", v)
    fun modelFor(id: String): String = str("model_$id")
    fun setModelFor(id: String, v: String) = put("model_$id", v)
    fun baseFor(id: String): String = str("base_$id")
    fun setBaseFor(id: String, v: String) = put("base_$id", v)

    // ---- قيم المزوّد الحالي
    var model: String
        get() = modelFor(provider)
        set(v) { setModelFor(provider, v) }

    var apiKey: String
        get() = keyFor(provider)
        set(v) { setKeyFor(provider, v) }

    var baseUrl: String
        get() = baseFor(provider)
        set(v) { setBaseFor(provider, v) }

    // ---- إعدادات المزوّد المخصص (custom)
    var customName: String
        get() = str("custom_name")
        set(v) { put("custom_name", v) }

    /** openai | anthropic | gemini */
    var customFormat: String
        get() = str("custom_format").ifBlank { "openai" }
        set(v) { put("custom_format", v) }

    /** اسم الـ header ديال المفتاح (فارغ = الافتراضي حسب الصيغة). */
    var customAuthHeader: String
        get() = str("custom_auth_header")
        set(v) { put("custom_auth_header", v) }

    var customAuthPrefix: String
        get() = str("custom_auth_prefix")
        set(v) { put("custom_auth_prefix", v) }

    /** headers إضافية: سطر لكل header بالشكل  Name: value */
    var customHeaders: String
        get() = str("custom_headers")
        set(v) { put("custom_headers", v) }

    /** مسار الدردشة (فارغ = الافتراضي حسب الصيغة). يقبل {model} فالـ gemini. */
    var customChatPath: String
        get() = str("custom_chat_path")
        set(v) { put("custom_chat_path", v) }

    /** auto | light | dark */
    var theme: String
        get() = sp.getString("theme", "auto") ?: "auto"
        set(v) { put("theme", v) }

    /** سجل المحادثة (JSON) باش يبقى حتى بعد إغلاق التطبيق. */
    var history: String
        get() = str("history")
        set(v) { put("history", v) }

    /** true = يطلب تأكيدا قبل كل كتابة/تعديل. الحذف وتنفيذ الأوامر دائما يطلبان تأكيدا. */
    var askBeforeEdit: Boolean
        get() = sp.getBoolean("ask_before_edit", false)
        set(v) { sp.edit().putBoolean("ask_before_edit", v).apply() }

    /** مجلد العمل (فارغ = مجلد المشروع المفتوح، وإلا AndroidIDEProjects). */
    var workspace: String
        get() = str("workspace")
        set(v) { put("workspace", v) }

    fun needsKey(): Boolean = AiProviders.get(provider)?.needsKey ?: true

    fun ready(): Boolean = apiKey.isNotBlank() || !needsKey()

    fun effectiveModel(): String = model.ifBlank { AiProviders.get(provider)?.model.orEmpty() }

    fun providerLabel(): String =
        if (provider == "custom") customName.ifBlank { "Custom" }
        else AiProviders.get(provider)?.label?.substringBefore(" (")?.substringBefore(" —") ?: provider

    companion object {
        val THEMES = listOf("auto", "light", "dark")
    }
}
KT_EOF

# ---------------------------------------------------------------- AiProviders.kt
cat > "$PKG_DIR/AiProviders.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

/**
 * سجل المزوّدين. لكل مزوّد: صيغة الـ API + العنوان الجاهز، والمستعمل يدخل المفتاح فقط.
 * أي مزوّد غير موجود هنا يمكن إضافته عبر "custom" (عنوان + صيغة + headers).
 */
object AiProviders {

    /** format = openai (متوافق مع OpenAI) | anthropic | gemini */
    class Provider(
        val id: String,
        val label: String,
        val format: String,
        val base: String,
        val model: String = "",
        val needsKey: Boolean = true,
        /** لائحة احتياطية لما ما يكونش عند المزوّد endpoint لجلب الموديلات. */
        val fallback: List<String> = emptyList()
    )

    val ALL: List<Provider> = listOf(
        Provider("openrouter", "OpenRouter (مئات الموديلات)", "openai", "https://openrouter.ai/api/v1", "openrouter/auto"),
        Provider("openai", "OpenAI (GPT)", "openai", "https://api.openai.com/v1", "gpt-4o-mini"),
        Provider("claude", "Anthropic (Claude)", "anthropic", "https://api.anthropic.com", "claude-sonnet-5-5"),
        Provider("gemini", "Google (Gemini)", "gemini", "https://generativelanguage.googleapis.com", "gemini-2.5-pro"),
        Provider("deepseek", "DeepSeek", "openai", "https://api.deepseek.com/v1", "deepseek-chat"),
        Provider("groq", "Groq", "openai", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile"),
        Provider("xai", "xAI (Grok)", "openai", "https://api.x.ai/v1"),
        Provider("mistral", "Mistral", "openai", "https://api.mistral.ai/v1", "mistral-large-latest"),
        Provider("together", "Together AI", "openai", "https://api.together.xyz/v1"),
        Provider("fireworks", "Fireworks AI", "openai", "https://api.fireworks.ai/inference/v1"),
        Provider("deepinfra", "DeepInfra", "openai", "https://api.deepinfra.com/v1/openai"),
        Provider("hyperbolic", "Hyperbolic", "openai", "https://api.hyperbolic.xyz/v1"),
        Provider("cerebras", "Cerebras", "openai", "https://api.cerebras.ai/v1"),
        Provider("sambanova", "SambaNova", "openai", "https://api.sambanova.ai/v1"),
        Provider("nvidia", "NVIDIA NIM", "openai", "https://integrate.api.nvidia.com/v1"),
        Provider("huggingface", "Hugging Face", "openai", "https://router.huggingface.co/v1"),
        Provider("moonshot", "Moonshot (Kimi)", "openai", "https://api.moonshot.ai/v1"),
        Provider("zai", "Z.AI (GLM)", "openai", "https://api.z.ai/api/paas/v4"),
        Provider("qwen", "Alibaba Qwen (DashScope)", "openai", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        Provider("siliconflow", "SiliconFlow", "openai", "https://api.siliconflow.com/v1"),
        Provider("cohere", "Cohere", "openai", "https://api.cohere.ai/compatibility/v1"),
        Provider(
            "perplexity", "Perplexity", "openai", "https://api.perplexity.ai", "sonar",
            fallback = listOf("sonar", "sonar-pro", "sonar-reasoning", "sonar-reasoning-pro", "sonar-deep-research")
        ),
        Provider("ollama", "Ollama (محلي — بلا مفتاح)", "openai", "http://127.0.0.1:11434/v1", needsKey = false),
        Provider("lmstudio", "LM Studio (محلي — بلا مفتاح)", "openai", "http://127.0.0.1:1234/v1", needsKey = false),
        Provider("custom", "Custom — أي مزوّد آخر", "openai", "", needsKey = false)
    )

    fun get(id: String): Provider? = ALL.firstOrNull { it.id == id }

    fun ids(): List<String> = ALL.map { it.id }
}
KT_EOF

# ---------------------------------------------------------------- AiClient.kt
cat > "$PKG_DIR/AiClient.kt" <<'KT_EOF'
package com.itsaky.androidide.ai

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * عميل HTTP بسيط بلا أي مكتبة خارجية.
 * 3 صيغ: openai (يغطي OpenRouter/OpenAI/Groq/DeepSeek/... وأي خدمة متوافقة) + anthropic + gemini.
 * كذلك كيجلب لائحة الموديلات ديال أي مزوّد بالمفتاح فقط.
 */
object AiClient {

    data class Msg(val role: String, val content: String) // role = "user" | "assistant"

    class ApiException(val code: Int, message: String) : RuntimeException(message)

    private const val NO_NATIVE =
        "\n\nIMPORTANT: Do NOT use native function/tool calling of the API (no browser, no functions, no python). " +
        "Tools exist ONLY as plain-text <tool .../> tags written inside your normal reply."

    /** وجهة الطلب بعد حلّ المزوّد والإعدادات. */
    private class Endpoint(val format: String, val base: String, val chatPath: String, val headers: Map<String, String>)

    private fun endpoint(p: AiPrefs): Endpoint {
        val prov = AiProviders.get(p.provider)
        val custom = p.provider == "custom"
        val format = if (custom) p.customFormat else (prov?.format ?: "openai")
        val base = p.baseUrl.ifBlank { prov?.base.orEmpty() }.trim().trimEnd('/')
        if (base.isBlank()) throw IllegalStateException("خاصك تدخل Base URL فالإعدادات")

        val h = LinkedHashMap<String, String>()
        val key = p.apiKey
        val defHeader = when (format) {
            "anthropic" -> "x-api-key"
            "gemini" -> "x-goog-api-key"
            else -> "Authorization"
        }
        val defPrefix = if (format == "openai") "Bearer " else ""
        val own = custom && p.customAuthHeader.isNotBlank()
        val header = if (own) p.customAuthHeader.trim() else defHeader
        var prefix = if (own) p.customAuthPrefix else defPrefix
        if (prefix.isNotEmpty() && prefix.last().isLetterOrDigit()) prefix += " "
        if (key.isNotBlank()) h[header] = prefix + key
        if (format == "anthropic" && !h.containsKey("anthropic-version")) h["anthropic-version"] = "2023-06-01"
        if (custom) {
            p.customHeaders.lines().forEach { l ->
                val i = l.indexOf(':')
                if (i > 0) {
                    val k = l.substring(0, i).trim()
                    val v = l.substring(i + 1).trim()
                    if (k.isNotEmpty()) h[k] = v
                }
            }
        }
        val path = if (custom && p.customChatPath.isNotBlank()) "/" + p.customChatPath.trim().trimStart('/') else ""
        return Endpoint(format, base, path, h)
    }

    private fun geminiRoot(e: Endpoint): String =
        if (e.base.endsWith("/v1beta") || e.base.endsWith("/v1")) e.base else e.base + "/v1beta"

    private fun chatUrl(e: Endpoint, model: String): String {
        if (e.chatPath.isNotEmpty()) return e.base + e.chatPath.replace("{model}", model.removePrefix("models/"))
        return when (e.format) {
            "anthropic" -> if (e.base.endsWith("/v1")) e.base + "/messages" else e.base + "/v1/messages"
            "gemini" -> geminiRoot(e) + "/models/" + model.removePrefix("models/") + ":generateContent"
            else -> e.base + "/chat/completions"
        }
    }

    /** كيعاود الطلب حتى 3 مرات فحالة 429 أو أخطاء السيرفر (5xx). */
    fun complete(p: AiPrefs, system: String, msgs: List<Msg>): String {
        require(p.ready()) { "ضع مفتاح API من الإعدادات" }
        val model = p.effectiveModel()
        require(model.isNotBlank()) { "اختر الموديل من الإعدادات (زر «اختيار»)" }
        val e = endpoint(p)
        var last: ApiException? = null
        var sys = system
        for (attempt in 0 until 3) {
            try {
                return when (e.format) {
                    "anthropic" -> claude(e, model, sys, msgs)
                    "gemini" -> gemini(e, model, sys, msgs)
                    else -> openAi(e, model, sys, msgs)
                }
            } catch (ex: ApiException) {
                // بعض النماذج (مثل gpt-oss) تحاول استدعاء أداة أصلية فيرفضها المزوّد: نعيد الطلب بتذكير صريح
                val nativeTool = ex.code == 400 && (ex.message ?: "").contains("tool", ignoreCase = true)
                if (!nativeTool && ex.code != 429 && ex.code < 500) throw ex
                if (nativeTool) sys = system + NO_NATIVE
                last = ex
                if (attempt < 2) Thread.sleep(if (nativeTool) 400L else 1500L * (attempt + 1))
            }
        }
        throw last ?: IllegalStateException("فشل الطلب")
    }

    /** اختبار سريع للاتصال والمفتاح. */
    fun ping(p: AiPrefs): String =
        complete(p, "Reply with the single word OK.", listOf(Msg("user", "ping"))).trim().take(40)

    // ------------------------------------------------------------------ chat formats
    private fun textOf(v: Any?): String = when (v) {
        is String -> v
        is JSONArray -> buildString {
            for (i in 0 until v.length()) {
                val o = v.optJSONObject(i)
                if (o != null) append(o.optString("text")) else append(v.optString(i))
            }
        }
        else -> ""
    }

    private fun failIfError(res: JSONObject) {
        when (val err = res.opt("error")) {
            is JSONObject -> throw RuntimeException(err.optString("message", "API error"))
            is String -> if (err.isNotBlank()) throw RuntimeException(err)
            else -> {}
        }
    }

    private fun openAi(e: Endpoint, model: String, system: String, msgs: List<Msg>): String {
        val arr = JSONArray()
        arr.put(JSONObject().put("role", "system").put("content", system))
        msgs.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
        val body = JSONObject().put("model", model).put("messages", arr)
        val res = JSONObject(http("POST", chatUrl(e, model), e.headers, body))
        failIfError(res)
        val choices = res.optJSONArray("choices")
            ?: throw RuntimeException("رد غير متوقع من المزوّد: " + res.toString().take(200))
        val msg = choices.optJSONObject(0)?.optJSONObject("message")
            ?: throw RuntimeException("رد فارغ من المزوّد: " + res.toString().take(200))
        return textOf(msg.opt("content"))
    }

    private fun claude(e: Endpoint, model: String, system: String, msgs: List<Msg>): String {
        val arr = JSONArray()
        msgs.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
        val body = JSONObject()
            .put("model", model)
            .put("max_tokens", 12000)
            .put("system", system)
            .put("messages", arr)
        val res = JSONObject(http("POST", chatUrl(e, model), e.headers, body))
        failIfError(res)
        val blocks = res.optJSONArray("content") ?: throw RuntimeException("رد غير متوقع: " + res.toString().take(200))
        return buildString {
            for (i in 0 until blocks.length()) {
                val b = blocks.getJSONObject(i)
                if (b.optString("type") == "text") append(b.optString("text"))
            }
        }
    }

    private fun gemini(e: Endpoint, model: String, system: String, msgs: List<Msg>): String {
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
        val res = JSONObject(http("POST", chatUrl(e, model), e.headers, body))
        failIfError(res)
        val parts = res.optJSONArray("candidates")?.optJSONObject(0)?.optJSONObject("content")?.optJSONArray("parts")
            ?: throw RuntimeException("رد فارغ (ربما حجبه فلتر الأمان): " + res.toString().take(200))
        return buildString { for (i in 0 until parts.length()) append(parts.getJSONObject(i).optString("text")) }
    }

    // ------------------------------------------------------------------ models list
    private fun collectIds(arr: JSONArray?, out: MutableCollection<String>) {
        if (arr == null) return
        for (i in 0 until arr.length()) {
            val o = arr.opt(i)
            when (o) {
                is JSONObject -> out.add(o.optString("id").ifBlank { o.optString("name") })
                is String -> out.add(o)
            }
        }
    }

    /** يجلب كل موديلات المزوّد الحالي بالمفتاح المدخل (OpenAI-compatible / Anthropic / Gemini). */
    fun listModels(p: AiPrefs): List<String> {
        require(p.ready()) { "أدخل مفتاح API أولا" }
        val e = endpoint(p)
        val out = LinkedHashSet<String>()
        when (e.format) {
            "anthropic" -> {
                val root = if (e.base.endsWith("/v1")) e.base else e.base + "/v1"
                val res = JSONObject(http("GET", "$root/models?limit=1000", e.headers, null))
                collectIds(res.optJSONArray("data"), out)
            }
            "gemini" -> {
                var token: String? = null
                var pages = 0
                do {
                    val url = geminiRoot(e) + "/models?pageSize=1000" +
                        (token?.let { "&pageToken=" + URLEncoder.encode(it, "UTF-8") } ?: "")
                    val res = JSONObject(http("GET", url, e.headers, null))
                    val arr = res.optJSONArray("models")
                    if (arr != null) {
                        for (i in 0 until arr.length()) {
                            val o = arr.getJSONObject(i)
                            val methods = o.optJSONArray("supportedGenerationMethods")
                            var ok = methods == null
                            if (methods != null) {
                                for (j in 0 until methods.length()) if (methods.optString(j) == "generateContent") ok = true
                            }
                            if (ok) out.add(o.optString("name").removePrefix("models/"))
                        }
                    }
                    token = res.optString("nextPageToken").ifBlank { null }
                    pages++
                } while (token != null && pages < 5)
            }
            else -> {
                val raw = http("GET", e.base + "/models", e.headers, null).trim()
                if (raw.startsWith("[")) {
                    collectIds(JSONArray(raw), out)
                } else {
                    val o = JSONObject(raw)
                    collectIds(o.optJSONArray("data") ?: o.optJSONArray("models"), out)
                }
            }
        }
        return out.filter { it.isNotBlank() }.sortedBy { it.lowercase() }
    }

    // ------------------------------------------------------------------ http
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

    private fun http(method: String, url: String, headers: Map<String, String>, body: JSONObject?): String {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = 20_000
            c.readTimeout = if (body != null) 300_000 else 30_000
            c.setRequestProperty("Accept", "application/json")
            headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
            if (body != null) {
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
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
import java.util.concurrent.TimeUnit

/**
 * منفّذ الأدوات: النموذج يرسل وسوم <tool .../> والوكيل ينفّذها (قراءة/كتابة/تعديل/إنشاء/حذف/نقل/بحث/تنفيذ أمر)
 * داخل مجلد العمل أو التخزين المشترك، مع إمكانية التراجع عن آخر تنفيذ.
 */
object AiAgent {

    data class Call(val name: String, val attrs: Map<String, String>, val body: String) {
        val path: String get() = attrs["path"].orEmpty()
    }

    data class StepResult(val call: Call, val ok: Boolean, val text: String)

    class Denied : RuntimeException()

    class Run { val undo = mutableListOf<Pair<File, String?>>() }

    /** مجلد العمل: المسارات النسبية كتبدا منو، والمطلقة مسموحة داخل التخزين المشترك (/storage/emulated/0). */
    class Workspace(val root: File, val projects: File) {
        fun resolve(p: String): File {
            val t = p.trim().ifEmpty { "." }
            val f = if (t.startsWith("/")) File(t) else File(root, t)
            val c = f.canonicalFile
            val ok = listOf(root, projects, Environment.getExternalStorageDirectory()).any {
                val r = it.canonicalFile
                c == r || c.path.startsWith(r.path + File.separator)
            }
            if (!ok) throw SecurityException("المسار خارج التخزين المسموح: $p")
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
    private val attrRe = Regex("(\\w+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
    private val editRe = Regex("<find>([\\s\\S]*?)</find>\\s*<replace>([\\s\\S]*?)</replace>")
    private val resultRe = Regex("<result ok=\"(true|false)\" label=\"([^\"]*)\">\\r?\\n([\\s\\S]*?)\\r?\\n</result>")

    private fun trimNl(s: String) =
        s.removePrefix("\r\n").removePrefix("\n").removeSuffix("\r\n").removeSuffix("\n")

    fun parse(reply: String): List<Call> = toolRe.findAll(reply).map { m ->
        val attrs = attrRe.findAll(m.groupValues[1]).associate {
            it.groupValues[1] to (it.groups[2]?.value ?: it.groups[3]?.value ?: "")
        }
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
            "run" -> "تنفيذ أمر: " + c.body.trim().lineSequence().firstOrNull().orEmpty().take(48)
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
            val content = unfence(c.body)
            guard(a, ask, "كتابة ملف", ws.rel(f))
            remember(run, f, old)
            put(a, f, content)
            (if (old == null) "تم إنشاء " else "تم تحديث ") + ws.rel(f) + " (" + content.lines().size + " سطر)"
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

        "run" -> {
            val cmd = c.body.trim().ifEmpty { c.attrs["cmd"].orEmpty().trim() }
            require(cmd.isNotEmpty()) { "run يحتاج أمرا" }
            val dir = if (c.attrs["dir"].isNullOrBlank()) ws.root.canonicalFile else ws.resolve(c.attrs["dir"].orEmpty())
            // تنفيذ الأوامر دائما يطلب تأكيدا مهما كان وضع التنفيذ
            if (!confirm(a, "تنفيذ أمر", cmd.take(600) + "\n\n(المجلد: " + ws.rel(dir) + ")")) throw Denied()
            runShell(a, cmd, dir)
        }

        else -> throw IllegalArgumentException("أداة غير معروفة: ${c.name}")
    }

    /** إذا وضع النموذج المحتوى داخل ``` بالغلط، نشيلو باش ما يدخلش فالملف. */
    private val fenceRe = Regex("^```[A-Za-z0-9_+#.-]*[ \\t]*\\r?\\n([\\s\\S]*?)\\r?\\n?```\\s*$")

    private fun unfence(s: String): String {
        val t = s.trim()
        if (!t.startsWith("```")) return s
        return fenceRe.find(t)?.groupValues?.get(1) ?: s
    }

    /** ينفّذ أمر shell فمجلد معين (مهلة 120 ثانية). كيستعمل بيئة AndroidIDE (usr/bin) إن وُجدت. */
    private fun runShell(a: Activity, cmd: String, dir: File): String {
        dir.mkdirs()
        val usr = File(a.filesDir, "usr")
        val bash = File(usr, "bin/bash")
        val sh = if (bash.canExecute()) bash.path else "/system/bin/sh"
        val pb = ProcessBuilder(sh, "-c", cmd).directory(dir).redirectErrorStream(true)
        val env = pb.environment()
        val bin = File(usr, "bin")
        if (bin.isDirectory) {
            env["PATH"] = bin.path + ":" + (env["PATH"] ?: "/system/bin")
            env["PREFIX"] = usr.path
            val home = File(a.filesDir, "home")
            if (home.isDirectory) env["HOME"] = home.path
        }
        val proc = pb.start()
        val out = StringBuffer()
        val reader = Thread {
            try {
                proc.inputStream.bufferedReader().use { r ->
                    val buf = CharArray(4096)
                    while (true) {
                        val n = r.read(buf)
                        if (n < 0) break
                        if (out.length < 20000) out.append(buf, 0, n)
                    }
                }
            } catch (t: Throwable) { /* انتهى الـ process */ }
        }
        reader.start()
        val finished = proc.waitFor(120, TimeUnit.SECONDS)
        if (!finished) {
            proc.destroyForcibly()
            reader.join(500)
            throw IllegalStateException("انتهت المهلة (120 ثانية)\n" + out.toString().trim().take(3000))
        }
        reader.join(1500)
        val text = out.toString().trim().ifEmpty { "(لا مخرجات)" }
        val code = proc.exitValue()
        if (code != 0) throw IllegalStateException("exit=$code\n" + text)
        return "exit=0\n" + text
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
import android.text.Editable
import android.text.InputType
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.TextWatcher
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.widget.NestedScrollView
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
    @Volatile private var status: String = ""
    private var onChange: (() -> Unit)? = null

    private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    private const val MAX_STEPS = 40

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
        val okColor = hex("#6FD39A", "#1E8E4E")
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

    /** عنصر اختيار بشكل بطاقة (بديل Spinner): كيفتح قائمة اختيار نظيفة. */
    private class Sel(val view: LinearLayout, val label: TextView, var index: Int)

    private fun selector(
        a: Activity, p: Pal, title: String, items: List<String>, start: Int, onPick: (Int) -> Unit
    ): Sel {
        val label = TextView(a).apply {
            setTextColor(p.text); textSize = 14f; setSingleLine()
            ellipsize = TextUtils.TruncateAt.END
            textDirection = View.TEXT_DIRECTION_ANY_RTL
        }
        val chevron = ImageView(a).apply {
            setImageDrawable(icon(a, "ic_ai_chevron"))
            imageTintList = ColorStateList.valueOf(p.sub)
        }
        val view = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ripple(outlined(p.surface, dp(a, 14).toFloat(), p.line, dp(a, 1)), dp(a, 14).toFloat())
            setPadding(dp(a, 16), dp(a, 13), dp(a, 12), dp(a, 13))
            isClickable = true; isFocusable = true
            addView(label, LinearLayout.LayoutParams(0, WRAP, 1f))
            addView(chevron, LinearLayout.LayoutParams(dp(a, 22), dp(a, 22)))
        }
        val sel = Sel(view, label, start.coerceIn(0, (items.size - 1).coerceAtLeast(0)))
        label.text = items.getOrElse(sel.index) { "" }
        view.setOnClickListener {
            AlertDialog.Builder(a)
                .setTitle(title)
                .setSingleChoiceItems(items.toTypedArray(), sel.index) { d, which ->
                    sel.index = which
                    label.text = items[which]
                    d.dismiss()
                    onPick(which)
                }
                .show()
        }
        return sel
    }

    /** نافذة اختيار الموديل مع بحث (كتتحمل بلائحة المزوّد كاملة). */
    private fun pickModel(a: Activity, p: Pal, models: List<String>, onPick: (String) -> Unit) {
        val shown = ArrayList<String>(models)
        val ad = object : ArrayAdapter<String>(a, android.R.layout.simple_list_item_1, shown) {
            override fun getView(pos: Int, v: View?, g: ViewGroup): View =
                (super.getView(pos, v, g) as TextView).apply {
                    setTextColor(p.text); textSize = 13.5f
                    textDirection = View.TEXT_DIRECTION_LTR
                }
        }
        val search = EditText(a).apply {
            hint = "ابحث بين ${models.size} موديل…"
            setTextColor(p.text); setHintTextColor(p.sub); setSingleLine()
            textDirection = View.TEXT_DIRECTION_ANY_RTL
        }
        val lv = ListView(a).apply { adapter = ad }
        val col = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 20), dp(a, 8), dp(a, 20), 0)
            addView(search, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(lv, LinearLayout.LayoutParams(MATCH, dp(a, 380)))
        }
        val dlg = AlertDialog.Builder(a).setTitle("اختر الموديل").setView(col).setNegativeButton("إغلاق", null).create()
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, af: Int) {}
            override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) {
                val q = s?.toString().orEmpty().trim()
                ad.clear()
                ad.addAll(if (q.isEmpty()) models else models.filter { it.contains(q, ignoreCase = true) })
                ad.notifyDataSetChanged()
            }
            override fun afterTextChanged(s: Editable?) {}
        })
        lv.setOnItemClickListener { _, _, pos, _ ->
            ad.getItem(pos)?.let { onPick(it) }
            dlg.dismiss()
        }
        dlg.show()
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
            // ارتفاع الـ sheet ثابت (النافذة - الهامش)، فنستعمل fitToContents باش ما يبقاش HALF_EXPANDED كيخبّي خانة الكتابة
            isFitToContents = true
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
        val rtl = a.resources.configuration.layoutDirection == View.LAYOUT_DIRECTION_RTL
        var stickNext = false

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

        // ---- القائمة (NestedScrollView + منع الـ BottomSheet من سرقة اللمسات = السكرول يخدم)
        val list = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(a, 8), 0, dp(a, 8))
        }
        val scroll = NestedScrollView(a).apply {
            addView(list)
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            isNestedScrollingEnabled = true
            setOnTouchListener { v, ev ->
                if (ev.action == MotionEvent.ACTION_DOWN || ev.action == MotionEvent.ACTION_MOVE) {
                    v.parent?.requestDisallowInterceptTouchEvent(true)
                }
                false
            }
        }

        val input = EditText(a).apply {
            hint = "اكتب أمرك…"
            setTextColor(p.text); setHintTextColor(p.sub)
            textSize = 15f
            background = outlined(p.surface, dp(a, 26).toFloat(), p.line, dp(a, 1))
            setPadding(dp(a, 18), dp(a, 12), dp(a, 18), dp(a, 12))
            maxLines = 5
            textDirection = View.TEXT_DIRECTION_ANY_RTL
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        }
        val send = iconButton(a, "ic_ai_send", "إرسال", p.onAccent, p.accent, 48) { }
        if (rtl) send.scaleX = -1f
        fun updateSend() {
            send.setImageDrawable(icon(a, if (busy) "ic_ai_stop" else "ic_ai_send"))
            send.contentDescription = if (busy) "إيقاف" else "إرسال"
            send.alpha = if (busy || input.text.isNotBlank()) 1f else 0.5f
        }
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, af: Int) {}
            override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) {
                send.alpha = if (busy || !s.isNullOrBlank()) 1f else 0.5f
            }
            override fun afterTextChanged(s: Editable?) {}
        })

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
                background = shape(p.codeBg, dp(a, 14).toFloat())
                setPadding(dp(a, 12), dp(a, 8), dp(a, 12), dp(a, 10))
            }
            val bar = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            bar.addView(TextView(a).apply {
                text = s.lang.ifBlank { "code" }; setTextColor(Color.parseColor("#8A8A9A")); textSize = 11.5f
                typeface = Typeface.MONOSPACE; textDirection = View.TEXT_DIRECTION_LTR
            }, LinearLayout.LayoutParams(0, WRAP, 1f))
            fun mini(label: String, f: () -> Unit) {
                bar.addView(TextView(a).apply {
                    text = label; textSize = 11.5f; setTextColor(p.codeText); gravity = Gravity.CENTER
                    setPadding(dp(a, 12), dp(a, 6), dp(a, 12), dp(a, 6))
                    background = ripple(shape(Color.parseColor("#2A2A34"), dp(a, 14).toFloat()), dp(a, 14).toFloat())
                    isClickable = true; isFocusable = true
                    setOnClickListener { f() }
                }, LinearLayout.LayoutParams(WRAP, WRAP).apply { marginStart = dp(a, 6) })
            }
            mini("نسخ") { copy(s.text) }
            mini("إدراج") { doInsert(s.text) }
            mini("استبدال") { doReplace(s.text) }

            val tv = TextView(a).apply {
                text = s.text; setTextColor(p.codeText); textSize = 12.5f; typeface = Typeface.MONOSPACE
                setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_LTR
                setHorizontallyScrolling(true)
                setPadding(0, dp(a, 8), 0, 0)
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
            bottomMargin = dp(a, 10)
            if (mine) { marginStart = dp(a, 48) } else { marginEnd = dp(a, 12) }
        }

        /** فقاعة بذيل صغير: الذيل كيتبدل حسب اتجاه الواجهة (LTR/RTL). */
        fun bubbleShape(color: Int, mine: Boolean): GradientDrawable {
            val big = dp(a, 20).toFloat()
            val small = dp(a, 6).toFloat()
            val tailRight = (mine && !rtl) || (!mine && rtl)
            val radii = if (tailRight) floatArrayOf(big, big, big, big, small, small, big, big)
            else floatArrayOf(big, big, big, big, big, big, small, small)
            return GradientDrawable().apply { setColor(color); cornerRadii = radii }
        }

        /** بطاقة نشاط الوكيل: كل أداة نفّذها (✓ نجحت / ✗ فشلت). */
        fun activity(m: AiClient.Msg): View {
            val items = AiAgent.parseResults(m.content)
            val col = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                background = outlined(Color.TRANSPARENT, dp(a, 16).toFloat(), p.line, dp(a, 1))
                setPadding(dp(a, 14), dp(a, 10), dp(a, 14), dp(a, 10))
            }
            col.addView(TextView(a).apply {
                text = "الإجراءات · ${items.size}"
                setTextColor(p.sub); textSize = 11.5f; typeface = Typeface.DEFAULT_BOLD
                setPadding(0, 0, 0, dp(a, 4))
            })
            items.forEach { (ok, label, detail) ->
                val sb = SpannableStringBuilder()
                sb.append(if (ok) "✓" else "✗")
                sb.setSpan(ForegroundColorSpan(if (ok) p.okColor else p.danger), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                sb.setSpan(StyleSpan(Typeface.BOLD), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                sb.append("   ").append(label)
                if (!ok && detail.isNotBlank()) {
                    val st = sb.length
                    sb.append("\n      ").append(detail.take(160))
                    sb.setSpan(ForegroundColorSpan(p.danger), st, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                col.addView(TextView(a).apply {
                    text = sb
                    textSize = 13f
                    setTextColor(p.text)
                    textDirection = View.TEXT_DIRECTION_ANY_RTL
                    setPadding(0, dp(a, 3), 0, dp(a, 3))
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
                background = bubbleShape(if (mine) p.accentBox else p.surface, mine)
                setPadding(dp(a, 14), dp(a, 10), dp(a, 14), dp(a, 10))
            }
            if (mine) {
                col.addView(TextView(a).apply {
                    text = body; setTextColor(p.onAccentBox); textSize = 15f
                    setLineSpacing(0f, 1.2f)
                    maxWidth = (a.resources.displayMetrics.widthPixels * 0.78f).toInt()
                    setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_ANY_RTL
                })
            } else {
                var first = true
                for (s in parse(body)) {
                    val gap = if (first) 0 else dp(a, 6)
                    first = false
                    if (s.isCode) {
                        col.addView(codeView(s), LinearLayout.LayoutParams(MATCH, WRAP).apply {
                            topMargin = maxOf(gap, dp(a, 4)); bottomMargin = dp(a, 4)
                        })
                    } else {
                        col.addView(TextView(a).apply {
                            text = md(p, s.text); setTextColor(p.text); textSize = 15f
                            setLineSpacing(0f, 1.2f)
                            setTextIsSelectable(true); textDirection = View.TEXT_DIRECTION_ANY_RTL
                        }, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = gap })
                    }
                }
            }
            col.layoutParams = itemParams(mine)
            return col
        }

        fun working(): View = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = shape(p.surface, dp(a, 18).toFloat())
            setPadding(dp(a, 14), dp(a, 11), dp(a, 16), dp(a, 11))
            addView(ProgressBar(a).apply {
                isIndeterminate = true; indeterminateTintList = ColorStateList.valueOf(p.accent)
            }, LinearLayout.LayoutParams(dp(a, 18), dp(a, 18)))
            addView(TextView(a).apply {
                text = status.ifBlank { "جارٍ العمل…" }
                setTextColor(p.sub); textSize = 13.5f; setPadding(dp(a, 10), 0, 0, 0)
                setSingleLine(); ellipsize = TextUtils.TruncateAt.END
                textDirection = View.TEXT_DIRECTION_ANY_RTL
            }, LinearLayout.LayoutParams(0, WRAP, 1f))
            layoutParams = itemParams(false).apply { marginEnd = dp(a, 48) }
        }

        fun errorCard(e: String): View = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            background = shape(p.danger, dp(a, 16).toFloat())
            setPadding(dp(a, 14), dp(a, 10), dp(a, 14), dp(a, 12))
            addView(TextView(a).apply {
                text = "تعذّر إتمام الطلب"; setTextColor(p.onDanger); textSize = 13.5f; typeface = Typeface.DEFAULT_BOLD
            })
            addView(TextView(a).apply {
                text = e; setTextColor(p.onDanger); textSize = 12.5f; setTextIsSelectable(true)
                setPadding(0, dp(a, 4), 0, 0)
            })
            layoutParams = itemParams(false)
        }

        fun emptyState(): View {
            val col = LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(a, 4), dp(a, 28), dp(a, 4), dp(a, 8))
                layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
            }
            col.addView(iconButton(a, "ic_ai_sparkle", "", p.onAccentBox, p.accentBox, 64) { }.apply { isClickable = false },
                LinearLayout.LayoutParams(dp(a, 64), dp(a, 64)))
            col.addView(TextView(a).apply {
                text = "وكيلك البرمجي جاهز"; setTextColor(p.text); textSize = 20f
                typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(a, 16) })
            col.addView(TextView(a).apply {
                text = "اكتب أمرا بسيطا وسأنفّذه مباشرة: مجلدات، ملفات، شاشات ومشاريع كاملة، أو تعديل الملف المفتوح."
                setTextColor(p.sub); textSize = 13.5f; gravity = Gravity.CENTER; setLineSpacing(0f, 1.25f)
            }, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(a, 6); bottomMargin = dp(a, 20) })
            listOf(
                "أنشئ مجلدا باسم login وضع فيه واجهة تسجيل دخول كاملة",
                "أنشئ مشروع أندرويد جديد باسم Notes",
                "أضف زر حفظ في الملف المفتوح"
            ).forEach { ex ->
                col.addView(TextView(a).apply {
                    text = ex; setTextColor(p.text); textSize = 13.5f
                    textDirection = View.TEXT_DIRECTION_ANY_RTL
                    background = ripple(outlined(Color.TRANSPARENT, dp(a, 16).toFloat(), p.line, dp(a, 1)), dp(a, 16).toFloat())
                    setPadding(dp(a, 16), dp(a, 12), dp(a, 16), dp(a, 12))
                    isClickable = true; isFocusable = true
                    setOnClickListener {
                        input.setText(ex); input.setSelection(input.text.length); input.requestFocus()
                    }
                }, LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(a, 8) })
            }
            return col
        }

        fun nearBottom(): Boolean {
            val c = scroll.getChildAt(0) ?: return true
            return c.bottom - (scroll.scrollY + scroll.height) < dp(a, 96)
        }

        fun render() {
            // ما نسحبوش المستعمل لتحت إلا إلا كان قريب من آخر المحادثة (باش يقدر يقرا القديم وهو الوكيل خدّام)
            val stick = stickNext || nearBottom()
            stickNext = false
            list.removeAllViews()
            if (AiPlugin.history.isEmpty() && !busy) list.addView(emptyState())
            AiPlugin.history.forEach { m -> bubble(m)?.let { list.addView(it) } }
            if (busy) list.addView(working())
            lastError?.let { e -> list.addView(errorCard(e)) }
            if (stick) scroll.post { scroll.scrollTo(0, list.height) }
        }

        // ---- الإرسال / الإيقاف
        fun ask(prompt: String) {
            if (busy) return
            if (!prefs.ready()) { toast("ضع مفتاح API أولا", true); showSettings(a); return }
            stickNext = true
            startRun(a, prompt)
        }

        fun cancel() {
            reqId++; busy = false; status = ""
            val last = AiPlugin.history.lastOrNull()
            if (last != null && last.role == "user" && !AiAgent.isResults(last)) AiPlugin.history.removeAt(AiPlugin.history.lastIndex)
            AiPlugin.save(a)
            updateSend(); render()
        }

        // ---- الهيدر
        val header = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val titles = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        titles.addView(TextView(a).apply {
            text = "مساعد الذكاء الاصطناعي"; setTextColor(p.text); textSize = 17f; typeface = Typeface.DEFAULT_BOLD
        })
        val subtitle = TextView(a).apply {
            setTextColor(p.sub); textSize = 12f; setSingleLine(); ellipsize = TextUtils.TruncateAt.END
            textDirection = View.TEXT_DIRECTION_LTR
            setPadding(0, dp(a, 2), 0, dp(a, 2))
            isClickable = true; isFocusable = true
            setOnClickListener { showSettings(a) }
        }
        titles.addView(subtitle)
        fun updateSubtitle() {
            subtitle.text = prefs.providerLabel() + " · " + prefs.effectiveModel().ifBlank { "اختر موديل" } + "  ›"
        }
        val avatar = iconButton(a, "ic_ai_sparkle", "", p.onAccentBox, p.accentBox, 42) { }
        avatar.isClickable = false
        val more = iconButton(a, "ic_ai_more", "المزيد", p.sub, Color.TRANSPARENT, 42) { }
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
        val close = iconButton(a, "ic_ai_close", "إغلاق", p.sub, Color.TRANSPARENT, 42) { dialog.dismiss() }
        header.addView(avatar, LinearLayout.LayoutParams(dp(a, 42), dp(a, 42)).apply { marginEnd = dp(a, 12) })
        header.addView(titles, LinearLayout.LayoutParams(0, WRAP, 1f))
        header.addView(more, LinearLayout.LayoutParams(dp(a, 42), dp(a, 42)))
        header.addView(close, LinearLayout.LayoutParams(dp(a, 42), dp(a, 42)))

        // ---- اقتراحات سريعة (Material Chips)
        val chipsRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        fun chip(label: String, onClick: () -> Unit) {
            chipsRow.addView(Chip(a).apply {
                text = label; setTextColor(p.text); textSize = 12.5f; isCheckable = false
                chipBackgroundColor = ColorStateList.valueOf(p.surface)
                chipStrokeColor = ColorStateList.valueOf(p.line)
                chipStrokeWidth = dp(a, 1).toFloat()
                setOnClickListener { onClick() }
            }, LinearLayout.LayoutParams(WRAP, WRAP).apply { marginEnd = dp(a, 6) })
        }
        fun prefill(text: String) {
            input.setText(text); input.setSelection(input.text.length); input.requestFocus()
        }
        chip("مشروع جديد") { prefill("أنشئ مشروع أندرويد جديد باسم ") }
        chip("مجلد + واجهة") { prefill("أنشئ مجلدا باسم ") }
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
        val inputRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM }
        inputRow.addView(input, LinearLayout.LayoutParams(0, WRAP, 1f).apply { marginEnd = dp(a, 8) })
        inputRow.addView(send, LinearLayout.LayoutParams(dp(a, 48), dp(a, 48)))

        // ---- التجميع
        val root = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 16), dp(a, 10), dp(a, 16), dp(a, 12))
            background = sheetBackground(a, p)
        }
        root.addView(View(a).apply { background = shape(p.line, dp(a, 2).toFloat()) },
            LinearLayout.LayoutParams(dp(a, 36), dp(a, 4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(a, 10) })
        root.addView(header)
        root.addView(View(a).apply { setBackgroundColor(p.line) },
            LinearLayout.LayoutParams(MATCH, dp(a, 1)).apply { topMargin = dp(a, 10) })
        root.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f))
        root.addView(chips, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(a, 4); bottomMargin = dp(a, 10) })
        root.addView(inputRow)

        onChange = { updateSend(); updateSubtitle(); render() }
        dialog.setOnDismissListener { onChange = null }
        updateSend(); updateSubtitle(); render()
        setupSheet(a, dialog, root, 56)
        dialog.show()
    }

    // ------------------------------------------------------------ agent loop
    private fun startRun(a: Activity, prompt: String) {
        val prefs = AiPrefs(a)
        lastError = null
        val ed = EditorAccess.find(a)
        val custom = prefs.workspace.trim()
        val root = if (custom.isNotEmpty()) File(custom) else (projectRoot(ed?.file()) ?: AiAgent.projectsDir())
        runCatching { root.mkdirs() }
        val ws = AiAgent.Workspace(root, AiAgent.projectsDir())
        val system = buildSystem(ed, ws)
        val first = buildPrompt(prompt, ed)
        val runStart = AiPlugin.history.size
        AiPlugin.history.add(AiClient.Msg("user", prompt))
        val my = ++reqId
        busy = true
        status = "يفكّر…"
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
                    status = if (step == 0) "يفكّر…" else "يراجع النتائج…"
                    notifyChange()
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
                    status = AiAgent.describe(calls.first()) + (if (calls.size > 1) "  (+" + (calls.size - 1) + ")" else "")
                    notifyChange()
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
                    status = ""
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

        fun toast(s: String, long: Boolean = false) =
            Toast.makeText(a, s, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()

        fun section(t: String) = TextView(a).apply {
            text = t; setTextColor(p.sub); textSize = 12f; typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(a, 4), dp(a, 20), dp(a, 4), dp(a, 6))
        }
        fun note(t: String) = TextView(a).apply {
            text = t; setTextColor(p.sub); textSize = 11.5f; setLineSpacing(0f, 1.2f)
            setPadding(dp(a, 4), dp(a, 6), dp(a, 4), 0)
        }
        fun field(h: String, v: String, pass: Boolean = false, multi: Boolean = false, uri: Boolean = false) =
            EditText(a).apply {
                hint = h; setText(v); setTextColor(p.text); setHintTextColor(p.sub)
                textSize = 14f
                background = outlined(p.surface, dp(a, 14).toFloat(), p.line, dp(a, 1))
                setPadding(dp(a, 16), dp(a, 13), dp(a, 16), dp(a, 13))
                layoutDirection = View.LAYOUT_DIRECTION_LTR
                if (multi) {
                    minLines = 3
                    gravity = Gravity.TOP or Gravity.START
                    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                } else {
                    setSingleLine()
                    inputType = when {
                        pass -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                        uri -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
                        else -> InputType.TYPE_CLASS_TEXT
                    }
                }
            }

        val ids = AiProviders.ids()
        val labels = AiProviders.ALL.map { it.label }
        var cur = prefs.provider.let { if (ids.contains(it)) it else "openrouter" }

        val key = field("API Key", "", pass = true)
        val model = field("", "")
        val base = field("", "", uri = true)
        val providerNote = note("")

        // ---- حقول المزوّد المخصص (custom)
        val formats = listOf("openai", "anthropic", "gemini")
        val cName = field("اسم المزوّد (للعرض فقط)", prefs.customName)
        val cFormat = selector(
            a, p, "صيغة الـ API",
            listOf("OpenAI-compatible (الأشهر)", "Anthropic Messages", "Google Gemini"),
            formats.indexOf(prefs.customFormat)
        ) { }
        val cAuthHeader = field("Authorization", prefs.customAuthHeader)
        val cAuthPrefix = field("Bearer ", prefs.customAuthPrefix)
        val cHeaders = field("X-Header: value", prefs.customHeaders, multi = true)
        val cPath = field("/chat/completions", prefs.customChatPath)
        val custom = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            addView(section("اسم المزوّد")); addView(cName)
            addView(section("صيغة الـ API")); addView(cFormat.view)
            addView(section("Header ديال المفتاح (اختياري)")); addView(cAuthHeader)
            addView(note("فارغ = الافتراضي حسب الصيغة (Authorization مع Bearer، أو x-api-key فـ Anthropic)."))
            addView(section("بادئة المفتاح (اختياري)")); addView(cAuthPrefix)
            addView(section("Headers إضافية (سطر لكل header)")); addView(cHeaders)
            addView(section("مسار الدردشة (اختياري)")); addView(cPath)
            addView(note("فارغ = المسار الافتراضي حسب الصيغة. فـ Gemini تقدر تكتب {model} داخل المسار."))
        }
        val advanced = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            addView(section("العنوان (Base URL)")); addView(base)
            addView(custom)
        }
        val advToggle = TextView(a).apply {
            text = "خيارات متقدمة  ▾"; setTextColor(p.accent); textSize = 13f
            setPadding(dp(a, 4), dp(a, 20), dp(a, 4), dp(a, 4))
            isClickable = true; isFocusable = true
            setOnClickListener {
                val opening = advanced.visibility != View.VISIBLE
                advanced.visibility = if (opening) View.VISIBLE else View.GONE
                text = if (opening) "خيارات متقدمة  ▴" else "خيارات متقدمة  ▾"
            }
        }

        fun load(id: String) {
            val pr = AiProviders.get(id)
            key.setText(prefs.keyFor(id))
            model.setText(prefs.modelFor(id))
            base.setText(prefs.baseFor(id))
            val defBase = pr?.base.orEmpty()
            base.hint = if (defBase.isBlank()) "https://example.com/v1" else defBase
            val defModel = pr?.model.orEmpty()
            model.hint = if (defModel.isBlank()) "اكتب اسم الموديل أو اضغط «اختيار»" else defModel
            val isCustom = id == "custom"
            custom.visibility = if (isCustom) View.VISIBLE else View.GONE
            advToggle.visibility = if (isCustom) View.GONE else View.VISIBLE
            if (isCustom) {
                advanced.visibility = View.VISIBLE
            } else {
                advanced.visibility = View.GONE
                advToggle.text = "خيارات متقدمة  ▾"
            }
            providerNote.text = when {
                isCustom -> "مزوّد مخصص: أدخل Base URL (فالخيارات المتقدمة) + الصيغة + المفتاح + اسم الموديل. يدعم أي خدمة."
                pr != null && !pr.needsKey -> "مزوّد محلي: المفتاح اختياري. تأكد أن الخادم يشتغل (مثلا فـ Termux)."
                else -> "ما عليك إلا مفتاح API — العنوان جاهز. بعد إدخاله اضغط «اختيار» لتشوف كل موديلات المزوّد."
            }
        }
        fun store(id: String) {
            prefs.setKeyFor(id, key.text.toString().trim())
            prefs.setModelFor(id, model.text.toString().trim())
            prefs.setBaseFor(id, base.text.toString().trim())
        }

        val providerSel = selector(a, p, "المزوّد", labels, ids.indexOf(cur)) { idx ->
            store(cur)
            cur = ids[idx]
            load(cur)
        }

        // ---- المفتاح + إظهار/إخفاء
        var reveal = false
        val eye = TextView(a).apply {
            text = "إظهار"; setTextColor(p.accent); textSize = 13f; gravity = Gravity.CENTER
            setPadding(dp(a, 14), dp(a, 8), dp(a, 6), dp(a, 8))
            isClickable = true; isFocusable = true
            setOnClickListener {
                reveal = !reveal
                val pos = key.selectionStart.coerceAtLeast(0)
                key.inputType = InputType.TYPE_CLASS_TEXT or
                    (if (reveal) InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD else InputType.TYPE_TEXT_VARIATION_PASSWORD)
                key.setSelection(pos.coerceAtMost(key.text.length))
                text = if (reveal) "إخفاء" else "إظهار"
            }
        }
        val keyRow = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(key, LinearLayout.LayoutParams(0, WRAP, 1f))
            addView(eye, LinearLayout.LayoutParams(WRAP, WRAP))
        }

        // ---- الموديل + جلب اللائحة
        fun fetchModels() {
            store(cur)
            prefs.provider = cur
            val id = cur
            toast("⏳ جارٍ جلب الموديلات…")
            Thread {
                val res = runCatching { AiClient.listModels(prefs) }
                a.runOnUiThread {
                    val found = res.getOrNull()
                    val fallback = AiProviders.get(id)?.fallback.orEmpty()
                    when {
                        found != null && found.isNotEmpty() -> pickModel(a, p, found) { model.setText(it) }
                        fallback.isNotEmpty() -> pickModel(a, p, fallback) { model.setText(it) }
                        res.isFailure -> toast("تعذّر جلب الموديلات: " + (res.exceptionOrNull()?.message ?: ""), true)
                        else -> toast("ما لقيتش موديلات — اكتب الاسم يدويا", true)
                    }
                }
            }.start()
        }
        val pick = materialButton(a, p, "اختيار", false) { fetchModels() }
        val modelRow = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(model, LinearLayout.LayoutParams(0, WRAP, 1f))
            addView(pick, LinearLayout.LayoutParams(WRAP, WRAP).apply { marginStart = dp(a, 8) })
        }

        // ---- السلوك والمظهر
        val modes = listOf("تلقائي — ينفّذ مباشرة", "اسأل قبل كل تعديل")
        val modeSel = selector(a, p, "وضع التنفيذ", modes, if (prefs.askBeforeEdit) 1 else 0) { }
        val workspace = field("/storage/emulated/0/Documents/Android_Projects", prefs.workspace)
        val themeIds = AiPrefs.THEMES
        val themeSel = selector(a, p, "المظهر", listOf("تلقائي (حسب النظام)", "فاتح", "داكن"), themeIds.indexOf(prefs.theme)) { }

        fun save() {
            store(cur)
            prefs.provider = cur
            prefs.customName = cName.text.toString().trim()
            prefs.customFormat = formats[cFormat.index.coerceIn(0, formats.size - 1)]
            prefs.customAuthHeader = cAuthHeader.text.toString().trim()
            prefs.customAuthPrefix = cAuthPrefix.text.toString()
            prefs.customHeaders = cHeaders.text.toString().trim()
            prefs.customChatPath = cPath.text.toString().trim()
            prefs.askBeforeEdit = modeSel.index == 1
            prefs.theme = themeIds[themeSel.index.coerceIn(0, themeIds.size - 1)]
            prefs.workspace = workspace.text.toString().trim()
        }

        // ---- المحتوى
        val content = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(a, 20), 0, dp(a, 20), dp(a, 16))
            addView(section("المزوّد")); addView(providerSel.view); addView(providerNote)
            addView(section("مفتاح API")); addView(keyRow)
            addView(note("كيتخزّن محليا فجهازك فقط، ولكل مزوّد مفتاحو."))
            addView(section("الموديل")); addView(modelRow)
            addView(advToggle); addView(advanced)
            addView(section("وضع التنفيذ")); addView(modeSel.view)
            addView(note("الحذف وتنفيذ الأوامر (run) دائما يطلبان تأكيدا."))
            addView(section("مجلد العمل (اختياري)")); addView(workspace)
            addView(note("فارغ = مجلد المشروع المفتوح، وإلا AndroidIDEProjects. هنا كيتخلق المجلدات والمشاريع الجديدة."))
            addView(section("المظهر")); addView(themeSel.view)
        }
        val scroll = NestedScrollView(a).apply {
            addView(content)
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            isNestedScrollingEnabled = true
            setOnTouchListener { v, ev ->
                if (ev.action == MotionEvent.ACTION_DOWN || ev.action == MotionEvent.ACTION_MOVE) {
                    v.parent?.requestDisallowInterceptTouchEvent(true)
                }
                false
            }
        }

        // ---- الأزرار (ثابتة تحت، ما كتتحركش مع السكرول)
        val actions = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(a, 20), dp(a, 12), dp(a, 20), dp(a, 16))
        }
        actions.addView(materialButton(a, p, "اختبار الاتصال", false) {
            save()
            toast("⏳ كنجرب الاتصال…")
            Thread {
                val msg = try { AiClient.ping(prefs); "الاتصال ناجح ✓" }
                catch (t: Throwable) { "فشل الاتصال: ${t.message ?: t.javaClass.simpleName}" }
                a.runOnUiThread { Toast.makeText(a, msg, Toast.LENGTH_LONG).show() }
            }.start()
        }, LinearLayout.LayoutParams(0, WRAP, 1f).apply { marginEnd = dp(a, 8) })
        actions.addView(materialButton(a, p, "حفظ", true) {
            save()
            toast("تم الحفظ")
            onChange?.invoke()
            dialog.dismiss()
        }, LinearLayout.LayoutParams(0, WRAP, 1f))

        // ---- الهيكل
        val head = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(a, 20), dp(a, 4), dp(a, 8), 0)
            addView(TextView(a).apply {
                text = "إعدادات المساعد"; setTextColor(p.text); textSize = 18f; typeface = Typeface.DEFAULT_BOLD
            }, LinearLayout.LayoutParams(0, WRAP, 1f))
            addView(iconButton(a, "ic_ai_close", "إغلاق", p.sub, Color.TRANSPARENT, 42) { dialog.dismiss() },
                LinearLayout.LayoutParams(dp(a, 42), dp(a, 42)))
        }
        val root = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(a, 10), 0, 0)
            background = sheetBackground(a, p)
        }
        root.addView(View(a).apply { background = shape(p.line, dp(a, 2).toFloat()) },
            LinearLayout.LayoutParams(dp(a, 36), dp(a, 4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(a, 8) })
        root.addView(head)
        root.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f))
        root.addView(View(a).apply { setBackgroundColor(p.line) }, LinearLayout.LayoutParams(MATCH, dp(a, 1)))
        root.addView(actions)

        load(cur)
        setupSheet(a, dialog, root, 64)
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
<tool name="run" dir="optional-dir">
one shell command (runs in the workspace; the user must approve every command)
</tool>

## Rules
- Paths are relative to the workspace root, or absolute anywhere inside shared storage (/storage/emulated/0/...).
- Always use double quotes for tag attributes, and write file content RAW inside the tag (never inside a ``` code fence).
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
- If a tool fails, read the error, fix the cause and retry once with a corrected call. If it fails again, stop and tell the user why.

## Building things (IMPORTANT)
- When the user asks to create a folder, file, screen, UI or project: DO IT NOW with create_dir + write_file. Never answer with instructions only.
- "Create a folder X and put Y in it" means: create_dir X, then write_file X/<files>. Use the workspace root unless the user gives another path.
- For a screen/UI in an Android project: write the XML layout (res/layout), its Activity or Fragment, any strings/colors/styles it needs,
  and register a new Activity in AndroidManifest.xm
