// JNI marshaling for the shared terminal engine in the Zig core (core/, ADR 0012).
//
// All terminal behavior lives in the core behind the C ABI in seance_core.h;
// this file only converts between Java and C types. The one libghostty-vt
// concern kept here is the PNG decoder for the Kitty graphics protocol, which
// uses stb_image and is registered with ghostty_sys_set().
#include <jni.h>
#include <ghostty/vt.h>
#include <seance_core.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include <stb_image.h>

#include <cstdint>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr size_t kKittyStorageLimit = 32 * 1024 * 1024;
constexpr size_t kKittyApcLimit = 8 * 1024 * 1024;
constexpr jsize kMaxSnapshotBytes = 32 * 1024 * 1024;

bool decode_png(void*, const GhosttyAllocator* allocator, const uint8_t* data,
    size_t data_len, GhosttySysImage* out) {
  if (data_len == 0 || data_len > kKittyApcLimit || data_len > INT32_MAX) return false;
  int width = 0;
  int height = 0;
  int channels = 0;
  stbi_uc* decoded = stbi_load_from_memory(
      data, static_cast<int>(data_len), &width, &height, &channels, 4);
  if (decoded == nullptr || width <= 0 || height <= 0 || width > 4096 || height > 4096) {
    stbi_image_free(decoded);
    return false;
  }
  const size_t output_len = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (output_len > kKittyStorageLimit) {
    stbi_image_free(decoded);
    return false;
  }
  uint8_t* output = ghostty_alloc(allocator, output_len);
  if (output == nullptr) {
    stbi_image_free(decoded);
    return false;
  }
  std::memcpy(output, decoded, output_len);
  stbi_image_free(decoded);
  out->width = static_cast<uint32_t>(width);
  out->height = static_cast<uint32_t>(height);
  out->data = output;
  out->data_len = output_len;
  return true;
}

void install_png_decoder() {
  static std::once_flag once;
  std::call_once(once, [] {
    ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<const void*>(decode_png));
  });
}

// Owns bytes returned by the core.
struct Bytes {
  ScBytes value{nullptr, 0};
  Bytes() = default;
  Bytes(const Bytes&) = delete;
  Bytes& operator=(const Bytes&) = delete;
  ~Bytes() { sc_bytes_free(value.ptr, value.len); }
  const uint8_t* data() const { return value.ptr; }
  size_t size() const { return value.len; }
};

int32_t require(int32_t status, const char* operation) {
  if (status < 0) {
    throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(status));
  }
  return status;
}

std::string java_utf8(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  jclass string_class = env->FindClass("java/lang/String");
  jmethodID get_bytes = env->GetMethodID(string_class, "getBytes", "(Ljava/lang/String;)[B");
  jstring encoding = env->NewStringUTF("UTF-8");
  auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(value, get_bytes, encoding));
  env->DeleteLocalRef(encoding);
  const jsize length = env->GetArrayLength(bytes);
  std::string result(static_cast<size_t>(length), '\0');
  env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte*>(result.data()));
  env->DeleteLocalRef(bytes);
  env->DeleteLocalRef(string_class);
  return result;
}

jbyteArray byte_array(JNIEnv* env, const uint8_t* data, size_t size) {
  if (size > static_cast<size_t>(INT32_MAX)) throw std::runtime_error("Result is too large");
  jbyteArray result = env->NewByteArray(static_cast<jsize>(size));
  if (size > 0) {
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(size), reinterpret_cast<const jbyte*>(data));
  }
  return result;
}

jbyteArray byte_array(JNIEnv* env, const Bytes& bytes) {
  return byte_array(env, bytes.data(), bytes.size());
}

jstring utf8_java_string(JNIEnv* env, const Bytes& bytes) {
  jbyteArray array = byte_array(env, bytes);
  jclass string_class = env->FindClass("java/lang/String");
  jmethodID constructor = env->GetMethodID(string_class, "<init>", "([BLjava/lang/String;)V");
  jstring encoding = env->NewStringUTF("UTF-8");
  auto result = static_cast<jstring>(env->NewObject(string_class, constructor, array, encoding));
  env->DeleteLocalRef(encoding);
  env->DeleteLocalRef(array);
  env->DeleteLocalRef(string_class);
  return result;
}

