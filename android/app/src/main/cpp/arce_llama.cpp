// JNI bridge between ai.arce.app.engine.LlamaNative and llama.cpp.
//
// One Engine owns a model and a context. A generation is a Session: it holds the sampler
// chain (with an optional lazy GBNF grammar for tool calls) and the per-generation state.
// Only one Session may be active per Engine; the Kotlin side runs all calls except
// nativeCancel on a single thread.

#include <jni.h>

#include <atomic>
#include <cstring>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include "ggml-backend.h"
#include "json-schema-to-grammar.h"
#include "json.h"
#include "llama.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "arce-llama", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "arce-llama", __VA_ARGS__)
#else
#include <cstdio>
#define LOGI(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#define LOGE(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#endif

namespace {

// Keep in sync with ai.arce.core.generation.FinishReason
enum FinishReason : jint { RUNNING = -1, EOG = 0, LENGTH = 1, CANCELLED = 2, ERROR = 3 };

struct Engine {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    std::atomic<bool> cancel{false};
    // Tokens currently held in the KV cache (sequence 0), in order. The next prompt reuses
    // the longest common prefix instead of re-evaluating the whole conversation.
    std::vector<llama_token> cached;
    // How many of them are the last prompt (the rest is the reply). Only the prompt is worth
    // saving: a later prompt carries the reply without its thinking, so it cannot reuse it.
    size_t prompt_len = 0;

    ~Engine() {
        if (ctx) llama_free(ctx);
        if (model) llama_model_free(model);
    }
};

struct Session {
    Engine * engine = nullptr;
    llama_sampler * sampler = nullptr;
    int max_tokens = 0;
    int generated = 0;
    jint finish = RUNNING;
    std::string utf8_pending;  // bytes of a character split across tokens

