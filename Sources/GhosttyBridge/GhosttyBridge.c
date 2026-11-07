#include "GhosttyBridge.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

typedef void *GhosttyTerminal;
typedef void *GhosttyRenderState;
typedef void *GhosttyRenderStateRowIterator;
typedef void *GhosttyRenderStateRowCells;
typedef void *GhosttyRenderStateImageIterator;
typedef void *GhosttyKittyGraphics;
typedef void *GhosttyKittyGraphicsImage;
typedef int GhosttyResult;
typedef uint64_t GhosttyCellRaw;
typedef uint64_t GhosttyRowRaw;

typedef struct { uint8_t r, g, b; } GhosttyColorRgb;
typedef struct { uint8_t tag; union { uint8_t palette; GhosttyColorRgb rgb; } value; } GhosttyStyleColor;
typedef struct {
    GhosttyStyleColor fg_color;
    GhosttyStyleColor bg_color;
    GhosttyStyleColor underline_color;
    uint16_t flags;
    uint16_t reserved;
} GhosttyStyle;
typedef struct { uint8_t *ptr; size_t cap, len; } GhosttyBuffer;
typedef struct { const uint8_t *ptr; size_t len; } GhosttyString;
typedef struct { uint64_t total, offset, len; } GhosttyTerminalScrollbar;
typedef union {
    intptr_t delta;
    size_t row;
    intptr_t delta_prompt;
    uint64_t padding[2];
} GhosttyTerminalScrollViewportValue;
typedef struct {
    int tag;
    GhosttyTerminalScrollViewportValue value;
} GhosttyTerminalScrollViewport;
typedef struct {
    size_t size;
    bool viewport_has_value;
    uint16_t viewport_x, viewport_y;
    bool wide_tail, visible, blinking, password_input;
    int visual_style;
} GhosttyRenderStateCursor;
typedef struct {
    size_t size;
    GhosttyColorRgb background, foreground, cursor;
    bool cursor_has_value;
    GhosttyColorRgb palette[256];
} GhosttyRenderStateColors;

enum {
    GHOSTTY_SUCCESS = 0,
    GHOSTTY_NO_VALUE = -4,
    GHOSTTY_RENDER_STATE_DATA_COLS = 1,
    GHOSTTY_RENDER_STATE_DATA_ROWS = 2,
    GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR = 4,
    GHOSTTY_RENDER_STATE_DATA_CURSOR = 18,
    GHOSTTY_RENDER_STATE_DATA_COLORS = 19,
    GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR = 22,
    GHOSTTY_RENDER_STATE_ROW_DATA_CELLS = 3,
    GHOSTTY_RENDER_STATE_ROW_DATA_RAW = 2,
    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW = 1,
    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE = 2,
    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR = 5,
    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR = 6,
    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8 = 9,
    GHOSTTY_TERMINAL_DATA_TITLE = 12,
    GHOSTTY_TERMINAL_DATA_SCROLLBAR = 9,
    GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS = 30,
    GHOSTTY_ROW_DATA_SEMANTIC_PROMPT = 6,
    GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM = 1,
    GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA = 2,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL = 1,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID = 2,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER = 4,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_Z = 5,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL = 6,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW = 7,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X = 10,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y = 11,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH = 12,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT = 13,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X = 14,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y = 15,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH = 16,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT = 17,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID = 18,
    GHOSTTY_IMAGE_PROTOCOL_KITTY = 0,
    GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH = 3,
    GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT = 4,
    GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT = 5,
    GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS = 7,
};

