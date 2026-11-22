#ifndef SEANCE_CORE_H
#define SEANCE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Version of this C ABI. Bumped on any incompatible change. */
uint32_t sc_abi_version(void);

/* Reconnect policy. The state is caller-owned; treat it as opaque and
 * initialize it with sc_reconnect_init(). Times are milliseconds from any
 * monotonic clock. */
typedef struct {
  bool enabled;
  uint32_t max_attempts;
  uint8_t backoff;
  int64_t started_at;
  uint32_t attempts;
  int64_t paused_at;
  int64_t paused_duration;
} ScReconnectPolicy;

enum { SC_BACKOFF_FAST = 0, SC_BACKOFF_BALANCED = 1, SC_BACKOFF_CONSERVATIVE = 2 };

/** Returns 0 on success, -1 if max_attempts is outside 1...10 or backoff is unknown. */
int32_t sc_reconnect_init(ScReconnectPolicy* policy, bool enabled, uint32_t max_attempts, uint8_t backoff);
/** Changes settings while keeping attempts and the retry window. Same return codes as init. */
int32_t sc_reconnect_configure(ScReconnectPolicy* policy, bool enabled, uint32_t max_attempts, uint8_t backoff);
/** Writes the delay before the next attempt and returns true, or returns false when no attempts remain. */
bool sc_reconnect_next_delay(const ScReconnectPolicy* policy, int64_t now_ms, int64_t* out_delay_ms);
bool sc_reconnect_begin_attempt(ScReconnectPolicy* policy, int64_t now_ms);
void sc_reconnect_reset(ScReconnectPolicy* policy);
void sc_reconnect_pause(ScReconnectPolicy* policy, int64_t now_ms);
void sc_reconnect_resume(ScReconnectPolicy* policy, int64_t now_ms);
uint32_t sc_reconnect_attempt_count(const ScReconnectPolicy* policy);
int64_t sc_reconnect_window_ms(const ScReconnectPolicy* policy);


/* ---------------------------------------------------------------------------
 * Terminal engine
 *
 * A thin, shared layer over libghostty-vt (ADR 0012). The core never does I/O:
 * the host feeds bytes from its transport with sc_engine_write() and sends the
 * bytes the encode and drain functions return back to the transport.
 *
 * Conventions:
 *  - Functions returning int32_t return a negative ScStatus on failure. Query
 *    functions return 1 (true) or 0 (false) on success.
 *  - Functions that produce bytes fill an ScBytes. Release it with
 *    sc_bytes_free(); an empty result has ptr == NULL and len == 0 and needs no
 *    release. Results never alias engine memory, so they stay valid across later
 *    calls.
 *  - Every function taking an ScEngine* locks that engine, so one engine may be
 *    used from several threads. ScEngine* must not be used after
 *    sc_engine_free().
 *  - Colors are 0xRRGGBB. Multi-byte integers in the wire formats are
 *    little-endian; "string" means an int32 byte length followed by bytes.
 *  - The host must link libghostty-vt itself. To decode PNG for the Kitty
 *    graphics protocol, register a decoder with ghostty_sys_set() before
 *    creating engines.
 * ------------------------------------------------------------------------- */

typedef struct ScEngine ScEngine;

typedef enum {
  SC_OK = 0,
  SC_ERROR_INVALID_ARGUMENT = -1,
  SC_ERROR_OUT_OF_MEMORY = -2,
  /** libghostty-vt reported a failure (for example a corrupt saved state). */
  SC_ERROR_ENGINE = -3,
  SC_ERROR_TOO_LARGE = -4,
} ScStatus;

/** Caller-owned bytes produced by the engine. */
typedef struct {
  uint8_t* ptr;
  size_t len;
} ScBytes;

void sc_bytes_free(uint8_t* ptr, size_t len);

typedef struct {
  /** sizeof(ScEngineConfig). */
  size_t size;
  uint16_t cols;
  uint16_t rows;
  /** When false, libghostty's default foreground, background and cursor apply. */
  bool has_colors;
  uint32_t foreground;
  uint32_t background;
  uint32_t cursor;
  /** 256 palette entries, or NULL for libghostty's default palette. */
  const uint32_t* palette;
  /** 0 selects the default of 10,000 lines. */
  uint32_t scrollback_lines;
} ScEngineConfig;