    ~Session() {
        if (sampler) llama_sampler_free(sampler);
    }
};

thread_local std::string g_last_error;

void set_error(const std::string & message) {
    g_last_error = message;
    LOGE("%s", message.c_str());
}

std::string to_string(JNIEnv * env, jstring s) {
    if (!s) return {};
    const char * chars = env->GetStringUTFChars(s, nullptr);
    std::string out(chars);
    env->ReleaseStringUTFChars(s, chars);
    return out;
}

// JNI's modified UTF-8 cannot carry 4-byte characters (emoji), so text crosses as bytes.
jbyteArray to_bytes(JNIEnv * env, const std::string & s) {
    jbyteArray array = env->NewByteArray(static_cast<jsize>(s.size()));
    env->SetByteArrayRegion(array, 0, static_cast<jsize>(s.size()), reinterpret_cast<const jbyte *>(s.data()));
    return array;
}

std::string from_bytes(JNIEnv * env, jbyteArray array) {
    const jsize len = env->GetArrayLength(array);
    std::string out(static_cast<size_t>(len), '\0');
    env->GetByteArrayRegion(array, 0, len, reinterpret_cast<jbyte *>(out.data()));
    return out;
}

// Length of the longest prefix of s that ends on a complete UTF-8 character.
size_t complete_utf8_prefix(const std::string & s) {
    size_t i = s.size();
    size_t back = 0;
    while (i > 0 && back < 4) {
        const auto c = static_cast<unsigned char>(s[i - 1]);
        if ((c & 0xC0) != 0x80) {  // lead byte or ASCII
            size_t need = 1;
            if ((c & 0xE0) == 0xC0) need = 2;
            else if ((c & 0xF0) == 0xE0) need = 3;
            else if ((c & 0xF8) == 0xF0) need = 4;
            return (back + 1 >= need) ? s.size() : i - 1;
        }
        --i;
        ++back;
    }
    return s.size();
}

bool abort_requested(void * data) {
    return static_cast<Engine *>(data)->cancel.load();
}

// Wraps the tool-call JSON grammar so that the constrained part starts at <tool_call>.
std::string tool_call_grammar(const std::string & schema_json) {
    const std::string body = json_schema_to_grammar(common_json::parse(schema_json));

    // Rename the generated start rule (a line beginning with "root ::=") so ours can take its place.
    // Done by hand: std::regex::multiline is not available in every libc++ the NDK ships.
    std::string renamed;
    size_t line_start = 0;
    while (line_start < body.size()) {
        size_t line_end = body.find('\n', line_start);
        if (line_end == std::string::npos) line_end = body.size();
        std::string line = body.substr(line_start, line_end - line_start);
        if (line.rfind("root ::=", 0) == 0) line = "tool-json ::=" + line.substr(std::strlen("root ::="));
        renamed += line + "\n";
        line_start = line_end + 1;
    }
    return "root ::= \"<tool_call>\" [ \\t\\n]* tool-json [ \\t\\n]* \"</tool_call>\"\n" + renamed;
}

llama_sampler * make_sampler(const llama_model * model, const std::string & tool_schema,
                             const std::string & strict_schema, bool thinking, float temperature, float top_p,
                             int top_k, float min_p, float dry_multiplier) {
    const llama_vocab * vocab = llama_model_get_vocab(model);
    auto params = llama_sampler_chain_default_params();
    llama_sampler * chain = llama_sampler_chain_init(params);

    if (!strict_schema.empty()) {
        // The whole output must match (e.g. the agent classification).
        const std::string grammar = json_schema_to_grammar(common_json::parse(strict_schema));
        llama_sampler * grammar_sampler = llama_sampler_init_grammar(vocab, grammar.c_str(), "root");
        if (!grammar_sampler) {
            llama_sampler_free(chain);
            set_error("strict grammar failed to parse");
            return nullptr;
        }
        llama_sampler_chain_add(chain, grammar_sampler);
    } else if (!tool_schema.empty()) {
        const std::string grammar = tool_call_grammar(tool_schema);
        // With thinking on, only a call after </think> counts; the reasoning may mention the tag.
        const char * pattern = thinking ? "</think>[\\s\\S]*?(<tool_call>)" : "(<tool_call>)";
        llama_sampler * grammar_sampler = llama_sampler_init_grammar_lazy_patterns(
            vocab, grammar.c_str(), "root", &pattern, 1, nullptr, 0);
        if (!grammar_sampler) {
            llama_sampler_free(chain);
            set_error("tool-call grammar failed to parse");
            return nullptr;
        }
        llama_sampler_chain_add(chain, grammar_sampler);
    }

    if (dry_multiplier > 0.0f) {
        static const char * breakers[] = {"\n", ":", "\"", "*"};
        llama_sampler_chain_add(chain, llama_sampler_init_dry(vocab, dry_multiplier, 1.75f, 2, -1, breakers, 4));
    }
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(top_k));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(top_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_min_p(min_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return chain;
}

void forget_cache(Engine * engine) {
    llama_memory_clear(llama_get_memory(engine->ctx), true);
    engine->cached.clear();
    engine->prompt_len = 0;
}

// Keeps the KV entries shared with the new prompt and drops the rest. Returns how many
// prompt tokens are already evaluated. At least one token is always left to decode so
// the sampler gets fresh logits.
size_t reuse_prefix(Engine * engine, const std::vector<llama_token> & tokens) {
    size_t n = 0;
    const size_t limit = std::min(engine->cached.size(), tokens.size());
    while (n < limit && engine->cached[n] == tokens[n]) n++;
    if (n == tokens.size() && n > 0) n--;
    if (n == 0) {
        forget_cache(engine);
        return 0;
    }
    // Recurrent/hybrid models (e.g. Qwen3.5) cannot drop a tail of their state; start over then.
    if (!llama_memory_seq_rm(llama_get_memory(engine->ctx), 0, static_cast<llama_pos>(n), -1)) {
        forget_cache(engine);
        return 0;
    }
    engine->cached.resize(n);
    return n;
}

bool decode_prompt(Engine * engine, const std::vector<llama_token> & tokens, size_t from) {
    const int n_batch = static_cast<int>(llama_n_batch(engine->ctx));
    for (size_t i = from; i < tokens.size(); i += n_batch) {
        const int n = static_cast<int>(std::min<size_t>(n_batch, tokens.size() - i));
        const int rc = llama_decode(engine->ctx, llama_batch_get_one(const_cast<llama_token *>(tokens.data()) + i, n));
        if (rc != 0) {
            // A half-evaluated batch leaves the cache in an unknown state.
            forget_cache(engine);
            set_error(rc == 2 ? "cancelled" : "prompt decode failed: " + std::to_string(rc));
            return false;
        }
        engine->cached.insert(engine->cached.end(), tokens.begin() + i, tokens.begin() + i + n);
    }
    return true;
}

}  // namespace

extern "C" {

JNIEXPORT void JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeBackendInit(JNIEnv *, jobject) {
    llama_backend_init();
}

JNIEXPORT jstring JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeLastError(JNIEnv * env, jobject) {
    return env->NewStringUTF(g_last_error.c_str());
}

JNIEXPORT jstring JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeSchemaToGrammar(JNIEnv * env, jobject, jstring schema) {
    try {
        return env->NewStringUTF(tool_call_grammar(to_string(env, schema)).c_str());
    } catch (const std::exception & e) {
        set_error(std::string("schema conversion failed: ") + e.what());
        return nullptr;
    }
}

JNIEXPORT jlong JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeLoad(JNIEnv * env, jobject, jstring path, jint n_ctx, jint n_threads,
                                              jint n_batch, jint n_gpu_layers, jint kv_type) {
    auto engine = std::make_unique<Engine>();

    auto mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    // Weights stay in the page cache: low RSS, and the OS can drop and re-read pages under pressure.
    mparams.load_mode = LLAMA_LOAD_MODE_MMAP;
    engine->model = llama_model_load_from_file(to_string(env, path).c_str(), mparams);
    if (!engine->model) {
        set_error("model load failed");
        return 0;
    }

    auto cparams = llama_context_default_params();
    cparams.n_ctx = static_cast<uint32_t>(n_ctx);
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    if (n_batch > 0) {
        cparams.n_batch = static_cast<uint32_t>(n_batch);
        cparams.n_ubatch = static_cast<uint32_t>(std::min(n_batch, 512));
    }
    // 0 = F16 (the default), 1 = Q8_0, 2 = Q4_0. A quantized V cache requires flash attention.
    if (kv_type == 1 || kv_type == 2) {
        const ggml_type type = kv_type == 1 ? GGML_TYPE_Q8_0 : GGML_TYPE_Q4_0;
        cparams.type_k = type;
        cparams.type_v = type;
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    }
    engine->ctx = llama_init_from_model(engine->model, cparams);
    if (!engine->ctx) {
        set_error("context creation failed (not enough memory for this context length?)");
        return 0;
    }
    llama_set_abort_callback(engine->ctx, abort_requested, engine.get());
    LOGI("loaded model, n_ctx=%u", llama_n_ctx(engine->ctx));
    return reinterpret_cast<jlong>(engine.release());
}

// "type: name (description)" for every compute device ggml was built with (CPU, Vulkan, OpenCL ...).
JNIEXPORT jobjectArray JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeDevices(JNIEnv * env, jobject) {
    const size_t n = ggml_backend_dev_count();
    jobjectArray out = env->NewObjectArray(static_cast<jsize>(n), env->FindClass("java/lang/String"), nullptr);
    for (size_t i = 0; i < n; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char * type = "other";
        switch (ggml_backend_dev_type(dev)) {
            case GGML_BACKEND_DEVICE_TYPE_CPU: type = "CPU"; break;
            case GGML_BACKEND_DEVICE_TYPE_GPU: type = "GPU"; break;
            case GGML_BACKEND_DEVICE_TYPE_IGPU: type = "iGPU"; break;
            case GGML_BACKEND_DEVICE_TYPE_ACCEL: type = "ACCEL"; break;
            default: break;
        }
        const std::string label = std::string(type) + ": " + ggml_backend_dev_name(dev) + " (" +
                                  ggml_backend_dev_description(dev) + ")";
        env->SetObjectArrayElement(out, static_cast<jsize>(i), env->NewStringUTF(label.c_str()));
    }
    return out;
}

JNIEXPORT void JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeFree(JNIEnv *, jobject, jlong engine) {
    delete reinterpret_cast<Engine *>(engine);
}

JNIEXPORT jlong JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeStart(JNIEnv * env, jobject, jlong engine_ptr, jbyteArray prompt_utf8,
                                               jstring tool_schema, jstring strict_schema, jboolean thinking,
                                               jint max_tokens,
                                               jfloat temperature, jfloat top_p, jint top_k, jfloat min_p,
                                               jfloat dry_multiplier) {
    auto * engine = reinterpret_cast<Engine *>(engine_ptr);
    engine->cancel = false;

    auto session = std::make_unique<Session>();
    session->engine = engine;
    try {
        session->sampler = make_sampler(engine->model, to_string(env, tool_schema), to_string(env, strict_schema), thinking,
                                        temperature, top_p,
                                        top_k, min_p, dry_multiplier);
    } catch (const std::exception & e) {
        set_error(std::string("tool schema rejected: ") + e.what());
        return 0;
    }
    if (!session->sampler) return 0;

    const std::string prompt = from_bytes(env, prompt_utf8);
    const llama_vocab * vocab = llama_model_get_vocab(engine->model);
    // One pass in the normal case: a token covers at least one UTF-8 byte, so a buffer the size of the
    // prompt cannot be too small. The second call only covers a tokenizer that adds tokens of its own.
    std::vector<llama_token> tokens(prompt.size() + 8);
    int n_prompt = llama_tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), tokens.data(),
                                  static_cast<int32_t>(tokens.size()), true, true);
    if (n_prompt < 0) {
        tokens.resize(-n_prompt);
        n_prompt = llama_tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), tokens.data(),
                                  static_cast<int32_t>(tokens.size()), true, true);
    }
    if (n_prompt < 0) {
        set_error("tokenize failed");
        return 0;
    }
    tokens.resize(n_prompt);

    const int n_ctx = static_cast<int>(llama_n_ctx(engine->ctx));
    if (n_prompt >= n_ctx) {
        set_error("prompt (" + std::to_string(n_prompt) + " tokens) does not fit the context (" +
                  std::to_string(n_ctx) + ")");
        return 0;
    }
    session->max_tokens = std::min<int>(max_tokens, n_ctx - n_prompt);

    const size_t reused = reuse_prefix(engine, tokens);
    LOGI("prompt %d tokens, %zu reused from the KV cache", n_prompt, reused);
    if (!decode_prompt(engine, tokens, reused)) return 0;
    engine->prompt_len = tokens.size();
    return reinterpret_cast<jlong>(session.release());
}

