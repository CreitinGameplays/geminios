#ifndef WM_H
#define WM_H

#include "lvgl/lvgl.h"
#include <sys/types.h>

// Creates a standard system window with Title Bar, Controls, and Dragging support
// Returns the content area object where widgets can be added
lv_obj_t* create_window(const char* title, lv_coord_t w, lv_coord_t h);

lv_obj_t* create_client_window(const char* title, lv_coord_t w, lv_coord_t h, lv_obj_t** out_img, pid_t pid);

bool wm_is_window_valid(lv_obj_t* win);
#endif
