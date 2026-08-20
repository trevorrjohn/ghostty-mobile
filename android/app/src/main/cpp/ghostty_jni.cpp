#include <jni.h>
#include <ghostty/vt.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include <stb_image.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr int32_t kSnapshotMagic = 0x47565431; // GVT1
constexpr size_t kKittyStorageLimit = 32 * 1024 * 1024;
constexpr size_t kKittyApcLimit = 8 * 1024 * 1024;

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

struct NativeTerminal {
  GhosttyTerminal terminal = nullptr;
  GhosttyKeyEncoder key_encoder = nullptr;
  GhosttyKeyEvent key_event = nullptr;
  GhosttyMouseEncoder mouse_encoder = nullptr;
  GhosttyMouseEvent mouse_event = nullptr;
  GhosttyRenderState render = nullptr;
  GhosttyRenderStateRowIterator rows = nullptr;
  GhosttyRenderStateRowCells cells = nullptr;
  GhosttyKittyGraphicsPlacementIterator kitty_placements = nullptr;
  bool first_snapshot = true;
  int pending_bells = 0;
  int pending_progress_state = -1;
  int pending_progress_value = -1;
  int pending_unknown_sequences = 0;
  std::string pending_clipboard;
  std::string pending_notification_title;
  std::string pending_notification_body;
  std::string pending_pty_write;
  std::mutex mutex;

  ~NativeTerminal() {
    ghostty_key_event_free(key_event);
    ghostty_key_encoder_free(key_encoder);
    ghostty_mouse_event_free(mouse_event);
    ghostty_mouse_encoder_free(mouse_encoder);
    ghostty_render_state_row_cells_free(cells);
    ghostty_kitty_graphics_placement_iterator_free(kitty_placements);
    ghostty_render_state_row_iterator_free(rows);
    ghostty_render_state_free(render);
    ghostty_terminal_free(terminal);
  }
};

void terminal_bell(GhosttyTerminal, void* userdata) {
  auto* instance = static_cast<NativeTerminal*>(userdata);
  instance->pending_bells = std::min(instance->pending_bells + 1, 10);
}

void terminal_write_pty(GhosttyTerminal, void* userdata, const uint8_t* data, size_t len) {
  auto* instance = static_cast<NativeTerminal*>(userdata);
  const size_t available = 64 * 1024 - std::min<size_t>(instance->pending_pty_write.size(), 64 * 1024);
  instance->pending_pty_write.append(
      reinterpret_cast<const char*>(data), std::min(len, available));
}

GhosttyClipboardWriteResult terminal_clipboard(
    GhosttyTerminal, void* userdata, const GhosttyClipboardWrite* write) {
  auto* instance = static_cast<NativeTerminal*>(userdata);
  for (size_t index = 0; index < write->contents_len; index++) {
    const GhosttyClipboardContent& content = write->contents[index];
    const std::string mime(reinterpret_cast<const char*>(content.mime.ptr), content.mime.len);
    if ((mime == "text/plain" || mime == "text/plain;charset=utf-8") && content.data.len <= 1024 * 1024) {
      instance->pending_clipboard.assign(
          reinterpret_cast<const char*>(content.data.ptr), content.data.len);
      return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
    }
  }
  return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
}

void terminal_notification(GhosttyTerminal, void* userdata,
    const GhosttyTerminalDesktopNotification* notification) {
  auto* instance = static_cast<NativeTerminal*>(userdata);
  instance->pending_notification_title.assign(
      reinterpret_cast<const char*>(notification->title.ptr),
      std::min<size_t>(notification->title.len, 256));
  instance->pending_notification_body.assign(
      reinterpret_cast<const char*>(notification->body.ptr),
      std::min<size_t>(notification->body.len, 4096));
}

void terminal_progress(GhosttyTerminal, void* userdata,
    const GhosttyTerminalProgressReport* report) {
  auto* instance = static_cast<NativeTerminal*>(userdata);
  instance->pending_progress_state = report->state;
  instance->pending_progress_value = report->progress;
}

void terminal_unknown_sequence(GhosttyTerminal, void* userdata,
    const GhosttyTerminalUnknownSequence*) {
  auto* instance = static_cast<NativeTerminal*>(userdata);
  instance->pending_unknown_sequences = std::min(instance->pending_unknown_sequences + 1, 100);
}

void append_i32(std::vector<uint8_t>& bytes, int32_t value);

void append_string(std::vector<uint8_t>& bytes, const std::string& value) {
  append_i32(bytes, static_cast<int32_t>(value.size()));
  bytes.insert(bytes.end(), value.begin(), value.end());
}

void require_success(GhosttyResult result, const char* operation) {
  if (result != GHOSTTY_SUCCESS) {
    throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(result));
  }
}

