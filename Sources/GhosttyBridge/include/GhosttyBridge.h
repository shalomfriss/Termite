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
} GTCell;

typedef struct {
    uint16_t cols;
    uint16_t rows;
    uint16_t cursor_x;
    uint16_t cursor_y;
    bool cursor_visible;
    uint8_t cursor_r, cursor_g, cursor_b;
    const GTCell *cells;
    const char *title;
    const char *working_directory;
} GTFrame;

/** Load libghostty-vt. Returns NULL when available, otherwise an error string. */
const char *gt_runtime_error(void);

/** Create a shell, PTY, Ghostty terminal, and render state. */
GTSession *gt_session_create(uint16_t cols, uint16_t rows, const char **error);
void gt_session_destroy(GTSession *session);

/** Read pending PTY output into Ghostty. Returns true when the screen changed. */
bool gt_session_poll(GTSession *session);

/** Return a borrowed frame, valid until the next call for this session. */
const GTFrame *gt_session_frame(GTSession *session);

bool gt_session_write(GTSession *session, const uint8_t *bytes, size_t len);
bool gt_session_resize(GTSession *session, uint16_t cols, uint16_t rows,
                       uint32_t cell_width_px, uint32_t cell_height_px);
bool gt_session_is_running(GTSession *session);
int gt_session_exit_status(GTSession *session);

#ifdef __cplusplus
}
#endif
#endif
