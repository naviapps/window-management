#ifndef WINDOW_MANAGEMENT_H
#define WINDOW_MANAGEMENT_H
#include <stdint.h>
#include <stddef.h>
#define WINDOW_MANAGEMENT_ABI_VERSION 6U
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    double x, y, width, height;
} WindowManagementRect;
typedef struct {
    WindowManagementRect frame, visible_frame;
    uint64_t identifier;
    uint32_t has_identifier, is_main;
} WindowManagementDisplay;
typedef struct {
    uint32_t code;
    WindowManagementRect frame;
} WindowManagementRectResult;
uint32_t window_management_abi_version(void);
typedef struct {
    uint32_t kind;
    int64_t columns, rows, column, row, column_span, row_span;
    double width_ratio, height_ratio;
} WindowManagementPlacement;
typedef struct {
    uint32_t code;
    WindowManagementPlacement value;
} WindowManagementPlacementResult;
typedef struct {
    uint32_t kind;
    double x, y;
    uint64_t identifier;
    int64_t index;
} WindowManagementDisplayTarget;
typedef struct {
    uint32_t code;
    WindowManagementDisplayTarget value;
} WindowManagementDisplayTargetResult;
/* Typed normalization uses the same kind codes as geometry/selection. Result code is 0 or 1 invalid
 * kind. */
WindowManagementPlacementResult
window_management_placement_normalize(WindowManagementPlacement value);
WindowManagementDisplayTargetResult
window_management_display_target_normalize(WindowManagementDisplayTarget value);
double window_management_inset_normalize(double value);
typedef struct {
    WindowManagementPlacement placement;
    WindowManagementDisplayTarget display;
    uint32_t area;
    double inset;
} WindowManagementPlacementRequest;
typedef struct {
    uint32_t direction, preserves_relative_position;
} WindowManagementMoveRequest;
/* Request area:0 visible,1 full; direction:0 next,1 previous.
   Code:0 resolved,1 invalid request/buffer,2 display not found. Displays are borrowed during the
   call. */
WindowManagementRectResult window_management_placement_resolve(
    WindowManagementPlacementRequest request, WindowManagementRect window,
    const WindowManagementDisplay *displays, size_t count, uint32_t fallback);
WindowManagementRectResult
window_management_movement_resolve(WindowManagementMoveRequest request, WindowManagementRect window,
                                   const WindowManagementDisplay *displays, size_t count,
                                   uint32_t fallback);
typedef struct {
    uint32_t code, requires_frame_write;
    WindowManagementRect frame;
} WindowManagementMovementPlanResult;
/* Same resolution and borrowed-buffer contract as movement_resolve. On success,
   requires_frame_write compares against the normalized input window. */
WindowManagementMovementPlanResult
window_management_movement_plan(WindowManagementMoveRequest request, WindowManagementRect window,
                                const WindowManagementDisplay *displays, size_t count,
                                uint32_t fallback);
typedef struct WindowManagementJson WindowManagementJson;
typedef struct {
    uint32_t code;
    const uint8_t *data;
    size_t length;
} WindowManagementJsonView;
/* kind:0 placement,1 display target,2 placement request,3 move request.
   Result code 0 is canonical JSON; code 1 is UTF-8 diagnostic text.
   Input is borrowed during the call; result views borrow their owner until destruction. */
WindowManagementJson *window_management_value_json(uint32_t kind, const uint8_t *data,
                                                   size_t length);
/* Serialize a native value with the same normalized schema and owned result contract. */
WindowManagementJson *window_management_placement_json(WindowManagementPlacement value);
WindowManagementJson *window_management_display_target_json(WindowManagementDisplayTarget value);
WindowManagementJson *
window_management_placement_request_json(WindowManagementPlacementRequest value);
WindowManagementJson *window_management_move_request_json(WindowManagementMoveRequest value);
WindowManagementJsonView window_management_json_view(const WindowManagementJson *owner);
void window_management_json_destroy(WindowManagementJson *owner);
/* Compile original JSON in one pass. The nonnull json output slot must be
 * writable and must not overlap the input. It receives an independently owned
 * canonical JSON result (code 0) or diagnostic (code 1). The compiled filter is
 * null on rejection. Destroy both owners independently using their own functions.
 * Concurrent filter queries are allowed; destruction needs exclusive ownership. */
typedef struct WindowManagementWindowFilter WindowManagementWindowFilter;
WindowManagementWindowFilter *window_management_window_filter_compile(const uint8_t *data,
                                                                      size_t length,
                                                                      WindowManagementJson **json);
/* Evaluate numeric IDs first: 0 excluded, 1 included, 2 invalid handle, 3 application conditions
   still need evaluation through window_management_window_filter_includes. */
uint32_t window_management_window_filter_match_identity(const WindowManagementWindowFilter *filter,
                                                        uint64_t window, int64_t process);
/* Missing application ID is null/zero, present empty ID is nonnull/zero.
   Returns 0 excluded, 1 included, 2 invalid view/handle. */