int32_t sc_engine_new(const ScEngineConfig* config, ScEngine** out);
/** Recreates an engine from sc_engine_encode_state() output. Colors and scrollback come from the state. */
int32_t sc_engine_restore(const uint8_t* data, size_t len, ScEngine** out);
void sc_engine_free(ScEngine* engine);

/** Feeds output from the remote host to the terminal. */
int32_t sc_engine_write(ScEngine* engine, const uint8_t* data, size_t len);
/** Cell sizes are in pixels and feed size reports and Kitty graphics placement. */
int32_t sc_engine_resize(ScEngine* engine, uint32_t cols, uint32_t rows, uint32_t cell_width, uint32_t cell_height);
/** Scrolls the local viewport; positive moves towards newer output. */
void sc_engine_scroll(ScEngine* engine, int32_t delta_rows);
void sc_engine_scroll_to_bottom(ScEngine* engine);

/**
 * Render snapshot of the dirty rows since the previous snapshot (all rows the
 * first time and after a full invalidation). Wire format, magic 'GVT1'
 * (0x47565431):
 *   magic, columns, rows, background, foreground, cursor color (ARGB),
 *   cursor x, cursor y (-1 outside the viewport), cursor style + 1 (0 hidden),
 *   scroll total, scroll offset, scroll visible,
 *   cursor flags (1 blinking, 2 password input, 4 wide tail, 8 at prompt),
 *   title, pwd, dirty (0 clean, 1 partial, 2 full), dirty row count, then per
 *   dirty row: row index and `columns` cells of
 *   { foreground, background, flags, underline color (ARGB), text }.
 * Cell flags: 1 bold, 2 italic, 4 faint, 8 blink, 16 strikethrough, 32
 * invisible, 64 selected, 128 overline, bits 8-10 underline style. Inverse is
 * already applied to the colors.
 */
int32_t sc_engine_snapshot(ScEngine* engine, ScBytes* out);

/**
 * Kitty graphics visible in the viewport: generation (int64), image count,
 * per image { id, generation (int64), width, height, format, pixel length,
 * pixels } (pixel length is 0 when known_generation equals the current
 * generation), placement count, per placement { image id, z, x offset, y offset,
 * pixel width, pixel height, viewport column, viewport row, source x, source y,
 * source width, source height }.
 */
int32_t sc_engine_kitty_frame(ScEngine* engine, uint64_t known_generation, ScBytes* out);

/** libghostty-vt's saved-state encoding of the terminal, for sc_engine_restore(). */
int32_t sc_engine_encode_state(ScEngine* engine, ScBytes* out);

/**
 * Takes the effects queued since the last call. Wire format: bells,
 * progress state (-1 none, else 0 remove, 1 set, 2 error, 3 indeterminate,
 * 4 pause), progress percent (-1 unknown), unknown-sequence count,
 * VT processing error (0/1), pty write (string; bytes the terminal wants sent
 * to the host, such as device reports), clipboard write count and per write
 * { kind (0 clear, 1 text), text }, notification count and per notification
 * { title, body }. Queues are bounded; clipboard writes accept only the
 * standard clipboard with text/plain content up to 1 MiB.
 */
int32_t sc_engine_drain_effects(ScEngine* engine, ScBytes* out);

/** Input encoding. Results are the bytes to send to the host. */

/** 1 when the application enabled mouse reporting. */
int32_t sc_engine_is_mouse_tracking(ScEngine* engine);
/** Empty unless the application enabled focus reporting (DEC 1004). */
int32_t sc_engine_encode_focus(ScEngine* engine, bool focused, ScBytes* out);

typedef struct {
  uint32_t action; /* GhosttyMouseAction: 0 press, 1 release, 2 motion */
  uint32_t button; /* GhosttyMouseButton: 1 left, 2 right, 3 middle, 4 wheel up, 5 wheel down */
  float x;         /* pixels from the top-left of the terminal area */
  float y;
  uint32_t modifiers; /* GhosttyMods: 1 shift, 2 ctrl, 4 alt, 8 super */
  uint32_t width;     /* terminal area in pixels */
  uint32_t height;
  uint32_t cell_width;
  uint32_t cell_height;
  bool any_pressed; /* some button is held (for motion events) */
} ScMouseInput;

int32_t sc_engine_encode_mouse(ScEngine* engine, const ScMouseInput* input, ScBytes* out);