typedef struct {
    GhosttyResult (*terminal_new)(const void *, GhosttyTerminal *, uint16_t, uint16_t);
    void (*terminal_free)(GhosttyTerminal);
    GhosttyResult (*terminal_resize)(GhosttyTerminal, uint16_t, uint16_t, uint32_t, uint32_t);
    void (*terminal_write)(GhosttyTerminal, const uint8_t *, size_t);
    GhosttyResult (*terminal_get)(GhosttyTerminal, int, void *);
    GhosttyResult (*terminal_set)(GhosttyTerminal, int, const void *);
    GhosttyResult (*render_new)(const void *, GhosttyRenderState *);
    void (*render_free)(GhosttyRenderState);
    GhosttyResult (*render_update)(GhosttyRenderState, GhosttyTerminal);
    GhosttyResult (*render_get)(GhosttyRenderState, int, void *);
    GhosttyResult (*row_new)(const void *, GhosttyRenderStateRowIterator *);
    void (*row_free)(GhosttyRenderStateRowIterator);
    bool (*row_next)(GhosttyRenderStateRowIterator);
    GhosttyResult (*row_get)(GhosttyRenderStateRowIterator, int, void *);
    GhosttyResult (*cells_new)(const void *, GhosttyRenderStateRowCells *);
    void (*cells_free)(GhosttyRenderStateRowCells);
    bool (*cells_next)(GhosttyRenderStateRowCells);
    GhosttyResult (*cells_get)(GhosttyRenderStateRowCells, int, void *);
    GhosttyResult (*cell_get)(GhosttyCellRaw, int, void *);
    GhosttyResult (*screen_row_get)(GhosttyRowRaw, int, void *);
    GhosttyResult (*terminal_scroll_viewport)(GhosttyTerminal, GhosttyTerminalScrollViewport);
    GhosttyResult (*image_iter_new)(const void *, GhosttyRenderStateImageIterator *);
    void (*image_iter_free)(GhosttyRenderStateImageIterator);
    bool (*image_iter_next)(GhosttyRenderStateImageIterator);
    GhosttyResult (*image_get_multi)(GhosttyRenderStateImageIterator, size_t,
                                     const int *, void **, size_t *);
    GhosttyKittyGraphicsImage (*kitty_image)(GhosttyKittyGraphics, uint32_t);
    GhosttyResult (*kitty_image_get_multi)(GhosttyKittyGraphicsImage, size_t,
                                           const int *, void **, size_t *);
} GhosttyAPI;

static GhosttyAPI api;
static void *library_handle;
static const char *runtime_error;
static pthread_once_t runtime_once = PTHREAD_ONCE_INIT;

#define LOAD(field, symbol) do { \
    *(void **)(&api.field) = dlsym(library_handle, symbol); \
    if (!api.field) { runtime_error = "libghostty-vt is missing a required symbol"; return; } \
} while (0)

static void load_runtime(void) {
    const char *explicit_path = getenv("LIBGHOSTTY_VT_PATH");
    const char *paths[] = {
        explicit_path,
        ".build/lib/libghostty-vt.dylib",
        ".deps/ghostty/zig-out/lib/libghostty-vt.dylib",
        "/opt/homebrew/lib/libghostty-vt.dylib",
        "/usr/local/lib/libghostty-vt.dylib",
        "libghostty-vt.dylib",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (paths[i] && paths[i][0]) {
            library_handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
            if (library_handle) break;
        }
    }
    if (!library_handle) {
        runtime_error = "libghostty-vt was not found. Run Scripts/run.sh or set LIBGHOSTTY_VT_PATH.";
        return;
    }
    LOAD(terminal_new, "ghostty_terminal_new");
    LOAD(terminal_free, "ghostty_terminal_free");
    LOAD(terminal_resize, "ghostty_terminal_resize");
    LOAD(terminal_write, "ghostty_terminal_vt_write");
    LOAD(terminal_get, "ghostty_terminal_get");
    LOAD(terminal_set, "ghostty_terminal_set");
    LOAD(render_new, "ghostty_render_state_new");
    LOAD(render_free, "ghostty_render_state_free");
    LOAD(render_update, "ghostty_render_state_update");
    LOAD(render_get, "ghostty_render_state_get");
    LOAD(row_new, "ghostty_render_state_row_iterator_new");
    LOAD(row_free, "ghostty_render_state_row_iterator_free");
    LOAD(row_next, "ghostty_render_state_row_iterator_next");
    LOAD(row_get, "ghostty_render_state_row_get");
    LOAD(cells_new, "ghostty_render_state_row_cells_new");
    LOAD(cells_free, "ghostty_render_state_row_cells_free");
    LOAD(cells_next, "ghostty_render_state_row_cells_next");
    LOAD(cells_get, "ghostty_render_state_row_cells_get");
    LOAD(cell_get, "ghostty_cell_get");
    LOAD(screen_row_get, "ghostty_row_get");
    LOAD(terminal_scroll_viewport, "ghostty_terminal_scroll_viewport");
    LOAD(image_iter_new, "ghostty_render_state_image_iterator_new");
    LOAD(image_iter_free, "ghostty_render_state_image_iterator_free");
    LOAD(image_iter_next, "ghostty_render_state_image_iterator_next");
    LOAD(image_get_multi, "ghostty_render_state_image_get_multi");
    LOAD(kitty_image, "ghostty_kitty_graphics_image");
    LOAD(kitty_image_get_multi, "ghostty_kitty_graphics_image_get_multi");
}

