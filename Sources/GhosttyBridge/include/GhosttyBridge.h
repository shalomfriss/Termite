#ifndef GHOSTTY_BRIDGE_H
#define GHOSTTY_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GTSession GTSession;

enum {
    GT_STYLE_BOLD = 1 << 0,
    GT_STYLE_ITALIC = 1 << 1,
    GT_STYLE_FAINT = 1 << 2,
    GT_STYLE_INVERSE = 1 << 4,
    GT_STYLE_INVISIBLE = 1 << 5,
    GT_STYLE_STRIKETHROUGH = 1 << 6,
    GT_STYLE_UNDERLINE_MASK = 7 << 8,
};

typedef struct {
    uint8_t text[32];
    uint8_t text_len;
    uint8_t fg_r, fg_g, fg_b;
    uint8_t bg_r, bg_g, bg_b;
    uint16_t style;
    uint8_t semantic_content;
} GTCell;

typedef struct {
    uint32_t image_id;
    uint32_t placement_id;
    int32_t viewport_col;
    int32_t viewport_row;
    uint32_t pixel_width;
    uint32_t pixel_height;
    uint32_t image_width;
    uint32_t image_height;
    uint32_t source_x;
    uint32_t source_y;
    uint32_t source_width;
    uint32_t source_height;
    uint32_t cell_offset_x;
    uint32_t cell_offset_y;
    int32_t layer;
    int32_t z;
    int32_t pixel_format;
    const uint8_t *pixels;
    size_t pixels_len;
} GTImage;

enum {
    GT_SEMANTIC_OUTPUT = 0,
    GT_SEMANTIC_INPUT = 1,
    GT_SEMANTIC_PROMPT = 2,
};

typedef struct {
    uint16_t cols;
    uint16_t rows;
    uint16_t cursor_x;
    uint16_t cursor_y;
    bool cursor_visible;
    uint8_t cursor_r, cursor_g, cursor_b;
    const GTCell *cells;
    const uint8_t *row_semantics;
    const GTImage *images;
    size_t image_count;
    const char *title;
    const char *working_directory;
    uint64_t scroll_total;
    uint64_t scroll_offset;
    uint64_t scroll_length;
    bool alternate_screen;
    bool mouse_reporting;
    bool focus_reporting;
    bool cursor_at_prompt;
    bool bracketed_paste;
} GTFrame;

enum {
    GT_MOUSE_ACTION_PRESS = 0,
    GT_MOUSE_ACTION_RELEASE = 1,
    GT_MOUSE_ACTION_MOTION = 2,
};

enum {
    GT_MOUSE_BUTTON_NONE = 0,
    GT_MOUSE_BUTTON_LEFT = 1,
    GT_MOUSE_BUTTON_RIGHT = 2,
    GT_MOUSE_BUTTON_MIDDLE = 3,
    GT_MOUSE_BUTTON_SCROLL_UP = 4,
    GT_MOUSE_BUTTON_SCROLL_DOWN = 5,
    GT_MOUSE_BUTTON_SCROLL_LEFT = 6,
    GT_MOUSE_BUTTON_SCROLL_RIGHT = 7,
};

enum {
    GT_MOD_SHIFT = 1 << 0,
    GT_MOD_CONTROL = 1 << 1,
    GT_MOD_ALT = 1 << 2,
    GT_MOD_SUPER = 1 << 3,
};

/** Load libghostty-vt. Returns NULL when available, otherwise an error string. */
const char *gt_runtime_error(void);

/** Create a shell, PTY, Ghostty terminal, and render state. */
GTSession *gt_session_create(uint16_t cols, uint16_t rows, const char **error);
GTSession *gt_session_create_at(uint16_t cols, uint16_t rows,
                                const char *working_directory, const char **error);
GTSession *gt_session_create_configured(uint16_t cols, uint16_t rows,
                                        const char *working_directory,
                                        const char *shell_integration_directory,
                                        const char **error);
void gt_session_destroy(GTSession *session);

/** Read pending PTY output into Ghostty. Returns true when the screen changed. */
bool gt_session_poll(GTSession *session);

/** Read at most max_bytes of pending PTY output, keeping a UI frame bounded. */
bool gt_session_poll_budgeted(GTSession *session, size_t max_bytes);

/** Return a borrowed frame, valid until the next call for this session. */
const GTFrame *gt_session_frame(GTSession *session);

bool gt_session_write(GTSession *session, const uint8_t *bytes, size_t len);
bool gt_session_set_echo(GTSession *session, bool enabled);
/** Encode and write application mouse/focus input using Ghostty's VT state. */
bool gt_session_send_mouse(GTSession *session, int action, int button,
                           uint16_t modifiers, float x, float y,
                           uint32_t screen_width, uint32_t screen_height,
                           uint32_t cell_width, uint32_t cell_height,
                           uint32_t padding_left, uint32_t padding_top,
                           bool any_button_pressed);
bool gt_session_send_focus(GTSession *session, bool focused);
/** Feed synthetic terminal output directly into libghostty-vt. */
bool gt_session_feed_output(GTSession *session, const uint8_t *bytes, size_t len);
/** Mark frontend-observed shell input/output boundaries using OSC 133. */
void gt_session_mark_input(GTSession *session);
void gt_session_mark_output(GTSession *session);
/** Copy raw PTY output captured since the latest command began. */
size_t gt_session_command_output(GTSession *session, uint8_t *buffer, size_t capacity);
bool gt_session_scroll(GTSession *session, intptr_t rows);
bool gt_session_scroll_to_bottom(GTSession *session);
bool gt_session_resize(GTSession *session, uint16_t cols, uint16_t rows,
                       uint32_t cell_width_px, uint32_t cell_height_px);
bool gt_session_is_running(GTSession *session);
int gt_session_exit_status(GTSession *session);

#ifdef __cplusplus
}
#endif
#endif