// Returns the next piece of text as UTF-8 bytes (possibly empty while a character is incomplete),
// or null once generation has finished; then nativeFinishReason says why.
JNIEXPORT jbyteArray JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeNext(JNIEnv * env, jobject, jlong session_ptr) {
    auto * s = reinterpret_cast<Session *>(session_ptr);
    if (s->finish != RUNNING) return nullptr;
    Engine * engine = s->engine;

    if (engine->cancel) {
        s->finish = CANCELLED;
        return nullptr;
    }
    if (s->generated >= s->max_tokens) {
        s->finish = LENGTH;
        return nullptr;
    }

    const llama_vocab * vocab = llama_model_get_vocab(engine->model);
    llama_token token = llama_sampler_sample(s->sampler, engine->ctx, -1);
    if (llama_vocab_is_eog(vocab, token)) {
        s->finish = EOG;
        return nullptr;
    }

    char buf[256];
    const int n = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, true);
    if (n < 0) {
        set_error("token_to_piece failed");
        s->finish = ERROR;
        return nullptr;
    }
    s->utf8_pending.append(buf, static_cast<size_t>(n));
    s->generated++;

    const int rc = llama_decode(engine->ctx, llama_batch_get_one(&token, 1));
    if (rc == 0) {
        engine->cached.push_back(token);
    } else if (rc == 2) {
        forget_cache(engine);
        s->finish = CANCELLED;
    } else {
        forget_cache(engine);
        set_error("decode failed: " + std::to_string(rc));
        s->finish = ERROR;
    }

    const size_t ready = s->finish == RUNNING ? complete_utf8_prefix(s->utf8_pending) : s->utf8_pending.size();
    std::string out = s->utf8_pending.substr(0, ready);
    s->utf8_pending.erase(0, ready);
    return to_bytes(env, out);
}

