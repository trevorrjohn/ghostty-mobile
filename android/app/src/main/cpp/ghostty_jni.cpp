#include <jni.h>
#include <ghostty/vt.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int32_t kSnapshotMagic = 0x47565431; // GVT1

struct NativeTerminal {
  GhosttyTerminal terminal = nullptr;
  GhosttyRenderState render = nullptr;
  GhosttyRenderStateRowIterator rows = nullptr;
  GhosttyRenderStateRowCells cells = nullptr;
  std::mutex mutex;

  ~NativeTerminal() {
    ghostty_render_state_row_cells_free(cells);
    ghostty_render_state_row_iterator_free(rows);
    ghostty_render_state_free(render);
    ghostty_terminal_free(terminal);
  }
};

void require_success(GhosttyResult result, const char* operation) {
  if (result != GHOSTTY_SUCCESS) {
    throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(result));
  }
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
    JNIEnv* env, jobject, jint columns, jint rows) {
  try {
    if (columns <= 0 || rows <= 0 || columns > UINT16_MAX || rows > UINT16_MAX) {
      throw std::invalid_argument("Invalid terminal dimensions");
    }
    auto instance = std::make_unique<NativeTerminal>();
    require_success(ghostty_terminal_new(
        nullptr, &instance->terminal,
        static_cast<uint16_t>(columns), static_cast<uint16_t>(rows)), "terminal create");

    const GhosttyColorRgb foreground{0xf1, 0xf3, 0xf8};
    const GhosttyColorRgb background{0x0a, 0x0c, 0x10};
    const GhosttyColorRgb cursor{0x8b, 0xe9, 0xb3};
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground), "foreground color");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background), "background color");
    require_success(ghostty_terminal_set(instance->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor), "cursor color");

    require_success(ghostty_render_state_new(nullptr, &instance->render), "render create");
    require_success(ghostty_render_state_row_iterator_new(nullptr, &instance->rows), "row iterator create");
    require_success(ghostty_render_state_row_cells_new(nullptr, &instance->cells), "cell iterator create");
    return reinterpret_cast<jlong>(instance.release());
  } catch (const std::exception& error) {
    throw_java(env, error);
    return 0;
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
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_COLS, &columns), "read columns");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &row_count), "read rows");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor), "read cursor");
    require_success(ghostty_render_state_get(instance->render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors), "read colors");
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

    std::vector<uint8_t> grapheme(32);
    int rows_written = 0;
    while (ghostty_render_state_row_iterator_next(instance->rows)) {
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
    while (rows_written++ < row_count) {
      for (int x = 0; x < columns; x++) {
        append_i32(result, argb(colors.foreground));
        append_i32(result, argb(colors.background));
        append_i32(result, 0);
        append_i32(result, 0);
      }
    }
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
Java_dev_ghostty_connect_terminal_bridge_GhosttyTerminal_nativeDestroy(
    JNIEnv*, jobject, jlong handle) {
  delete reinterpret_cast<NativeTerminal*>(handle);
}
