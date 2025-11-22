#include "wm.h"
#include <map>
#include <string>
#include <iostream>

// Structure to save window state for Restore functionality
struct WindowState {
    bool maximized;
    lv_coord_t orig_x, orig_y, orig_w, orig_h;
};

// Track state of windows
static std::map<lv_obj_t*, WindowState> win_cache;

// --- Event Handlers ---

static void win_close_event_cb(lv_event_t * e) {
    lv_obj_t * btn = lv_event_get_target(e);
    lv_obj_t * win = (lv_obj_t*)lv_event_get_user_data(e);
    
    // Clean up cache
    win_cache.erase(win);
    lv_obj_del(win);
}

static void win_minimize_event_cb(lv_event_t * e) {
    lv_obj_t * win = (lv_obj_t*)lv_event_get_user_data(e);
    // Simple hide for now (Taskbar integration would go here)
    lv_obj_add_flag(win, LV_OBJ_FLAG_HIDDEN);
    std::cout << "[WM] Window minimized (hidden). Re-launch to see it again." << std::endl;
}

static void win_maximize_event_cb(lv_event_t * e) {
    lv_obj_t * win = (lv_obj_t*)lv_event_get_user_data(e);
    
    if (win_cache.find(win) == win_cache.end()) {
        // Should not happen, but init if missing
        win_cache[win] = {false, 0, 0, 0, 0};
    }

    WindowState &state = win_cache[win];

    if (state.maximized) {
        // Restore
        lv_obj_set_size(win, state.orig_w, state.orig_h);
        lv_obj_set_pos(win, state.orig_x, state.orig_y);
        state.maximized = false;
    } else {
        // Maximize
        // Save current state
        state.orig_x = lv_obj_get_x(win);
        state.orig_y = lv_obj_get_y(win);
        state.orig_w = lv_obj_get_width(win);
        state.orig_h = lv_obj_get_height(win);

        // Set to full screen size (minus taskbar roughly)
        lv_obj_set_pos(win, 0, 0);
        lv_obj_set_size(win, lv_disp_get_hor_res(NULL), lv_disp_get_ver_res(NULL) - 48); // 48 is taskbar height
        state.maximized = true;
    }
}

// Handle Dragging of the Window via the Header
static void win_header_drag_event_cb(lv_event_t * e) {
    lv_obj_t * header = lv_event_get_target(e);
    lv_obj_t * win = lv_obj_get_parent(header);
    
    lv_indev_t * indev = lv_indev_get_act();
    if(!indev) return;

    lv_point_t vect;
    lv_indev_get_vect(indev, &vect);

    lv_coord_t x = lv_obj_get_x(win) + vect.x;
    lv_coord_t y = lv_obj_get_y(win) + vect.y;

    // Robust clamping to keep window reachable
    lv_coord_t scr_w = lv_disp_get_hor_res(NULL);
    lv_coord_t scr_h = lv_disp_get_ver_res(NULL);
    lv_coord_t win_w = lv_obj_get_width(win);
    
    // Prevent moving top header completely off-screen
    if (y < 0) y = 0;
    if (y > scr_h - 40) y = scr_h - 40; // Keep at least header visible

    // Prevent moving completely off sides
    if (x + win_w < 40) x = 40 - win_w;
    if (x > scr_w - 40) x = scr_w - 40;

    lv_obj_set_pos(win, x, y);
}

// --- Cleanup Handler ---
static void win_delete_event_cb(lv_event_t * e) {
    lv_obj_t * win = lv_event_get_target(e);
    win_cache.erase(win);
}

lv_obj_t* create_window(const char* title, lv_coord_t w, lv_coord_t h) {
    // Create Window Object
    lv_obj_t * win = lv_win_create(lv_scr_act(), 40); // 40px header height
    lv_win_add_title(win, title);
    
    lv_obj_set_size(win, w, h);
    lv_obj_center(win);

    // Store initial state
    WindowState state;
    state.maximized = false;
    state.orig_w = w;
    state.orig_h = h;
    state.orig_x = (lv_disp_get_hor_res(NULL) - w) / 2;
    state.orig_y = (lv_disp_get_ver_res(NULL) - h) / 2;
    win_cache[win] = state;

    // Style the Window
    // Header
    lv_obj_t * header = lv_win_get_header(win);
    lv_obj_set_style_bg_color(header, lv_color_hex(0x303030), 0); // Dark Grey
    lv_obj_set_style_text_color(header, lv_color_hex(0xFFFFFF), 0);
    
    // Content
    lv_obj_t * content = lv_win_get_content(win);
    lv_obj_set_style_bg_color(content, lv_color_hex(0xF0F0F0), 0); // Light Grey

    // Make Header Draggable
    lv_obj_add_flag(header, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(header, win_header_drag_event_cb, LV_EVENT_PRESSING, NULL);

    // Add Control Buttons
    // Close (Red)
    lv_obj_t * btn_close = lv_win_add_btn(win, LV_SYMBOL_CLOSE, 40);
    lv_obj_set_style_bg_color(btn_close, lv_color_hex(0xC0392B), 0);
    lv_obj_add_event_cb(btn_close, win_close_event_cb, LV_EVENT_CLICKED, win);

    // Maximize
    lv_obj_t * btn_max = lv_win_add_btn(win, LV_SYMBOL_UP, 40);
    lv_obj_add_event_cb(btn_max, win_maximize_event_cb, LV_EVENT_CLICKED, win);

    // Minimize
    lv_obj_t * btn_min = lv_win_add_btn(win, LV_SYMBOL_MINUS, 40);
    lv_obj_add_event_cb(btn_min, win_minimize_event_cb, LV_EVENT_CLICKED, win);

    // Add delete handler to clean up map
    lv_obj_add_event_cb(win, win_delete_event_cb, LV_EVENT_DELETE, NULL);

    // Bring to front when clicked
    lv_obj_add_event_cb(win, [](lv_event_t* e){
        lv_obj_move_foreground(lv_event_get_target(e));
    }, LV_EVENT_CLICKED, NULL);

    return content; // Return content area for adding widgets
}