const char *gt_runtime_error(void) {
    pthread_once(&runtime_once, load_runtime);
    return runtime_error;
}

struct GTSession {
    int master_fd;
    pid_t child;
    int exit_status;
    bool running;
    bool dirty;
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    GhosttyRenderStateImageIterator images;
    GTCell *cell_buffer;
    size_t cell_capacity;
    uint8_t *row_semantics;
    size_t row_capacity;
    GTImage *image_buffer;
    size_t image_capacity;
    uint8_t *command_output;
    size_t command_output_len;
    size_t command_output_capacity;
    bool capturing_command_output;
    char title[256];
    char working_directory[1024];
    GTFrame frame;
};

static void write_pty_reply(GhosttyTerminal terminal, void *userdata,
                            const uint8_t *data, size_t len) {
    (void)terminal;
    GTSession *s = userdata;
    if (!s || s->master_fd < 0 || !data) return;
    size_t sent = 0;
    while (sent < len) {
        ssize_t count = write(s->master_fd, data + sent, len - sent);
        if (count > 0) sent += (size_t)count;
        else if (errno != EINTR) break;
    }
}

static void set_error(const char **out, const char *message) {
    if (out) *out = message;
}

GTSession *gt_session_create(uint16_t cols, uint16_t rows, const char **error) {
    const char *load_error = gt_runtime_error();
    if (load_error) { set_error(error, load_error); return NULL; }
    GTSession *s = calloc(1, sizeof(*s));
    if (!s) { set_error(error, "Could not allocate a terminal session."); return NULL; }
    s->master_fd = -1;
    s->exit_status = -1;
    if (api.terminal_new(NULL, &s->terminal, cols, rows) != GHOSTTY_SUCCESS ||
        api.render_new(NULL, &s->render) != GHOSTTY_SUCCESS ||
        api.row_new(NULL, &s->rows) != GHOSTTY_SUCCESS ||
        api.cells_new(NULL, &s->cells) != GHOSTTY_SUCCESS ||
        api.image_iter_new(NULL, &s->images) != GHOSTTY_SUCCESS) {
        set_error(error, "Could not initialize libghostty-vt.");
        gt_session_destroy(s);
        return NULL;
    }
    GhosttyColorRgb foreground = {210, 225, 234};
    GhosttyColorRgb background = {6, 17, 24};
    api.terminal_set(s->terminal, 12, &foreground);
    api.terminal_set(s->terminal, 13, &background);
    api.terminal_set(s->terminal, 14, &foreground);
    size_t scrollback_bytes = 64 * 1024 * 1024;
    size_t scrollback_lines = 100000;
    api.terminal_set(s->terminal, 28, &scrollback_bytes);
    api.terminal_set(s->terminal, 29, &scrollback_lines);

    struct winsize ws = {.ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0};
    s->child = forkpty(&s->master_fd, NULL, NULL, &ws);
    if (s->child < 0) {
        set_error(error, "Could not create a pseudo-terminal.");
        gt_session_destroy(s);
        return NULL;
    }
    if (s->child == 0) {
        const char *shell = getenv("SHELL");
        if (!shell || !shell[0]) shell = "/bin/zsh";
        const char *name = strrchr(shell, '/');
        name = name ? name + 1 : shell;
        char login_name[256];
        snprintf(login_name, sizeof(login_name), "-%s", name);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        execl(shell, login_name, (char *)NULL);
        _exit(127);
    }
    fcntl(s->master_fd, F_SETFL, fcntl(s->master_fd, F_GETFL) | O_NONBLOCK);
    s->running = true;
    s->dirty = true;
    api.terminal_set(s->terminal, 1, s);
    api.terminal_set(s->terminal, 2, (const void *)write_pty_reply);
    api.terminal_resize(s->terminal, cols, rows, 9, 18);
    set_error(error, NULL);
    return s;
}

void gt_session_destroy(GTSession *s) {
    if (!s) return;
    if (s->master_fd >= 0) close(s->master_fd);
    if (s->running && s->child > 0) kill(s->child, SIGHUP);
    if (s->cells) api.cells_free(s->cells);
    if (s->images) api.image_iter_free(s->images);
    if (s->rows) api.row_free(s->rows);
    if (s->render) api.render_free(s->render);
    if (s->terminal) api.terminal_free(s->terminal);
    free(s->cell_buffer);
    free(s->row_semantics);
    free(s->image_buffer);
    free(s->command_output);
    free(s);
}