JNIEXPORT jint JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeFinishReason(JNIEnv *, jobject, jlong session_ptr) {
    return reinterpret_cast<Session *>(session_ptr)->finish;
}

// Writes the KV entries of the last prompt to a file, so the same conversation can continue later
// without evaluating the prompt again (after the app was closed, or another conversation was
// open). Returns the file's size in bytes, or 0 when nothing was written: no model state to keep,
// fewer than min_tokens, or a model whose state cannot be cut back to the prompt (recurrent and
// hybrid ones such as Qwen3.5, which could not reuse a prefix in memory either).
// Must not run while a session is active; the Kotlin side runs it on the llama thread.
JNIEXPORT jlong JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeSaveState(JNIEnv * env, jobject, jlong engine_ptr, jstring path,
                                                   jint min_tokens) {
    auto * engine = reinterpret_cast<Engine *>(engine_ptr);
    const size_t keep = std::min(engine->prompt_len, engine->cached.size());
    if (keep == 0 || keep < static_cast<size_t>(std::max(min_tokens, 1))) return 0;

    if (keep < engine->cached.size()) {
        if (!llama_memory_seq_rm(llama_get_memory(engine->ctx), 0, static_cast<llama_pos>(keep), -1)) return 0;
        engine->cached.resize(keep);
    }
    const size_t written = llama_state_seq_save_file(engine->ctx, to_string(env, path).c_str(), 0,
                                                     engine->cached.data(), engine->cached.size());
    if (written == 0) set_error("could not save the KV state");
    return static_cast<jlong>(written);
}

