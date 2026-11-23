#ifdef NDEBUG
#undef NDEBUG
#endif
#include "window_management.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    const char *filter_json = "{\"includedOwnerApplicationIdentifiers\":[\"\"],"
                              "\"includedWindowIdentifiers\":[18446744073709551615]}";
    WindowManagementJson *filter_json_owner = NULL;
    WindowManagementWindowFilter *filter = window_management_window_filter_compile(
        (const uint8_t *)filter_json, strlen(filter_json), &filter_json_owner);
    assert(filter);
    WindowManagementJsonView filter_view = window_management_json_view(filter_json_owner);
    assert(filter_view.code == 0 && filter_view.data && filter_view.length);
    window_management_json_destroy(filter_json_owner);
    assert(window_management_window_filter_match_identity(filter, UINT64_MAX, 12) == 3);
    assert(window_management_window_filter_match_identity(filter, 1, 12) == 0);
    assert(window_management_window_filter_match_identity(NULL, 1, 12) == 2);
    assert(window_management_window_filter_includes(filter, UINT64_MAX, 12, (const uint8_t *)"",
                                                    0) == 1);
    assert(window_management_window_filter_includes(filter, UINT64_MAX, 12, NULL, 0) == 0);
    const uint8_t invalid_utf8[] = {0xff};
    assert(window_management_window_filter_includes(filter, UINT64_MAX, 12, invalid_utf8, 1) == 2);
    assert(window_management_window_filter_includes(filter, UINT64_MAX, 12, NULL, 1) == 2);
    window_management_window_filter_destroy(filter);
    filter = window_management_window_filter_compile((const uint8_t *)"{}", 2, &filter_json_owner);
    assert(window_management_window_filter_match_identity(filter, 1, 12) == 1);
    window_management_window_filter_destroy(filter);
    assert(window_management_json_view(filter_json_owner).code == 0);
    window_management_json_destroy(filter_json_owner);
    const uint8_t invalid_filter[] = "{\"unknown\":true}";
    filter = window_management_window_filter_compile(invalid_filter, sizeof invalid_filter - 1,
                                                     &filter_json_owner);
    assert(!filter);
    filter_view = window_management_json_view(filter_json_owner);
    assert(filter_view.code == 1 && filter_view.data && filter_view.length);
    assert(window_management_window_filter_includes(filter, 0, 0, NULL, 0) == 2);
    window_management_json_destroy(filter_json_owner);
    window_management_window_filter_destroy(NULL);
    assert(window_management_rect_contains((WindowManagementRect){0, 0, 10, 10}, 0, 0) == 1);
    assert(window_management_rect_contains((WindowManagementRect){0, 0, 10, 10}, 10, 0) == 0);
    assert(window_management_abi_version() == WINDOW_MANAGEMENT_ABI_VERSION);
    assert(sizeof(WindowManagementRect) == 32 && sizeof(WindowManagementDisplay) == 80);
    assert(sizeof(WindowManagementPlacement) == 72 &&
           sizeof(WindowManagementPlacementResult) == 80);
    assert(sizeof(WindowManagementDisplayTarget) == 40 &&
           sizeof(WindowManagementDisplayTargetResult) == 48);
    assert(sizeof(WindowManagementPlacementRequest) == 128 &&
           sizeof(WindowManagementMoveRequest) == 8);
    assert(sizeof(WindowManagementJsonView) == 24);
    assert(sizeof(WindowManagementWindowIdentity) == 16 &&
           sizeof(WindowManagementWindowIdentityResult) == 24);
    WindowManagementRect area = {0, 0, 100, 80};
    WindowManagementPlacement grid = {
        .kind = 1, .columns = 2, .rows = 1, .column = 1, .row = 0, .column_span = 1, .row_span = 1};
    WindowManagementRectResult frame = window_management_placement(grid, area, 0);
    assert(frame.code == 0 && frame.frame.x == 50 && frame.frame.width == 50 &&
           frame.frame.height == 80);
    WindowManagementPlacement centered = {.kind = 2, .width_ratio = INFINITY, .height_ratio = NAN};
    WindowManagementPlacementResult normalized = window_management_placement_normalize(centered);
    assert(normalized.code == 0 && normalized.value.width_ratio == 1 &&
           normalized.value.height_ratio == 0);
    WindowManagementDisplayTarget target = {.kind = 3, .identifier = UINT64_MAX};
    assert(window_management_display_target_normalize(target).value.identifier == UINT64_MAX);
    assert(window_management_inset_normalize(INFINITY) == 0);
    WindowManagementDisplay display = {
        .frame = area, .visible_frame = area, .identifier = 0, .has_identifier = 1, .is_main = 1};
    WindowManagementPlacementRequest request = {
        .placement = grid, .display = {.kind = 3, .identifier = 0}, .area = 0, .inset = 0};
    frame = window_management_placement_resolve(request, area, &display, 1, 0);
    assert(frame.code == 0 && frame.frame.x == 50);
    request.display.identifier = 99;
    assert(window_management_placement_resolve(request, area, &display, 1, 0).code == 2);
    assert(window_management_placement_resolve(request, area, &display, 1, 1).code == 0);
    WindowManagementJson *encoded = window_management_placement_request_json(request);
    WindowManagementJsonView encoded_view = window_management_json_view(encoded);
    assert(encoded_view.code == 0 && encoded_view.data && encoded_view.length);
    size_t encoded_length = encoded_view.length;
    uint8_t *copy = malloc(encoded_length);
    assert(copy);
    memcpy(copy, encoded_view.data, encoded_length);
    window_management_json_destroy(encoded);
    WindowManagementJson *canonical = window_management_value_json(2, copy, encoded_length);
    WindowManagementJsonView canonical_view = window_management_json_view(canonical);
    assert(canonical_view.code == 0 && canonical_view.length == encoded_length);
    assert(memcmp(canonical_view.data, copy, encoded_length) == 0);
    window_management_json_destroy(canonical);
    free(copy);
    WindowManagementMoveRequest move = {.direction = 0, .preserves_relative_position = 1};
    assert(window_management_movement_resolve(move, area, NULL, 0, 1).code == 2);
    assert(window_management_movement_resolve(move, area, &display, SIZE_MAX, 1).code == 1);
    assert(sizeof(WindowManagementMovementPlanResult) == 40);
    WindowManagementRect reversed = {60, 60, -20, -20};
    WindowManagementMovementPlanResult plan =
        window_management_movement_plan(move, reversed, &display, 1, 0);
    assert(plan.code == 0 && plan.requires_frame_write == 0 && plan.frame.x == 40 &&
           plan.frame.y == 40 && plan.frame.width == 20 && plan.frame.height == 20);
    frame = window_management_movement_resolve(move, reversed, &display, 1, 0);
    assert(frame.code == 0 && frame.frame.x == plan.frame.x && frame.frame.y == plan.frame.y &&
           frame.frame.width == plan.frame.width && frame.frame.height == plan.frame.height);
    WindowManagementDisplay gap_displays[] = {
        {.frame = {100, -100, 300, 300}, .visible_frame = {100, -80, 300, 280}},
        {.frame = {-400, -100, 200, 300}, .visible_frame = {-400, -100, 200, 300}},
    };
    WindowManagementRect spanning = {-250, -50, 450, 100};
    assert(window_management_display_select(gap_displays, 2, 1, spanning, 0, 0, 0, 0, 0) == 0);
    WindowManagementPlacementRequest fill_current = {.placement = {.kind = 0},
                                                     .display = {.kind = 1}};
    frame = window_management_placement_resolve(fill_current, spanning, gap_displays, 2, 0);
    assert(frame.code == 0 && frame.frame.x == 100 && frame.frame.y == -80 &&
           frame.frame.height == 280);
    move.preserves_relative_position = 0;
    frame = window_management_movement_resolve(move, spanning, gap_displays, 2, 0);
    assert(frame.code == 0 && frame.frame.x == -400 && frame.frame.y == 0 &&
           frame.frame.width == 200);
    assert(window_management_display_index_containing_point(gap_displays, 2, 100, 0) == 1);
    assert(window_management_display_index_containing_point(gap_displays, 2, -25, 0) == -1);
    assert(window_management_display_index_containing_point(NULL, 0, 100, 0) == -1);
    assert(window_management_display_index_containing_point(NULL, 2, 100, 0) == -1);
    WindowManagementDisplay precision_displays[] = {
        {.frame = {0, 0, 100, 100}, .visible_frame = {0, 0, 100, 100}},
        {.frame = {200, 0, 100, 100}, .visible_frame = {200, 0, 100, 100}},
    };
    WindowManagementRect tiny = {1, 1, DBL_TRUE_MIN, DBL_TRUE_MIN};
    assert(window_management_display_select(precision_displays, 2, 1, tiny, 0, 0, 0, 0, 0) == 0);
    frame = window_management_placement_resolve(fill_current, tiny, precision_displays, 2, 0);
    assert(frame.code == 0 && frame.frame.x == 0 && frame.frame.width == 100);
    frame = window_management_movement_resolve(move, tiny, precision_displays, 2, 0);
    assert(frame.code == 0 && frame.frame.x == 250 && frame.frame.y == 50 &&
           frame.frame.width == tiny.width && frame.frame.height == tiny.height);
    const char *json = "{\"placement\":{\"kind\":\"fill\"}}";
    const char *bad = "{\"placement\":{\"kind\":\"fill\",\"extra\":0}}";
    WindowManagementJson *owner =
        window_management_value_json(2, (const uint8_t *)bad, strlen(bad));
    assert(window_management_json_view(owner).code == 1);
    window_management_json_destroy(owner);
    owner = window_management_value_json(99, (const uint8_t *)json, strlen(json));
    assert(window_management_json_view(owner).code == 1);
    window_management_json_destroy(owner);
    assert(window_management_json_view(NULL).code == 1);
    window_management_json_destroy(NULL);
    assert(window_management_windows_query_view(NULL).code == 2);
    window_management_windows_query_destroy(NULL);
    WindowManagementQuery *hit =
        window_management_windows_query(4, (WindowManagementWindowIdentity){0}, NAN, 0);
    assert(hit);
    WindowManagementQueryView hit_view = window_management_windows_query_view(hit);
#ifdef _WIN32
    assert(hit_view.code == 0 && hit_view.count == 0);
#else
    assert(hit_view.code == 1 && hit_view.count == 0);
#endif
    window_management_windows_query_destroy(hit);
#ifndef _WIN32
    WindowManagementWindowIdentityResult identity = window_management_windows_foreground_identity();
    assert(identity.code == 1 && identity.native_error == 0 && identity.identity.handle == 0 &&
           identity.identity.process == 0 && identity.identity.thread == 0);
    WindowManagementQuery *query = window_management_windows_displays();
    assert(window_management_windows_query_view(query).code == 1);
    window_management_windows_query_destroy(query);
#endif
    return 0;
}