bool gt_session_poll(GTSession *s) {
    if (!s) return false;
    uint8_t buffer[32768];
    bool changed = false;
    for (;;) {
        ssize_t count = read(s->master_fd, buffer, sizeof(buffer));
        if (count > 0) {
            if (s->capturing_command_output) {
                size_t needed = s->command_output_len + (size_t)count;
                if (needed > s->command_output_capacity) {
                    size_t capacity = s->command_output_capacity ? s->command_output_capacity : 32768;
                    while (capacity < needed) capacity *= 2;
                    uint8_t *next = realloc(s->command_output, capacity);
                    if (next) {
                        s->command_output = next;
                        s->command_output_capacity = capacity;
                    }
                }
                if (needed <= s->command_output_capacity) {
                    memcpy(s->command_output + s->command_output_len, buffer, (size_t)count);
                    s->command_output_len = needed;
                }
            }
            api.terminal_write(s->terminal, buffer, (size_t)count);
            changed = true;
            continue;
        }
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            s->running = false;
        }
        break;
    }
    if (s->child > 0) {
        int status = 0;
        pid_t result = waitpid(s->child, &status, WNOHANG);
        if (result == s->child) {
            s->running = false;
            s->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            s->child = 0;
            changed = true;
        }
    }
    s->dirty |= changed;
    return changed;
}

static GhosttyColorRgb fallback_fg(void) { return (GhosttyColorRgb){210, 225, 234}; }
static GhosttyColorRgb fallback_bg(void) { return (GhosttyColorRgb){6, 17, 24}; }

static size_t collect_images(GTSession *s) {
    if (api.render_get(s->render, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR,
                       &s->images) != GHOSTTY_SUCCESS) return 0;
    GhosttyKittyGraphics graphics = NULL;
    if (api.terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                         &graphics) != GHOSTTY_SUCCESS || !graphics) return 0;

    size_t count = 0;
    while (api.image_iter_next(s->images)) {
        int protocol = -1;
        GTImage image = {0};
        int placement_keys[] = {
            GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_Z,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH,
            GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT,
        };
        void *placement_values[] = {
            &protocol, &image.image_id, &image.placement_id, &image.layer,
            &image.z, &image.viewport_col, &image.viewport_row,
            &image.cell_offset_x, &image.cell_offset_y,
            &image.pixel_width, &image.pixel_height,
            &image.source_x, &image.source_y,
            &image.source_width, &image.source_height,
        };
        size_t placement_count = sizeof(placement_keys) / sizeof(placement_keys[0]);
        if (api.image_get_multi(s->images, placement_count, placement_keys,
                                placement_values, NULL) != GHOSTTY_SUCCESS ||
            protocol != GHOSTTY_IMAGE_PROTOCOL_KITTY) continue;

        GhosttyKittyGraphicsImage handle = api.kitty_image(graphics, image.image_id);
        if (!handle) continue;
        GhosttyString pixels = {0};
        int image_keys[] = {
            GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH,
            GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT,
            GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT,
            GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS,
        };
        void *image_values[] = {
            &image.image_width, &image.image_height, &image.pixel_format, &pixels,
        };
        if (api.kitty_image_get_multi(handle, 4, image_keys, image_values, NULL) !=
                GHOSTTY_SUCCESS || !pixels.ptr || !pixels.len) continue;
        image.pixels = pixels.ptr;
        image.pixels_len = pixels.len;

        if (count == s->image_capacity) {
            size_t capacity = s->image_capacity ? s->image_capacity * 2 : 16;
            GTImage *next = realloc(s->image_buffer, capacity * sizeof(GTImage));
            if (!next) break;
            s->image_buffer = next;
            s->image_capacity = capacity;
        }
        s->image_buffer[count++] = image;
    }
    return count;
}