/**
 * Encodes a scroll gesture. `rows` is positive when content moves down (towards
 * newer output); the count is capped at 10 per call.
 *  - Mouse tracking on: wheel up/down press events (buttons 4 and 5) in the
 *    reporting format the application chose.
 *  - Alternate screen with alternate-scroll mode (DEC 1007) and no mouse
 *    tracking: Down/Up arrow keys honoring application cursor mode.
 *  - Otherwise: empty. The host should scroll its local scrollback with
 *    sc_engine_scroll().
 */
int32_t sc_engine_encode_scroll(ScEngine* engine, int32_t rows, ScBytes* out);

/**
 * Encodes a key press. `name` is "a".."z", "0".."9", "F1".."F25" or an
 * upper-case W3C-style name: ENTER, TAB, ESCAPE, SPACE, BACKSPACE, DELETE,
 * INSERT, HOME, END, PAGE_UP, PAGE_DOWN, ARROW_UP/DOWN/LEFT/RIGHT, MINUS,
 * EQUAL, COMMA, PERIOD, SLASH, SEMICOLON, QUOTE, BACKQUOTE, BACKSLASH,
 * BRACKET_LEFT/RIGHT, NUMPAD_*, modifier keys such as SHIFT_LEFT, and so on
 * (see core/src/keys.zig). Unknown names encode as an unidentified key, which
 * only produces output when `text` is not empty. `text` is the UTF-8 the key
 * generates. `modifiers` is GhosttyMods; `action` is 0 release, 1 press, 2 repeat.
 */
int32_t sc_engine_encode_key(ScEngine* engine, const uint8_t* name, size_t name_len,
                             const uint8_t* text, size_t text_len, uint32_t modifiers,
                             uint32_t action, ScBytes* out);

/** Whether pasting `data` is free of control sequences that could run commands. */
bool sc_paste_is_safe(const uint8_t* data, size_t len);
/** Sanitizes pasted text and adds bracketed paste markers when the application enabled them. */
int32_t sc_engine_encode_paste(ScEngine* engine, const uint8_t* data, size_t len, ScBytes* out);

/** Selection, search and text. Coordinates are viewport columns and rows. */
int32_t sc_engine_select_word(ScEngine* engine, int32_t column, int32_t row);
int32_t sc_engine_select_range(ScEngine* engine, int32_t start_column, int32_t end_column, int32_t row);
/** Moves the selection end. Returns 0 when nothing is selected. */
int32_t sc_engine_extend_selection(ScEngine* engine, int32_t column, int32_t row);
int32_t sc_engine_set_selection_endpoint(ScEngine* engine, bool start, int32_t column, int32_t row);
/** {startColumn, startRow, endColumn, endRow}; -1 for an end outside the viewport or no selection. */
void sc_engine_selection_endpoints(ScEngine* engine, int32_t out[4]);
bool sc_engine_has_selection(ScEngine* engine);
int32_t sc_engine_clear_selection(ScEngine* engine);
/** Selects the output of the latest command (needs OSC 133 shell integration). */
int32_t sc_engine_select_latest_output(ScEngine* engine);
int32_t sc_engine_select_output(ScEngine* engine, int32_t column, int32_t row);
/** Scrolls to the previous (direction < 0) or next shell prompt. */
int32_t sc_engine_jump_prompt(ScEngine* engine, int32_t direction);
/** UTF-8 selection text, unwrapped and trimmed; empty when nothing is selected. */
int32_t sc_engine_selected_text(ScEngine* engine, ScBytes* out);
/** All text including scrollback as UTF-8, unwrapped and trimmed. */
int32_t sc_engine_plain_text(ScEngine* engine, ScBytes* out);
/**
 * Case-insensitive (ASCII) search across scrollback and screen, joining
 * soft-wrapped rows. Selects the match and scrolls it into view; repeating the
 * same query steps to the next (direction >= 0) or previous match, wrapping.
 * Queries are limited to 1024 bytes. Returns 1 when a match was selected.
 */
int32_t sc_engine_search(ScEngine* engine, const uint8_t* query, size_t query_len, int32_t direction);
/** The OSC 8 hyperlink URI at the cell; empty when there is none. */
int32_t sc_engine_hyperlink(ScEngine* engine, int32_t column, int32_t row, ScBytes* out);

#ifdef __cplusplus
}
#endif

#endif
