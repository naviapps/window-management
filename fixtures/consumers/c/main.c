#include <CWindowManagement/window_management.h>
#include <assert.h>
#include <float.h>
#include <stdio.h>
#include <string.h>

static void expect_frame(WindowManagementRectResult result, WindowManagementRect expected) {
    assert(result.code == 0);
    assert(result.frame.x == expected.x && result.frame.y == expected.y);
    assert(result.frame.width == expected.width && result.frame.height == expected.height);
}

int main(void) {
    assert(window_management_abi_version() == WINDOW_MANAGEMENT_ABI_VERSION);
    WindowManagementWindowIdentityResult foreground =
        window_management_windows_foreground_identity();
    assert(foreground.code == 1 && foreground.identity.handle == 0);
    const uint8_t selection[] = "{\"includedWindowIdentifiers\":[42,18446744073709551615],"
                                "\"includedOwnerProcessIdentifiers\":[12,-9223372036854775808],"
                                "\"excludedOwnerApplicationIdentifiers\":[\"\"]}";
    WindowManagementJson *selection_json = NULL;
    WindowManagementWindowFilter *filter =
        window_management_window_filter_compile(selection, sizeof selection - 1, &selection_json);
    assert(filter);
    const uint8_t canonical[] =
        "{\"includedOwnerApplicationIdentifiers\":[],"
        "\"includedOwnerProcessIdentifiers\":[-9223372036854775808,12],"
        "\"includedWindowIdentifiers\":[42,18446744073709551615],"
        "\"excludedOwnerApplicationIdentifiers\":[\"\"],\"excludedOwnerProcessIdentifiers\":[],"
        "\"excludedWindowIdentifiers\":[]}";
    WindowManagementJsonView selection_view = window_management_json_view(selection_json);
    assert(selection_view.code == 0 && selection_view.data);
    assert(selection_view.length == sizeof canonical - 1);
    assert(memcmp(selection_view.data, canonical, selection_view.length) == 0);
    window_management_json_destroy(selection_json);
    assert(window_management_window_filter_match_identity(filter, 7, 12) == 0);
    assert(window_management_window_filter_match_identity(filter, 42, 12) == 3);
    assert(window_management_window_filter_match_identity(filter, UINT64_MAX, INT64_MIN) == 3);
    assert(window_management_window_filter_includes(filter, 42, 12, NULL, 0) == 1);
    window_management_window_filter_destroy(filter);
    const double smallest = DBL_TRUE_MIN;
    expect_frame(
        window_management_placement((WindowManagementPlacement){0},
                                    (WindowManagementRect){0, 0, 3 * smallest, 7 * smallest}, 1),
        (WindowManagementRect){2 * smallest, 2 * smallest, 0, 4 * smallest});
    const WindowManagementDisplay displays[] = {
        {.frame = {1000, 0, 600, 500},
         .visible_frame = {1000, 20, 600, 480},
         .identifier = 2,
         .has_identifier = 1},
        {.frame = {0, 0, 800, 600},
         .visible_frame = {0, 40, 800, 560},
         .identifier = 1,
         .has_identifier = 1,
         .is_main = 1},
    };
    size_t count = sizeof displays / sizeof displays[0];
    const WindowManagementRect window = {600, 80, 640, 200};
    /* All geometry is caller-owned. The center is in the gap between these displays. */
    assert(window_management_display_select(displays, count, 1, window, 0, 0, 0, 0, 0) == 0);
    assert(window_management_display_index_containing_point(displays, count, 1000, 80) == 1);
    const WindowManagementDisplay coincident[] = {
        {.frame = {0, 0, 100, 100}, .identifier = 1, .has_identifier = 1},
        {.frame = {-0.0, -0.0, 100, 100}, .identifier = 9, .has_identifier = 1},
    };
    assert(window_management_display_select(coincident, 2, 2, window, 10, 10, 0, 0, 0) == 0);
    WindowManagementPlacementRequest request = {
        .placement =
            {.kind = 1, .columns = 2, .rows = 1, .column = 1, .column_span = 1, .row_span = 1},
        .display = {.kind = 1},
        .area = 0,
        .inset = 10,
    };
    expect_frame(window_management_placement_resolve(request, window, displays, count, 0),
                 (WindowManagementRect){1300, 30, 290, 460});

    request.display = (WindowManagementDisplayTarget){.kind = 3, .identifier = 99};
    assert(window_management_placement_resolve(request, window, displays, count, 0).code == 2);
    expect_frame(window_management_placement_resolve(request, window, displays, count, 1),
                 (WindowManagementRect){400, 50, 390, 540});
    puts(
        "Standalone installed C WindowManagement consumer passed placement and display selection.");
    return 0;
}