// Reads a file written by nativeSaveState into the (emptied) cache. Returns how many tokens it
// holds, or 0 on failure (the cache is then empty and the next prompt is evaluated in full). A file
// from another model, another context size or another llama.cpp build is refused by llama.cpp.
JNIEXPORT jlong JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeLoadState(JNIEnv * env, jobject, jlong engine_ptr, jstring path) {
    auto * engine = reinterpret_cast<Engine *>(engine_ptr);
    forget_cache(engine);

    std::vector<llama_token> tokens(llama_n_ctx(engine->ctx));
    size_t count = 0;
    const size_t read = llama_state_seq_load_file(engine->ctx, to_string(env, path).c_str(), 0, tokens.data(),
                                                  tokens.size(), &count);
    if (read == 0 || count == 0 || count > tokens.size()) {
        forget_cache(engine);
        set_error("could not load the KV state");
        return 0;
    }
    tokens.resize(count);
    engine->cached = std::move(tokens);
    engine->prompt_len = engine->cached.size();
    return static_cast<jlong>(count);
}

JNIEXPORT void JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeCancel(JNIEnv *, jobject, jlong engine_ptr) {
    reinterpret_cast<Engine *>(engine_ptr)->cancel = true;
}

JNIEXPORT void JNICALL
Java_ai_arce_app_engine_LlamaNative_nativeEnd(JNIEnv *, jobject, jlong session_ptr) {
    delete reinterpret_cast<Session *>(session_ptr);
}

}  // extern "C"
