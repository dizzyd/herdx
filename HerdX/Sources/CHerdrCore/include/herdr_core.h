// C ABI for herdr-core. Keep in sync with herdr-core/src/ffi.rs.
#ifndef HERDR_CORE_H
#define HERDR_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct HxSession HxSession;

/// One terminal cell. Glyphs live in HxGrid.glyphs at [glyph_off, +glyph_len).
typedef struct {
  uint32_t fg;        // 0x00=named, 0x01=indexed, 0x02=RGB (herdr packing)
  uint32_t bg;
  uint16_t modifier;  // ratatui modifier bits + herdr underline-style in 12..15
  uint16_t glyph_len;
  uint32_t glyph_off;
  uint32_t hyperlink; // index into HxGrid.hyperlinks; UINT32_MAX means none
} HxCell;

typedef struct {
  const uint8_t *bytes;
  size_t len;
} HxHyperlink;

/// One pane's placement inside the shared surface, in cell units.
typedef struct {
  uint16_t x, y, width, height;
  uint16_t inner_x, inner_y, inner_width, inner_height;
  bool focused;
  bool alternate_screen;
  bool mouse_reporting;
  uint64_t scroll_offset_from_bottom;
  uint64_t scroll_max_offset_from_bottom;
  uint64_t content_revision;
  uint32_t id_index;  // resolve with hx_pane_id
} HxPane;

/// One image placement, in surface cell coordinates.
typedef struct {
  uint64_t asset_id;
  uint16_t x, y;
  uint32_t cols, rows;
  uint32_t source_x, source_y, source_width, source_height;
  uint32_t x_offset, y_offset;
  int32_t z;
} HxPlacement;

#define HX_IMAGE_RGB 0
#define HX_IMAGE_RGBA 1
#define HX_IMAGE_PNG 2

typedef struct {
  uint32_t width;
  uint32_t height;
  uint8_t format;
  const uint8_t *data;
  size_t len;
} HxAsset;

/// A flattened pane surface: width * height cells, row-major.
typedef struct {
  uint16_t width;
  uint16_t height;
  const HxCell *cells;
  size_t cell_count;
  const uint8_t *glyphs;
  size_t glyph_bytes;
  const HxHyperlink *hyperlinks;
  size_t hyperlink_count;
  uint16_t cursor_x;
  uint16_t cursor_y;
  bool cursor_visible;
  uint8_t cursor_shape;  // DECSCUSR parameter
  uint64_t revision;
  const HxPane *panes;
  size_t pane_count;
  const HxPlacement *placements;
  size_t placement_count;
} HxGrid;

// Key kinds; anything printable uses HX_KEY_CHAR with a codepoint.
#define HX_KEY_CHAR 0
#define HX_KEY_BACKSPACE 1
#define HX_KEY_ENTER 2
#define HX_KEY_LEFT 3
#define HX_KEY_RIGHT 4
#define HX_KEY_UP 5
#define HX_KEY_DOWN 6
#define HX_KEY_HOME 7
#define HX_KEY_END 8
#define HX_KEY_PAGEUP 9
#define HX_KEY_PAGEDOWN 10
#define HX_KEY_TAB 11
#define HX_KEY_BACKTAB 12
#define HX_KEY_DELETE 13
#define HX_KEY_INSERT 14
#define HX_KEY_ESC 15
#define HX_KEY_F1 16

// Modifier bits (crossterm order).
#define HX_MOD_SHIFT 1
#define HX_MOD_CONTROL 2
#define HX_MOD_ALT 4
#define HX_MOD_SUPER 8

/// `socket_path` picks the herdr session; NULL means the default one.
/// `attach_machines` false attaches the local server alone.
HxSession *hx_session_connect(uint16_t cols, uint16_t rows, uint32_t cell_width_px,
                              uint32_t cell_height_px, const char *socket_path,
                              bool attach_machines);

/// The client socket a NULL `socket_path` would use. Caller frees.
char *hx_default_socket_path(void);
void hx_session_free(HxSession *session);
bool hx_session_connected(const HxSession *session);