std::string java_string(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {};
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
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

GhosttyKey key_from_name(const std::string& name) {
  if (name.size() == 1) {
    const char key = name[0];
    if (key >= 'A' && key <= 'Z') return static_cast<GhosttyKey>(GHOSTTY_KEY_A + key - 'A');
    if (key >= 'a' && key <= 'z') return static_cast<GhosttyKey>(GHOSTTY_KEY_A + key - 'a');
    if (key >= '0' && key <= '9') return static_cast<GhosttyKey>(GHOSTTY_KEY_DIGIT_0 + key - '0');
  }
  if (name == "ESCAPE") return GHOSTTY_KEY_ESCAPE;
  if (name == "SPACE") return GHOSTTY_KEY_SPACE;
  if (name == "BACKQUOTE") return GHOSTTY_KEY_BACKQUOTE;
  if (name == "BACKSLASH") return GHOSTTY_KEY_BACKSLASH;
  if (name == "BRACKET_LEFT") return GHOSTTY_KEY_BRACKET_LEFT;
  if (name == "BRACKET_RIGHT") return GHOSTTY_KEY_BRACKET_RIGHT;
  if (name == "COMMA") return GHOSTTY_KEY_COMMA;
  if (name == "EQUAL") return GHOSTTY_KEY_EQUAL;
  if (name == "MINUS") return GHOSTTY_KEY_MINUS;
  if (name == "PERIOD") return GHOSTTY_KEY_PERIOD;
  if (name == "QUOTE") return GHOSTTY_KEY_QUOTE;
  if (name == "SEMICOLON") return GHOSTTY_KEY_SEMICOLON;
  if (name == "SLASH") return GHOSTTY_KEY_SLASH;
  if (name == "TAB") return GHOSTTY_KEY_TAB;
  if (name == "ENTER") return GHOSTTY_KEY_ENTER;
  if (name == "BACKSPACE") return GHOSTTY_KEY_BACKSPACE;
  if (name == "DELETE") return GHOSTTY_KEY_DELETE;
  if (name == "INSERT") return GHOSTTY_KEY_INSERT;
  if (name == "HOME") return GHOSTTY_KEY_HOME;
  if (name == "END") return GHOSTTY_KEY_END;
  if (name == "PAGE_UP") return GHOSTTY_KEY_PAGE_UP;
  if (name == "PAGE_DOWN") return GHOSTTY_KEY_PAGE_DOWN;
  if (name == "ARROW_UP") return GHOSTTY_KEY_ARROW_UP;
  if (name == "ARROW_DOWN") return GHOSTTY_KEY_ARROW_DOWN;
  if (name == "ARROW_LEFT") return GHOSTTY_KEY_ARROW_LEFT;
  if (name == "ARROW_RIGHT") return GHOSTTY_KEY_ARROW_RIGHT;
  if (name == "SHIFT_LEFT") return GHOSTTY_KEY_SHIFT_LEFT;
  if (name == "SHIFT_RIGHT") return GHOSTTY_KEY_SHIFT_RIGHT;
  if (name == "CONTROL_LEFT") return GHOSTTY_KEY_CONTROL_LEFT;
  if (name == "CONTROL_RIGHT") return GHOSTTY_KEY_CONTROL_RIGHT;
  if (name == "ALT_LEFT") return GHOSTTY_KEY_ALT_LEFT;
  if (name == "ALT_RIGHT") return GHOSTTY_KEY_ALT_RIGHT;
  if (name == "META_LEFT") return GHOSTTY_KEY_META_LEFT;
  if (name == "META_RIGHT") return GHOSTTY_KEY_META_RIGHT;
  if (name.size() >= 2 && name[0] == 'F') {
    const int number = std::atoi(name.c_str() + 1);
    if (number >= 1 && number <= 25) return static_cast<GhosttyKey>(GHOSTTY_KEY_F1 + number - 1);
  }
  return GHOSTTY_KEY_UNIDENTIFIED;
}

jbyteArray byte_array(JNIEnv* env, const char* data, size_t size) {
  jbyteArray result = env->NewByteArray(static_cast<jsize>(size));
  if (size > 0) env->SetByteArrayRegion(result, 0, static_cast<jsize>(size),
      reinterpret_cast<const jbyte*>(data));
  return result;
}

jstring utf8_java_string(JNIEnv* env, const uint8_t* data, size_t size) {
  jbyteArray bytes = byte_array(env, reinterpret_cast<const char*>(data), size);
  jclass string_class = env->FindClass("java/lang/String");
  jmethodID constructor = env->GetMethodID(string_class, "<init>", "([BLjava/lang/String;)V");
  jstring encoding = env->NewStringUTF("UTF-8");
  auto result = static_cast<jstring>(env->NewObject(string_class, constructor, bytes, encoding));
  env->DeleteLocalRef(encoding);
  env->DeleteLocalRef(bytes);
  env->DeleteLocalRef(string_class);
  return result;
}

int32_t argb(GhosttyColorRgb color) {
  return static_cast<int32_t>(0xff000000u |
      (static_cast<uint32_t>(color.r) << 16) |
      (static_cast<uint32_t>(color.g) << 8) |
      static_cast<uint32_t>(color.b));
}

void append_i32(std::vector<uint8_t>& bytes, int32_t value) {
  const uint32_t raw = static_cast<uint32_t>(value);
  bytes.push_back(static_cast<uint8_t>(raw));
  bytes.push_back(static_cast<uint8_t>(raw >> 8));
  bytes.push_back(static_cast<uint8_t>(raw >> 16));
  bytes.push_back(static_cast<uint8_t>(raw >> 24));
}

void append_i64(std::vector<uint8_t>& bytes, uint64_t value) {
  append_i32(bytes, static_cast<int32_t>(value));
  append_i32(bytes, static_cast<int32_t>(value >> 32));
}

void replace_i32(std::vector<uint8_t>& bytes, size_t offset, int32_t value) {
  const uint32_t raw = static_cast<uint32_t>(value);
  bytes[offset] = static_cast<uint8_t>(raw);
  bytes[offset + 1] = static_cast<uint8_t>(raw >> 8);
  bytes[offset + 2] = static_cast<uint8_t>(raw >> 16);
  bytes[offset + 3] = static_cast<uint8_t>(raw >> 24);
}

void throw_java(JNIEnv* env, const std::exception& error) {
  jclass type = env->FindClass("java/lang/IllegalStateException");
  env->ThrowNew(type, error.what());
}

NativeTerminal* from_handle(jlong handle) {
  if (handle == 0) throw std::invalid_argument("Ghostty terminal is closed");
  return reinterpret_cast<NativeTerminal*>(handle);
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeCreate(
    JNIEnv* env, jobject, jint columns, jint rows, jint foregroundArgb,
    jint backgroundArgb, jint cursorArgb) {
  try {
    if (columns <= 0 || rows <= 0 || columns > UINT16_MAX || rows > UINT16_MAX) {
      throw std::invalid_argument("Invalid terminal dimensions");
    }
    auto instance = std::make_unique<NativeTerminal>();
    require_success(ghostty_sys_set(
        GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<const void*>(decode_png)), "PNG decoder");
    require_success(ghostty_terminal_new(
        nullptr, &instance->terminal,
        static_cast<uint16_t>(columns), static_cast<uint16_t>(rows)), "terminal create");
    const uint64_t kitty_storage_limit = kKittyStorageLimit;
    const size_t kitty_apc_limit = kKittyApcLimit;
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kitty_storage_limit), "Kitty storage limit");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &kitty_apc_limit), "Kitty APC limit");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_USERDATA, instance.get()), "effect userdata");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_BELL, reinterpret_cast<const void*>(terminal_bell)), "bell callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void*>(terminal_write_pty)), "PTY write callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void*>(terminal_clipboard)), "clipboard callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, reinterpret_cast<const void*>(terminal_notification)), "notification callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, reinterpret_cast<const void*>(terminal_progress)), "progress callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, reinterpret_cast<const void*>(terminal_unknown_sequence)), "unknown callback");
    const size_t unknown_sequence_limit = 256;
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unknown_sequence_limit), "unknown sequence limit");
    require_success(ghostty_key_encoder_new(nullptr, &instance->key_encoder), "key encoder create");
    require_success(ghostty_key_event_new(nullptr, &instance->key_event), "key event create");
    require_success(ghostty_mouse_encoder_new(nullptr, &instance->mouse_encoder), "mouse encoder create");
    require_success(ghostty_mouse_event_new(nullptr, &instance->mouse_event), "mouse event create");

    const auto color = [](jint value) -> GhosttyColorRgb {
      return GhosttyColorRgb{
          static_cast<uint8_t>(value >> 16),
          static_cast<uint8_t>(value >> 8),
          static_cast<uint8_t>(value)};
    };
    const GhosttyColorRgb foreground = color(foregroundArgb);
    const GhosttyColorRgb background = color(backgroundArgb);
    const GhosttyColorRgb cursor = color(cursorArgb);
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground), "foreground color");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background), "background color");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor), "cursor color");
    const size_t scrollback_lines = 10000;
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback_lines), "scrollback limit");
    const size_t continuation_limit = 4096;
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit), "continuation limit");

    require_success(ghostty_render_state_new(nullptr, &instance->render), "render create");
    require_success(ghostty_render_state_row_iterator_new(nullptr, &instance->rows), "row iterator create");
    require_success(ghostty_render_state_row_cells_new(nullptr, &instance->cells), "cell iterator create");
    require_success(ghostty_kitty_graphics_placement_iterator_new(
        nullptr, &instance->kitty_placements), "Kitty placement iterator create");
    return reinterpret_cast<jlong>(instance.release());
  } catch (const std::exception& error) {
    throw_java(env, error);
    return 0;
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeState(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    uint8_t* bytes = nullptr;
    size_t length = 0;
    require_success(ghostty_snapshot_encode_alloc(instance->terminal, nullptr, &bytes, &length),
        "snapshot encode");
    if (length > 32 * 1024 * 1024) {
      ghostty_free(nullptr, bytes, length);
      throw std::runtime_error("Terminal snapshot exceeds 32 MB");
    }
    jbyteArray result = byte_array(env, reinterpret_cast<const char*>(bytes), length);
    ghostty_free(nullptr, bytes, length);
    return result;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeRestore(
    JNIEnv* env, jobject, jbyteArray data) {
  try {
    const jsize length = env->GetArrayLength(data);
    if (length <= 0 || length > 32 * 1024 * 1024) throw std::invalid_argument("Invalid terminal snapshot size");
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    env->GetByteArrayRegion(data, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    GhosttySnapshotDecoder decoder = nullptr;
    require_success(ghostty_snapshot_decoder_new_buf(nullptr, &decoder, bytes.data(), bytes.size()),
        "snapshot decoder create");
    GhosttyTerminal restored = nullptr;
    const GhosttyResult decode_result = ghostty_snapshot_decoder_decode(decoder, &restored);
    ghostty_snapshot_decoder_free(decoder);
    require_success(decode_result, "snapshot decode");

    auto instance = std::make_unique<NativeTerminal>();
    instance->terminal = restored;
    require_success(ghostty_sys_set(
        GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<const void*>(decode_png)), "PNG decoder");
    const uint64_t kitty_storage_limit = kKittyStorageLimit;
    const size_t kitty_apc_limit = kKittyApcLimit;
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kitty_storage_limit), "Kitty storage limit");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &kitty_apc_limit), "Kitty APC limit");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_USERDATA, instance.get()), "effect userdata");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_BELL, reinterpret_cast<const void*>(terminal_bell)), "bell callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void*>(terminal_write_pty)), "PTY write callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void*>(terminal_clipboard)), "clipboard callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, reinterpret_cast<const void*>(terminal_notification)), "notification callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, reinterpret_cast<const void*>(terminal_progress)), "progress callback");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, reinterpret_cast<const void*>(terminal_unknown_sequence)), "unknown callback");
    const size_t unknown_sequence_limit = 256;
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unknown_sequence_limit), "unknown sequence limit");
    require_success(ghostty_key_encoder_new(nullptr, &instance->key_encoder), "key encoder create");
    require_success(ghostty_key_event_new(nullptr, &instance->key_event), "key event create");
    require_success(ghostty_mouse_encoder_new(nullptr, &instance->mouse_encoder), "mouse encoder create");
    require_success(ghostty_mouse_event_new(nullptr, &instance->mouse_event), "mouse event create");
    require_success(ghostty_render_state_new(nullptr, &instance->render), "render create");
    require_success(ghostty_render_state_row_iterator_new(nullptr, &instance->rows), "row iterator create");
    require_success(ghostty_render_state_row_cells_new(nullptr, &instance->cells), "cell iterator create");
    require_success(ghostty_kitty_graphics_placement_iterator_new(
        nullptr, &instance->kitty_placements), "Kitty placement iterator create");
    return reinterpret_cast<jlong>(instance.release());
  } catch (const std::exception& error) {
    throw_java(env, error);
    return 0;
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeDrainEffects(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    std::vector<uint8_t> result;
    bool processing_error = false;
    require_success(ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error), "read processing health");
    append_i32(result, instance->pending_bells);
    append_i32(result, instance->pending_progress_state);
    append_i32(result, instance->pending_progress_value);
    append_string(result, instance->pending_clipboard);
    append_string(result, instance->pending_notification_title);
    append_string(result, instance->pending_notification_body);
    append_i32(result, instance->pending_unknown_sequences);
    append_i32(result, processing_error ? 1 : 0);
    append_string(result, instance->pending_pty_write);
    instance->pending_bells = 0;
    instance->pending_progress_state = -1;
    instance->pending_progress_value = -1;
    instance->pending_unknown_sequences = 0;
    instance->pending_clipboard.clear();
    instance->pending_notification_title.clear();
    instance->pending_notification_body.clear();
    instance->pending_pty_write.clear();
    return byte_array(env, reinterpret_cast<const char*>(result.data()), result.size());
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeIsMouseTracking(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    bool tracking = false;
    require_success(ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking), "read mouse tracking");
    return tracking;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return false;
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeMouse(
    JNIEnv* env, jobject, jlong handle, jint action, jint button, jfloat x, jfloat y,
    jint modifiers, jint width, jint height, jint cellWidth, jint cellHeight,
    jboolean anyPressed) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    ghostty_mouse_encoder_setopt_from_terminal(instance->mouse_encoder, instance->terminal);
    GhosttyMouseEncoderSize size{
        sizeof(GhosttyMouseEncoderSize), static_cast<uint32_t>(width),
        static_cast<uint32_t>(height), static_cast<uint32_t>(cellWidth),
        static_cast<uint32_t>(cellHeight), 0, 0, 0, 0};
    ghostty_mouse_encoder_setopt(instance->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
    const bool pressed = anyPressed;
    const bool track_last_cell = true;
    ghostty_mouse_encoder_setopt(instance->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
    ghostty_mouse_encoder_setopt(instance->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_last_cell);
    ghostty_mouse_event_set_action(instance->mouse_event, static_cast<GhosttyMouseAction>(action));
    ghostty_mouse_event_set_button(instance->mouse_event, static_cast<GhosttyMouseButton>(button));
    ghostty_mouse_event_set_mods(instance->mouse_event, static_cast<GhosttyMods>(modifiers));
    ghostty_mouse_event_set_position(instance->mouse_event, GhosttyMousePosition{x, y});
    char buffer[128];
    size_t written = 0;
    GhosttyResult result = ghostty_mouse_encoder_encode(
        instance->mouse_encoder, instance->mouse_event, buffer, sizeof(buffer), &written);
    require_success(result, "mouse encode");
    return byte_array(env, buffer, written);
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectWord(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    GhosttyPoint point{GHOSTTY_POINT_TAG_VIEWPORT,
        {.coordinate = {static_cast<uint16_t>(column), static_cast<uint32_t>(row)}}};
    auto ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(instance->terminal, point, &ref) != GHOSTTY_SUCCESS) return false;
    auto options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
    options.ref = ref;
    auto selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_terminal_select_word(instance->terminal, &options, &selection) != GHOSTTY_SUCCESS) return false;
    require_success(ghostty_terminal_set(instance->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection),
        "install selection");
    return true;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return false;
  }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeExtendSelection(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    auto selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_terminal_get(instance->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) != GHOSTTY_SUCCESS) return false;
    GhosttyPoint point{GHOSTTY_POINT_TAG_VIEWPORT,
        {.coordinate = {static_cast<uint16_t>(column), static_cast<uint32_t>(row)}}};
    auto ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(instance->terminal, point, &ref) != GHOSTTY_SUCCESS) return false;
    selection.end = ref;
    require_success(ghostty_terminal_set(instance->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection),
        "extend selection");
    return true;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return false;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSelectedText(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    auto options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.unwrap = true;
    options.trim = true;
    uint8_t* bytes = nullptr;
    size_t length = 0;
    const GhosttyResult result = ghostty_terminal_selection_format_alloc(
        instance->terminal, nullptr, options, &bytes, &length);
    if (result == GHOSTTY_NO_VALUE) return env->NewStringUTF("");
    require_success(result, "format selection");
    jstring value = utf8_java_string(env, bytes, length);
    ghostty_free(nullptr, bytes, length);
    return value;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeClearSelection(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    require_success(ghostty_terminal_set(instance->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nullptr),
        "clear selection");
  } catch (const std::exception& error) {
    throw_java(env, error);
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeHyperlink(
    JNIEnv* env, jobject, jlong handle, jint column, jint row) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    GhosttyPoint point{GHOSTTY_POINT_TAG_VIEWPORT,
        {.coordinate = {static_cast<uint16_t>(column), static_cast<uint32_t>(row)}}};
    auto ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(instance->terminal, point, &ref) != GHOSTTY_SUCCESS) return env->NewStringUTF("");
    size_t length = 0;
    GhosttyResult result = ghostty_grid_ref_hyperlink_uri(&ref, nullptr, 0, &length);
    if (result == GHOSTTY_SUCCESS && length == 0) return env->NewStringUTF("");
    if (result != GHOSTTY_OUT_OF_SPACE) {
      require_success(result, "query hyperlink");
    }
    std::vector<uint8_t> bytes(length);
    require_success(ghostty_grid_ref_hyperlink_uri(&ref, bytes.data(), bytes.size(), &length),
        "read hyperlink");
    return utf8_java_string(env, bytes.data(), length);
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodeKey(
    JNIEnv* env, jobject, jlong handle, jstring keyName, jstring text,
    jint modifiers, jint action) {
  try {
    NativeTerminal* instance = from_handle(handle);
    const std::string key_name = java_string(env, keyName);
    const std::string utf8 = java_utf8(env, text);
    std::lock_guard lock(instance->mutex);
    ghostty_key_encoder_setopt_from_terminal(instance->key_encoder, instance->terminal);
    ghostty_key_event_set_action(instance->key_event, static_cast<GhosttyKeyAction>(action));
    ghostty_key_event_set_key(instance->key_event, key_from_name(key_name));
    ghostty_key_event_set_mods(instance->key_event, static_cast<GhosttyMods>(modifiers));
    ghostty_key_event_set_consumed_mods(instance->key_event, 0);
    ghostty_key_event_set_composing(instance->key_event, false);
    ghostty_key_event_set_unshifted_codepoint(instance->key_event, 0);
    ghostty_key_event_set_utf8(instance->key_event, utf8.data(), utf8.size());
    char buffer[128];
    size_t written = 0;
    GhosttyResult result = ghostty_key_encoder_encode(
        instance->key_encoder, instance->key_event, buffer, sizeof(buffer), &written);
    if (result == GHOSTTY_OUT_OF_SPACE) {
      std::vector<char> dynamic(written);
      require_success(ghostty_key_encoder_encode(instance->key_encoder, instance->key_event,
          dynamic.data(), dynamic.size(), &written), "key encode");
      return byte_array(env, dynamic.data(), written);
    }
    require_success(result, "key encode");
    return byte_array(env, buffer, written);
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativePasteIsSafe(
    JNIEnv* env, jobject, jstring text) {
  const std::string utf8 = java_utf8(env, text);
  return ghostty_paste_is_safe(utf8.data(), utf8.size());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeEncodePaste(
    JNIEnv* env, jobject, jlong handle, jstring text) {
  try {
    NativeTerminal* instance = from_handle(handle);
    const std::string utf8 = java_utf8(env, text);
    std::vector<char> mutable_input(utf8.begin(), utf8.end());
    std::lock_guard lock(instance->mutex);
    GhosttyTerminalModeConfig mode{GHOSTTY_MODE_BRACKETED_PASTE, false};
    require_success(ghostty_terminal_get(instance->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode),
        "read bracketed paste mode");
    std::vector<char> output(mutable_input.size() + (mode.value ? 12 : 0));
    size_t written = 0;
    require_success(ghostty_paste_encode(mutable_input.data(), mutable_input.size(), mode.value,
        output.data(), output.size(), &written), "paste encode");
    return byte_array(env, output.data(), written);
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeWrite(
    JNIEnv* env, jobject, jlong handle, jbyteArray data, jint offset, jint length) {
  try {
    NativeTerminal* instance = from_handle(handle);
    const jsize size = env->GetArrayLength(data);
    if (offset < 0 || length < 0 || offset > size - length) {
      throw std::invalid_argument("Invalid terminal write range");
    }
    std::vector<uint8_t> copy(static_cast<size_t>(length));
    env->GetByteArrayRegion(data, offset, length, reinterpret_cast<jbyte*>(copy.data()));
    std::lock_guard lock(instance->mutex);
    ghostty_terminal_vt_write(instance->terminal, copy.data(), copy.size());
  } catch (const std::exception& error) {
    throw_java(env, error);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeResize(
    JNIEnv* env, jobject, jlong handle, jint columns, jint rows,
    jint cellWidth, jint cellHeight) {
  try {
    NativeTerminal* instance = from_handle(handle);
    if (columns <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0 ||
        columns > UINT16_MAX || rows > UINT16_MAX) {
      throw std::invalid_argument("Invalid terminal dimensions");
    }
    std::lock_guard lock(instance->mutex);
    require_success(ghostty_terminal_resize(instance->terminal,
        static_cast<uint16_t>(columns), static_cast<uint16_t>(rows),
        static_cast<uint32_t>(cellWidth), static_cast<uint32_t>(cellHeight)), "terminal resize");
  } catch (const std::exception& error) {
    throw_java(env, error);
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeKittyFrame(
    JNIEnv* env, jobject, jlong handle, jlong knownGeneration) {
  try {
    struct Image {
      uint32_t id;
      uint32_t width;
      uint32_t height;
      GhosttyKittyImageFormat format;
      uint64_t generation;
      const uint8_t* data;
      size_t data_len;
    };
    struct Placement {
      uint32_t image_id;
      int32_t z;
      uint32_t x_offset;
      uint32_t y_offset;
      GhosttyKittyGraphicsPlacementRenderInfo render;
    };

    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    GhosttyKittyGraphics graphics = nullptr;
    if (ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) != GHOSTTY_SUCCESS || graphics == nullptr) {
      std::vector<uint8_t> empty;
      append_i64(empty, 0);
      append_i32(empty, 0);
      append_i32(empty, 0);
      return byte_array(env, reinterpret_cast<const char*>(empty.data()), empty.size());
    }
    uint64_t generation = 0;
    require_success(ghostty_kitty_graphics_get(
        graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation), "Kitty generation");
    require_success(ghostty_kitty_graphics_get(graphics,
        GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &instance->kitty_placements),
        "Kitty placements");

    std::unordered_map<uint32_t, Image> images;
    std::vector<Placement> placements;
    while (ghostty_kitty_graphics_placement_next(instance->kitty_placements)) {
      uint32_t image_id = 0;
      uint32_t x_offset = 0;
      uint32_t y_offset = 0;
      int32_t z = 0;
      bool is_virtual = false;
      require_success(ghostty_kitty_graphics_placement_get(instance->kitty_placements,
          GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &image_id), "Kitty placement image");
      require_success(ghostty_kitty_graphics_placement_get(instance->kitty_placements,
          GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &is_virtual), "Kitty placement type");
      if (is_virtual) continue;
      require_success(ghostty_kitty_graphics_placement_get(instance->kitty_placements,
          GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &x_offset), "Kitty x offset");
      require_success(ghostty_kitty_graphics_placement_get(instance->kitty_placements,
          GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &y_offset), "Kitty y offset");
      require_success(ghostty_kitty_graphics_placement_get(instance->kitty_placements,
          GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z), "Kitty z index");
      auto render = GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo);
      GhosttyKittyGraphicsImage image = ghostty_kitty_graphics_image(graphics, image_id);
      if (image == nullptr || ghostty_kitty_graphics_placement_render_info(
          instance->kitty_placements, image, instance->terminal, &render) != GHOSTTY_SUCCESS ||
          !render.viewport_visible) continue;
      placements.push_back(Placement{image_id, z, x_offset, y_offset, render});
      if (images.contains(image_id)) continue;
      Image value{image_id, 0, 0, GHOSTTY_KITTY_IMAGE_FORMAT_RGBA, 0, nullptr, 0};
      require_success(ghostty_kitty_graphics_image_get(image,
          GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &value.width), "Kitty image width");
      require_success(ghostty_kitty_graphics_image_get(image,
          GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &value.height), "Kitty image height");
      require_success(ghostty_kitty_graphics_image_get(image,
          GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &value.format), "Kitty image format");
      require_success(ghostty_kitty_graphics_image_get(image,
          GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &value.generation), "Kitty image generation");
      require_success(ghostty_kitty_graphics_image_get(image,
          GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &value.data_len), "Kitty image length");
      if (ghostty_kitty_graphics_image_get(image,
          GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &value.data) != GHOSTTY_SUCCESS) continue;
      images.emplace(image_id, value);
    }

    std::vector<uint8_t> result;
    append_i64(result, generation);
    append_i32(result, static_cast<int32_t>(images.size()));
    const bool include_pixels = generation != static_cast<uint64_t>(knownGeneration);
    for (const auto& [id, image] : images) {
      append_i32(result, id);
      append_i64(result, image.generation);
      append_i32(result, image.width);
      append_i32(result, image.height);
      append_i32(result, image.format);
      const size_t data_len = include_pixels ? image.data_len : 0;
      append_i32(result, static_cast<int32_t>(data_len));
      if (data_len > 0) result.insert(result.end(), image.data, image.data + data_len);
    }
    append_i32(result, static_cast<int32_t>(placements.size()));
    for (const Placement& placement : placements) {
      append_i32(result, placement.image_id);
      append_i32(result, placement.z);
      append_i32(result, placement.x_offset);
      append_i32(result, placement.y_offset);
      append_i32(result, placement.render.pixel_width);
      append_i32(result, placement.render.pixel_height);
      append_i32(result, placement.render.viewport_col);
      append_i32(result, placement.render.viewport_row);
      append_i32(result, placement.render.source_x);
      append_i32(result, placement.render.source_y);
      append_i32(result, placement.render.source_width);
      append_i32(result, placement.render.source_height);
    }
    return byte_array(env, reinterpret_cast<const char*>(result.data()), result.size());
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeSnapshot(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    require_success(ghostty_render_state_update(instance->render, instance->terminal), "render update");

    uint16_t columns = 0;
    uint16_t row_count = 0;
    auto cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    auto colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    GhosttyTerminalScrollbar scrollbar{};
    GhosttyString title{};
    GhosttyString pwd{};
    bool cursor_at_prompt = false;
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_COLS, &columns), "read columns");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &row_count), "read rows");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor), "read cursor");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors), "read colors");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty), "read dirty state");
    if (instance->first_snapshot) {
      dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
      require_success(ghostty_render_state_set(instance->render,
          GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty), "force initial render");
      instance->first_snapshot = false;
    }
    require_success(ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar), "read scrollbar");
    require_success(ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_TITLE, &title), "read title");
    require_success(ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_PWD, &pwd), "read pwd");
    require_success(ghostty_terminal_get(instance->terminal,
        GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &cursor_at_prompt), "read prompt state");
    require_success(ghostty_render_state_get(instance->render,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &instance->rows), "populate rows");

    std::vector<uint8_t> result;
    result.reserve(40 + static_cast<size_t>(columns) * row_count * 17);
    append_i32(result, kSnapshotMagic);
    append_i32(result, columns);
    append_i32(result, row_count);
    append_i32(result, argb(colors.background));
    append_i32(result, argb(colors.foreground));
    append_i32(result, colors.cursor_has_value ? argb(colors.cursor) : argb(colors.foreground));
    append_i32(result, cursor.viewport_has_value ? cursor.viewport_x : -1);
    append_i32(result, cursor.viewport_has_value ? cursor.viewport_y : -1);
    append_i32(result, cursor.visible ? cursor.visual_style + 1 : 0);
    append_i32(result, static_cast<int32_t>(std::min<uint64_t>(scrollbar.total, INT32_MAX)));
    append_i32(result, static_cast<int32_t>(std::min<uint64_t>(scrollbar.offset, INT32_MAX)));
    append_i32(result, static_cast<int32_t>(std::min<uint64_t>(scrollbar.len, INT32_MAX)));
    append_i32(result, (cursor.blinking ? 1 : 0) | (cursor.password_input ? 2 : 0) |
        (cursor.wide_tail ? 4 : 0) | (cursor_at_prompt ? 8 : 0));
    append_i32(result, static_cast<int32_t>(title.len));
    if (title.len > 0) result.insert(result.end(), title.ptr, title.ptr + title.len);
    append_i32(result, static_cast<int32_t>(pwd.len));
    if (pwd.len > 0) result.insert(result.end(), pwd.ptr, pwd.ptr + pwd.len);
    append_i32(result, static_cast<int32_t>(dirty));
    const size_t update_count_offset = result.size();
    append_i32(result, 0);

    std::vector<uint8_t> grapheme(32);
    int rows_written = 0;
    uint16_t row_y = 0;
    while (ghostty_render_state_row_iterator_next_dirty(instance->rows, &row_y)) {
      append_i32(result, row_y);
      require_success(ghostty_render_state_row_get(instance->rows,
          GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &instance->cells), "populate cells");
      int cells_written = 0;
      while (ghostty_render_state_row_cells_next(instance->cells)) {
        GhosttyColorRgb foreground{};
        GhosttyColorRgb background{};
        auto style = GHOSTTY_INIT_SIZED(GhosttyStyle);
        const GhosttyResult fg_result = ghostty_render_state_row_cells_get(instance->cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground);
        const GhosttyResult bg_result = ghostty_render_state_row_cells_get(instance->cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background);
        require_success(ghostty_render_state_row_cells_get(instance->cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style), "read cell style");

        int32_t foreground_argb = fg_result == GHOSTTY_SUCCESS ? argb(foreground) : argb(colors.foreground);
        int32_t background_argb = bg_result == GHOSTTY_SUCCESS ? argb(background) : argb(colors.background);
        if (style.inverse) std::swap(foreground_argb, background_argb);
        int32_t flags = (style.bold ? 1 : 0) | (style.italic ? 2 : 0) |
            (style.faint ? 4 : 0) | (style.underline ? 8 : 0) |
            (style.strikethrough ? 16 : 0) | (style.invisible ? 32 : 0);
        bool selected = false;
        if (ghostty_render_state_row_cells_get(instance->cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected) == GHOSTTY_SUCCESS && selected) {
          flags |= 64;
        }

        GhosttyBuffer text{grapheme.data(), grapheme.size(), 0};
        GhosttyResult text_result = ghostty_render_state_row_cells_get(instance->cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
        if (text_result == GHOSTTY_OUT_OF_SPACE) {
          grapheme.resize(text.len);
          text = GhosttyBuffer{grapheme.data(), grapheme.size(), 0};
          text_result = ghostty_render_state_row_cells_get(instance->cells,
              GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
        }
        require_success(text_result, "read cell text");
        append_i32(result, foreground_argb);
        append_i32(result, background_argb);
        append_i32(result, flags);
        append_i32(result, static_cast<int32_t>(text.len));
        result.insert(result.end(), grapheme.begin(), grapheme.begin() + text.len);
        cells_written++;
      }
      while (cells_written++ < columns) {
        append_i32(result, argb(colors.foreground));
        append_i32(result, argb(colors.background));
        append_i32(result, 0);
        append_i32(result, 0);
      }
      rows_written++;
    }
    replace_i32(result, update_count_offset, rows_written);
    require_success(ghostty_render_state_clean(instance->render), "render clean");

    jbyteArray output = env->NewByteArray(static_cast<jsize>(result.size()));
    env->SetByteArrayRegion(output, 0, static_cast<jsize>(result.size()),
        reinterpret_cast<const jbyte*>(result.data()));
    return output;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeScroll(
    JNIEnv* env, jobject, jlong handle, jint deltaRows) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    GhosttyTerminalScrollViewport behavior{};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
    behavior.value.delta = deltaRows;
    ghostty_terminal_scroll_viewport(instance->terminal, behavior);
  } catch (const std::exception& error) {
    throw_java(env, error);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeScrollToBottom(
    JNIEnv* env, jobject, jlong handle) {
  try {
    NativeTerminal* instance = from_handle(handle);
    std::lock_guard lock(instance->mutex);
    GhosttyTerminalScrollViewport behavior{};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
    ghostty_terminal_scroll_viewport(instance->terminal, behavior);
  } catch (const std::exception& error) {
    throw_java(env, error);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeDestroy(
    JNIEnv*, jobject, jlong handle) {
  delete reinterpret_cast<NativeTerminal*>(handle);
}