const GTFrame *gt_session_frame(GTSession *s) {
    if (!s) return NULL;
    if (!s->dirty && s->frame.cells) return &s->frame;
    if (api.render_update(s->render, s->terminal) != GHOSTTY_SUCCESS) return NULL;

    uint16_t cols = 0, rows = 0;
    GhosttyRenderStateColors colors = {0}; colors.size = sizeof(colors);
    GhosttyRenderStateCursor cursor = {0}; cursor.size = sizeof(cursor);
    if (api.render_get(s->render, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) != GHOSTTY_SUCCESS ||
        api.render_get(s->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS) return NULL;
    if (api.render_get(s->render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors) != GHOSTTY_SUCCESS) {
        colors.foreground = fallback_fg(); colors.background = fallback_bg();
    }
    api.render_get(s->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);

    size_t needed = (size_t)cols * rows;
    if (needed > s->cell_capacity) {
        GTCell *next = realloc(s->cell_buffer, needed * sizeof(GTCell));
        if (!next) return NULL;
        s->cell_buffer = next;
        s->cell_capacity = needed;
    }
    memset(s->cell_buffer, 0, needed * sizeof(GTCell));
    if (rows > s->row_capacity) {
        uint8_t *next = realloc(s->row_semantics, rows);
        if (!next) return NULL;
        s->row_semantics = next;
        s->row_capacity = rows;
    }
    memset(s->row_semantics, 0, rows);
    if (api.render_get(s->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s->rows) != GHOSTTY_SUCCESS) return NULL;
    uint16_t y = 0;
    while (y < rows && api.row_next(s->rows)) {
        GhosttyRowRaw raw_row = 0;
        if (api.row_get(s->rows, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw_row) == GHOSTTY_SUCCESS) {
            int semantic = 0;
            if (api.screen_row_get(raw_row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic) == GHOSTTY_SUCCESS) {
                s->row_semantics[y] = (uint8_t)semantic;
            }
        }
        if (api.row_get(s->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s->cells) != GHOSTTY_SUCCESS) { y++; continue; }
        uint16_t x = 0;
        while (x < cols && api.cells_next(s->cells)) {
            GTCell *out = &s->cell_buffer[(size_t)y * cols + x];
            GhosttyBuffer text = {.ptr = out->text, .cap = sizeof(out->text), .len = 0};
            GhosttyStyle style = {0};
            GhosttyColorRgb fg = colors.foreground, bg = colors.background;
            GhosttyCellRaw raw = 0;
            api.cells_get(s->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
            api.cells_get(s->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
            if (api.cells_get(s->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS) {
                int semantic = 0;
                if (api.cell_get(raw, 9, &semantic) == GHOSTTY_SUCCESS) {
                    out->semantic_content = (uint8_t)semantic;
                }
            }
            if (api.cells_get(s->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_NO_VALUE) fg = colors.foreground;
            if (api.cells_get(s->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_NO_VALUE) bg = colors.background;
            if (style.flags & GT_STYLE_INVERSE) {
                GhosttyColorRgb swap = fg; fg = bg; bg = swap;
            }
            out->text_len = (uint8_t)(text.len > sizeof(out->text) ? sizeof(out->text) : text.len);
            out->fg_r = fg.r; out->fg_g = fg.g; out->fg_b = fg.b;
            out->bg_r = bg.r; out->bg_g = bg.g; out->bg_b = bg.b;
            out->style = style.flags;
            x++;
        }
        y++;
    }

    GhosttyString title = {0};
    if (api.terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS && title.ptr) {
        size_t count = title.len < sizeof(s->title) - 1 ? title.len : sizeof(s->title) - 1;
        memcpy(s->title, title.ptr, count); s->title[count] = 0;
    } else {
        strcpy(s->title, "Shell");
    }
    struct proc_vnodepathinfo path_info = {0};
    int path_info_size = proc_pidinfo(s->child, PROC_PIDVNODEPATHINFO, 0,
                                     &path_info, sizeof(path_info));
    if (path_info_size == sizeof(path_info) && path_info.pvi_cdir.vip_path[0]) {
        snprintf(s->working_directory, sizeof(s->working_directory), "%s",
                 path_info.pvi_cdir.vip_path);
    } else {
        GhosttyString working_directory = {0};
        if (api.terminal_get(s->terminal, 13, &working_directory) == GHOSTTY_SUCCESS && working_directory.ptr) {
            size_t count = working_directory.len < sizeof(s->working_directory) - 1
                ? working_directory.len : sizeof(s->working_directory) - 1;
            memcpy(s->working_directory, working_directory.ptr, count);
            s->working_directory[count] = 0;
        } else {
            s->working_directory[0] = 0;
        }
    }
    GhosttyColorRgb cursor_color = colors.cursor_has_value ? colors.cursor : colors.foreground;
    GhosttyTerminalScrollbar scrollbar = {0};
    api.terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar);
    size_t image_count = collect_images(s);
    s->frame = (GTFrame){
        .cols = cols, .rows = rows,
        .cursor_x = cursor.viewport_has_value ? cursor.viewport_x : 0,
        .cursor_y = cursor.viewport_has_value ? cursor.viewport_y : 0,
        .cursor_visible = cursor.viewport_has_value && cursor.visible,
        .cursor_r = cursor_color.r, .cursor_g = cursor_color.g, .cursor_b = cursor_color.b,
        .cells = s->cell_buffer, .row_semantics = s->row_semantics,
        .images = s->image_buffer, .image_count = image_count, .title = s->title,
        .working_directory = s->working_directory,
        .scroll_total = scrollbar.total,
        .scroll_offset = scrollbar.offset,
        .scroll_length = scrollbar.len,
    };
    s->dirty = false;
    return &s->frame;
}

bool gt_session_write(GTSession *s, const uint8_t *bytes, size_t len) {
    if (!s || s->master_fd < 0 || !bytes) return false;
    size_t sent = 0;
    while (sent < len) {
        ssize_t count = write(s->master_fd, bytes + sent, len - sent);
        if (count > 0) sent += (size_t)count;
        else if (errno != EINTR) return false;
    }
    return true;
}

bool gt_session_feed_output(GTSession *s, const uint8_t *bytes, size_t len) {
    if (!s || !s->terminal || !bytes) return false;
    api.terminal_write(s->terminal, bytes, len);
    s->dirty = true;
    return true;
}

static void write_semantic_marker(GTSession *s, const char *marker) {
    if (!s || !s->terminal || !marker) return;
    api.terminal_write(s->terminal, (const uint8_t *)marker, strlen(marker));
    s->dirty = true;
}

void gt_session_mark_input(GTSession *s) {
    if (s) s->capturing_command_output = false;
    /* P marks the prompt at the current cursor. A would request a fresh line,
       which is only appropriate when emitted by the shell before its prompt. */
    write_semantic_marker(s, "\033]133;D\007\033]133;P\007\033]133;B\007");
}

void gt_session_mark_output(GTSession *s) {
    /* The marker is injected directly into the parser while typed characters
       are echoed asynchronously by the PTY. Drain that echo before changing
       semantic state so the command remains tagged as input. */
    if (s && s->master_fd >= 0) {
        struct pollfd descriptor = {.fd = s->master_fd, .events = POLLIN};
        if (poll(&descriptor, 1, 12) > 0 && (descriptor.revents & POLLIN)) {
            gt_session_poll(s);
        }
    }
    if (s) {
        s->command_output_len = 0;
        s->capturing_command_output = true;
    }
    write_semantic_marker(s, "\033]133;C\007");
}

size_t gt_session_command_output(GTSession *s, uint8_t *buffer, size_t capacity) {
    if (!s) return 0;
    if (buffer && capacity) {
        size_t count = s->command_output_len < capacity ? s->command_output_len : capacity;
        memcpy(buffer, s->command_output, count);
    }
    return s->command_output_len;
}

bool gt_session_scroll(GTSession *s, intptr_t rows) {
    if (!s || !rows) return false;
    GhosttyTerminalScrollViewport behavior = {
        .tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA,
        .value = {.delta = rows},
    };
    bool ok = api.terminal_scroll_viewport(s->terminal, behavior) == GHOSTTY_SUCCESS;
    s->dirty |= ok;
    return ok;
}

bool gt_session_scroll_to_bottom(GTSession *s) {
    if (!s) return false;
    GhosttyTerminalScrollViewport behavior = {
        .tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM,
        .value = {.delta = 0},
    };
    bool ok = api.terminal_scroll_viewport(s->terminal, behavior) == GHOSTTY_SUCCESS;
    s->dirty |= ok;
    return ok;
}

bool gt_session_resize(GTSession *s, uint16_t cols, uint16_t rows, uint32_t cw, uint32_t ch) {
    if (!s || !cols || !rows) return false;
    struct winsize ws = {.ws_row = rows, .ws_col = cols,
                         .ws_xpixel = (uint16_t)(cols * cw), .ws_ypixel = (uint16_t)(rows * ch)};
    ioctl(s->master_fd, TIOCSWINSZ, &ws);
    bool ok = api.terminal_resize(s->terminal, cols, rows, cw, ch) == GHOSTTY_SUCCESS;
    s->dirty = true;
    return ok;
}

bool gt_session_is_running(GTSession *s) { return s && s->running; }
int gt_session_exit_status(GTSession *s) { return s ? s->exit_status : -1; }