uint32_t window_management_window_filter_includes(const WindowManagementWindowFilter *filter,
                                                  uint64_t window, int64_t process,
                                                  const uint8_t *application, size_t length);
void window_management_window_filter_destroy(WindowManagementWindowFilter *filter);
WindowManagementRect window_management_rect_normalize(WindowManagementRect rect);
/* Normalizes bounds; rejects non-finite points. Minimum edges included, maximum excluded. */
uint32_t window_management_rect_contains(WindowManagementRect rect, double x, double y);
/* Placement kind:0 fill,1 grid,2 centered. Result code:0 success,1 invalid kind.
   Grid counts/indices/spans and ratios are clamped. Row zero starts at minimum y. */
WindowManagementRectResult window_management_placement(WindowManagementPlacement placement,
                                                       WindowManagementRect area, double inset);
WindowManagementRect window_management_move(WindowManagementRect window,
                                            WindowManagementRect source,
                                            WindowManagementRect target,
                                            uint32_t preserves_position);
/* Returns number of indices written; zero for empty input or invalid buffers/capacity.
   Buffers must cover their declared counts and be aligned; output capacity must cover count. */
size_t window_management_display_order(const WindowManagementDisplay *displays, size_t count,
                                       size_t *output, size_t capacity);
/* kind: 0 main, 1 greatest positive window overlap, 2 point in the supplied display coordinate
   space, 3 identifier, 4 ordered index. Returns an original-array index or -1. Kind 1 uses
   normalized full frames; equal areas prefer center containment, then stable order. Zero-width or
   zero-height windows use center containment alone. Nonzero fallback permits the first ordered
   display when a valid kind has no match. Displays must be aligned and readable for count; null is
   permitted for zero count. */
int64_t window_management_display_select(const WindowManagementDisplay *displays, size_t count,
                                         uint32_t kind, WindowManagementRect window, double x,
                                         double y, uint64_t identifier, int64_t index,
                                         uint32_t fallback);
/* Returns a position in stable display order or -1 when the point has no match or the input is
   invalid. Uses the same borrowed buffer and half-open point rules as display selection. */
int64_t window_management_display_index_containing_point(const WindowManagementDisplay *displays,
                                                         size_t count, double x, double y);
int64_t window_management_display_adjacent(int64_t index, uint32_t previous, int64_t count);
typedef struct {
    uint64_t handle;
    uint32_t process, thread;
} WindowManagementWindowIdentity;
typedef struct {
    uint32_t code, native_error;
    WindowManagementWindowIdentity identity;
} WindowManagementWindowIdentityResult;
/* Capture the foreground HWND/process/thread without reading window metadata.
   Status: 0 success, 1 unsupported OS, 3 unavailable owner, 4 foreground changed.
   The identity is zeroed on failure. The returned value needs no destruction. */
WindowManagementWindowIdentityResult window_management_windows_foreground_identity(void);
typedef struct {
    WindowManagementWindowIdentity identity;
    WindowManagementRect frame;
    const uint8_t *title;
    size_t title_length;
    uint32_t minimized, maximized;
} WindowManagementWindowView;
typedef struct WindowManagementQuery WindowManagementQuery;
typedef struct {
    uint32_t code, native_error;
    size_t count;
    const WindowManagementDisplay *displays;
    size_t display_count;
} WindowManagementQueryView;
/* Own results and destroy exactly once. Views borrow the result; copy before destruction.
   Status: 0 success, 1 unsupported OS, 2 invalid input, 3 unavailable,
   4 target identity changed, 5 native failure (native_error carries GetLastError).
   Query kinds: 0 visible windows, 1 foreground, 2 known identity, 3 root window at a
   physical point, 4 visible non-minimized bounds containing a physical point in native z order.
   Physical-point queries sample the pixel containing the fractional coordinates.
   An invalid point yields zero results for kind 4.
   Commands: 0 set frame, 1 restore, 2 minimize, 3 maximize, 4 post close request. */
WindowManagementQuery *window_management_windows_query(uint32_t kind,
                                                       WindowManagementWindowIdentity identity,
                                                       double x, double y);
WindowManagementQuery *window_management_windows_displays(void);
WindowManagementQuery *window_management_windows_command(WindowManagementWindowIdentity identity,
                                                         uint32_t operation,
                                                         WindowManagementRect frame);
/* kind:0 placement request,1 move request. Input uses the shared request JSON shapes.
   Nonzero fallback permits first-display fallback. Native identity is rechecked before setting a
   frame. */
WindowManagementQuery *window_management_windows_request(WindowManagementWindowIdentity identity,
                                                         uint32_t kind, const uint8_t *data,
                                                         size_t length, uint32_t fallback);
WindowManagementQueryView window_management_windows_query_view(const WindowManagementQuery *query);
WindowManagementWindowView
window_management_windows_query_window(const WindowManagementQuery *query, size_t index);
void window_management_windows_query_destroy(WindowManagementQuery *query);
#ifdef __cplusplus
}
#endif
#endif