/// Refreshes the caller's view. Pointers stay valid until the next call.
bool hx_grid_acquire(HxSession *session, HxGrid *out);

/// Copies image bytes for a placement. Valid until the next call.
bool hx_asset(HxSession *session, uint64_t asset_id, HxAsset *out);

char *hx_pane_id(const HxSession *session, uint32_t id_index);

// Endpoints: the local server plus each saved SSH machine.
#define HX_ENDPOINT_CONNECTING 0
#define HX_ENDPOINT_ONLINE 1
#define HX_ENDPOINT_OFFLINE 2

size_t hx_endpoint_count(const HxSession *session);
char *hx_endpoint_id(const HxSession *session, size_t index);
char *hx_endpoint_label(const HxSession *session, size_t index);

/// The SSH machines herdr knows about, as a JSON array. Free with
/// hx_string_free.
char *hx_machines_json(void);

/// Why an endpoint is not connected, if it has said. Free with hx_string_free.
char *hx_endpoint_error(const HxSession *session, size_t index);

/// Whether a machine is reachable but has no herdr installed.
bool hx_endpoint_needs_install(const HxSession *session, size_t index);

/// Tells every server whether this window is the one being looked at.
bool hx_set_focus(const HxSession *session, bool focused);

/// Adds a machine, or replaces the one with `id`. Returns the id, or NULL with
/// the reason available from hx_machine_error.
char *hx_machine_save(const char *id, const char *label, const char *target,
                      const char *session, bool enabled);

/// Removes a machine by id.
bool hx_machine_remove(const char *id);

/// Why the last machine edit failed. Free with hx_string_free.
char *hx_machine_error(void);
uint8_t hx_endpoint_status(const HxSession *session, size_t index);
bool hx_endpoint_is_remote(const HxSession *session, size_t index);
size_t hx_active_endpoint(const HxSession *session);
bool hx_set_active_endpoint(HxSession *session, size_t index);
char *hx_endpoint_snapshot_json(const HxSession *session, size_t index);
char *hx_next_endpoint_event(const HxSession *session, size_t index);
char *hx_connect_error(void);
void hx_string_free(char *s);

// Mouse kinds.
#define HX_MOUSE_DOWN 0
#define HX_MOUSE_UP 1
#define HX_MOUSE_DRAG 2
#define HX_MOUSE_MOVED 3
#define HX_MOUSE_SCROLL_UP 4
#define HX_MOUSE_SCROLL_DOWN 5
#define HX_MOUSE_SCROLL_LEFT 6
#define HX_MOUSE_SCROLL_RIGHT 7

#define HX_BUTTON_LEFT 0
#define HX_BUTTON_RIGHT 1
#define HX_BUTTON_MIDDLE 2

/// One mouse event in surface coordinates.
typedef struct {
  uint16_t kind;
  uint8_t button;
  uint16_t column;
  uint16_t row;
  uint32_t pixel_x;
  uint32_t pixel_y;
  uint8_t modifiers;
  uint16_t lines;
} HxMouseEvent;

bool hx_send_mouse(const HxSession *session, const char *pane_id,
                   const HxMouseEvent *event);

bool hx_send_key(const HxSession *session, const char *pane_id, uint16_t kind,
                 uint32_t codepoint, uint8_t modifiers);
bool hx_send_text(const HxSession *session, const char *pane_id, const char *text);
bool hx_send_paste(const HxSession *session, const char *pane_id, const char *text);
bool hx_set_default_color(const HxSession *session, bool foreground, uint8_t r,
                          uint8_t g, uint8_t b);
bool hx_set_appearance(const HxSession *session, bool dark);
bool hx_set_palette(const HxSession *session, const uint8_t *colors, size_t count);
bool hx_resize(const HxSession *session, uint16_t cols, uint16_t rows,
               uint32_t cell_width_px, uint32_t cell_height_px);
bool hx_endpoint_request(const HxSession *session, const char *boot_id, const char *request);

#endif