void throw_java(JNIEnv* env, const std::exception& error) {
  jclass type = env->FindClass("java/lang/IllegalStateException");
  env->ThrowNew(type, error.what());
}

ScEngine* from_handle(jlong handle) {
  if (handle == 0) throw std::invalid_argument("Ghostty terminal is closed");
  return reinterpret_cast<ScEngine*>(handle);
}

// Runs `body`, translating C++ exceptions into IllegalStateException and
// returning `fallback` when one is thrown.
template <typename Result, typename Body>
Result guarded(JNIEnv* env, Result fallback, Body&& body) {
  try {
    return body();
  } catch (const std::exception& error) {
    throw_java(env, error);
    return fallback;
  }
}

template <typename Body>
void guarded_void(JNIEnv* env, Body&& body) {
  try {
    body();
  } catch (const std::exception& error) {
    throw_java(env, error);
  }
}

// Calls a core function that fills ScBytes and returns the bytes as a byte[].
template <typename Fill>
jbyteArray bytes_result(JNIEnv* env, const char* operation, Fill&& fill) {
  return guarded<jbyteArray>(env, nullptr, [&] {
    Bytes bytes;
    require(fill(&bytes.value), operation);
    return byte_array(env, bytes);
  });
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeCreate(
    JNIEnv* env, jobject, jint columns, jint rows, jint foregroundArgb,
    jint backgroundArgb, jint cursorArgb, jintArray paletteArgb) {
  return guarded<jlong>(env, 0, [&] {
    if (columns <= 0 || rows <= 0 || columns > UINT16_MAX || rows > UINT16_MAX) {
      throw std::invalid_argument("Invalid terminal dimensions");
    }
    install_png_decoder();
    uint32_t palette[256];
    ScEngineConfig config{};
    config.size = sizeof(config);
    config.cols = static_cast<uint16_t>(columns);
    config.rows = static_cast<uint16_t>(rows);
    config.has_colors = true;
    config.foreground = static_cast<uint32_t>(foregroundArgb) & 0xffffff;
    config.background = static_cast<uint32_t>(backgroundArgb) & 0xffffff;
    config.cursor = static_cast<uint32_t>(cursorArgb) & 0xffffff;
    if (env->GetArrayLength(paletteArgb) == 256) {
      jint argb[256];
      env->GetIntArrayRegion(paletteArgb, 0, 256, argb);
      for (size_t index = 0; index < 256; index++) palette[index] = static_cast<uint32_t>(argb[index]) & 0xffffff;
      config.palette = palette;
    }
    ScEngine* engine = nullptr;
    require(sc_engine_new(&config, &engine), "terminal create");
    return reinterpret_cast<jlong>(engine);
  });
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeRestore(
    JNIEnv* env, jobject, jbyteArray data) {
  return guarded<jlong>(env, 0, [&] {
    const jsize length = env->GetArrayLength(data);
    if (length <= 0 || length > kMaxSnapshotBytes) throw std::invalid_argument("Invalid terminal snapshot size");
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    env->GetByteArrayRegion(data, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    install_png_decoder();
    ScEngine* engine = nullptr;
    require(sc_engine_restore(bytes.data(), bytes.size(), &engine), "snapshot decode");
    return reinterpret_cast<jlong>(engine);
  });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeDestroy(
    JNIEnv*, jobject, jlong handle) {
  sc_engine_free(reinterpret_cast<ScEngine*>(handle));
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeWrite(
    JNIEnv* env, jobject, jlong handle, jbyteArray data, jint offset, jint length) {
  guarded_void(env, [&] {
    ScEngine* engine = from_handle(handle);
    const jsize size = env->GetArrayLength(data);
    if (offset < 0 || length < 0 || offset > size - length) {
      throw std::invalid_argument("Invalid terminal write range");
    }
    std::vector<uint8_t> copy(static_cast<size_t>(length));
    env->GetByteArrayRegion(data, offset, length, reinterpret_cast<jbyte*>(copy.data()));
    require(sc_engine_write(engine, copy.data(), copy.size()), "terminal write");
  });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeResize(
    JNIEnv* env, jobject, jlong handle, jint columns, jint rows, jint cellWidth, jint cellHeight) {
  guarded_void(env, [&] {
    ScEngine* engine = from_handle(handle);
    if (columns <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0) {
      throw std::invalid_argument("Invalid terminal dimensions");
    }
    require(sc_engine_resize(engine, static_cast<uint32_t>(columns), static_cast<uint32_t>(rows),
        static_cast<uint32_t>(cellWidth), static_cast<uint32_t>(cellHeight)), "terminal resize");
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSnapshot(
    JNIEnv* env, jobject, jlong handle) {
  return bytes_result(env, "snapshot", [&](ScBytes* out) {
    return sc_engine_snapshot(from_handle(handle), out);
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeState(
    JNIEnv* env, jobject, jlong handle) {
  return bytes_result(env, "snapshot encode", [&](ScBytes* out) {
    return sc_engine_encode_state(from_handle(handle), out);
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeKittyFrame(
    JNIEnv* env, jobject, jlong handle, jlong knownGeneration) {
  return bytes_result(env, "Kitty frame", [&](ScBytes* out) {
    return sc_engine_kitty_frame(from_handle(handle), static_cast<uint64_t>(knownGeneration), out);
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeDrainEffects(
    JNIEnv* env, jobject, jlong handle) {
  return bytes_result(env, "drain effects", [&](ScBytes* out) {
    return sc_engine_drain_effects(from_handle(handle), out);
  });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeScroll(
    JNIEnv* env, jobject, jlong handle, jint deltaRows) {
  guarded_void(env, [&] { sc_engine_scroll(from_handle(handle), deltaRows); });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeScrollToBottom(
    JNIEnv* env, jobject, jlong handle) {
  guarded_void(env, [&] { sc_engine_scroll_to_bottom(from_handle(handle)); });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeScroll(
    JNIEnv* env, jobject, jlong handle, jint rows) {
  return bytes_result(env, "scroll encode", [&](ScBytes* out) {
    return sc_engine_encode_scroll(from_handle(handle), rows, out);
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeKey(
    JNIEnv* env, jobject, jlong handle, jstring keyName, jstring text, jint modifiers, jint action) {
  return guarded<jbyteArray>(env, nullptr, [&] {
    ScEngine* engine = from_handle(handle);
    const std::string key_name = java_utf8(env, keyName);
    const std::string utf8 = java_utf8(env, text);
    Bytes bytes;
    require(sc_engine_encode_key(engine,
        reinterpret_cast<const uint8_t*>(key_name.data()), key_name.size(),
        reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size(),
        static_cast<uint32_t>(modifiers), static_cast<uint32_t>(action), &bytes.value), "key encode");
    return byte_array(env, bytes);
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativePasteIsSafe(
    JNIEnv* env, jobject, jstring text) {
  const std::string utf8 = java_utf8(env, text);
  return sc_paste_is_safe(reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodePaste(
    JNIEnv* env, jobject, jlong handle, jstring text) {
  return guarded<jbyteArray>(env, nullptr, [&] {
    ScEngine* engine = from_handle(handle);
    const std::string utf8 = java_utf8(env, text);
    Bytes bytes;
    require(sc_engine_encode_paste(engine,
        reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size(), &bytes.value), "paste encode");
    return byte_array(env, bytes);
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeIsMouseTracking(
    JNIEnv* env, jobject, jlong handle) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_is_mouse_tracking(from_handle(handle)), "read mouse tracking") == 1;
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeFocus(
    JNIEnv* env, jobject, jlong handle, jboolean focused) {
  return bytes_result(env, "focus encode", [&](ScBytes* out) {
    return sc_engine_encode_focus(from_handle(handle), focused, out);
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeMouse(
    JNIEnv* env, jobject, jlong handle, jint action, jint button, jfloat x, jfloat y,
    jint modifiers, jint width, jint height, jint cellWidth, jint cellHeight, jboolean anyPressed) {
  return bytes_result(env, "mouse encode", [&](ScBytes* out) {
    ScMouseInput input{};
    input.action = static_cast<uint32_t>(action);
    input.button = static_cast<uint32_t>(button);
    input.x = x;
    input.y = y;
    input.modifiers = static_cast<uint32_t>(modifiers);
    input.width = static_cast<uint32_t>(width);
    input.height = static_cast<uint32_t>(height);
    input.cell_width = static_cast<uint32_t>(cellWidth);
    input.cell_height = static_cast<uint32_t>(cellHeight);
    input.any_pressed = anyPressed;
    return sc_engine_encode_mouse(from_handle(handle), &input, out);
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectWord(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_select_word(from_handle(handle), column, row), "select word") == 1;
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectRange(
    JNIEnv* env, jobject, jlong handle, jint startColumn, jint endColumn, jint row) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_select_range(from_handle(handle), startColumn, endColumn, row), "select range") == 1;
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeExtendSelection(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_extend_selection(from_handle(handle), column, row), "extend selection") == 1;
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSetSelectionEndpoint(
    JNIEnv* env, jobject, jlong handle, jboolean start, jint column, jint row) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_set_selection_endpoint(from_handle(handle), start, column, row),
        "update selection endpoint") == 1;
  });
}

extern "C" JNIEXPORT jintArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectionEndpoints(
    JNIEnv* env, jobject, jlong handle) {
  return guarded<jintArray>(env, nullptr, [&] {
    int32_t points[4];
    sc_engine_selection_endpoints(from_handle(handle), points);
    jintArray result = env->NewIntArray(4);
    env->SetIntArrayRegion(result, 0, 4, reinterpret_cast<const jint*>(points));
    return result;
  });
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectedText(
    JNIEnv* env, jobject, jlong handle) {
  return guarded<jstring>(env, nullptr, [&] {
    Bytes bytes;
    require(sc_engine_selected_text(from_handle(handle), &bytes.value), "read selection");
    return utf8_java_string(env, bytes);
  });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativePlainText(
    JNIEnv* env, jobject, jlong handle) {
  return bytes_result(env, "format terminal", [&](ScBytes* out) {
    return sc_engine_plain_text(from_handle(handle), out);
  });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeClearSelection(
    JNIEnv* env, jobject, jlong handle) {
  guarded_void(env, [&] { require(sc_engine_clear_selection(from_handle(handle)), "clear selection"); });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectLatestOutput(
    JNIEnv* env, jobject, jlong handle) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_select_latest_output(from_handle(handle)), "select latest output") == 1;
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectOutput(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_select_output(from_handle(handle), column, row), "select output") == 1;
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeJumpPrompt(
    JNIEnv* env, jobject, jlong handle, jint direction) {
  return guarded<jboolean>(env, false, [&] {
    return require(sc_engine_jump_prompt(from_handle(handle), direction), "jump prompt") == 1;
  });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSearch(
    JNIEnv* env, jobject, jlong handle, jstring query, jint direction) {
  return guarded<jboolean>(env, false, [&] {
    ScEngine* engine = from_handle(handle);
    const std::string utf8 = java_utf8(env, query);
    return require(sc_engine_search(engine,
        reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size(), direction), "search") == 1;
  });
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeHyperlink(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  return guarded<jstring>(env, nullptr, [&] {
    Bytes bytes;
    require(sc_engine_hyperlink(from_handle(handle), column, row, &bytes.value), "read hyperlink");
    return utf8_java_string(env, bytes);
  });
}
