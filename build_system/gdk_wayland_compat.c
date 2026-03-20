#include <stddef.h>

typedef unsigned long GType;

GType gdk_wayland_display_get_type(void) {
    return 0;
}

void* gdk_wayland_display_get_wl_display(void* display) {
    (void)display;
    return NULL;
}

GType gdk_wayland_monitor_get_type(void) {
    return 0;
}

void* gdk_wayland_monitor_get_wl_output(void* monitor) {
    (void)monitor;
    return NULL;
}

void* gdk_wayland_seat_get_wl_seat(void* seat) {
    (void)seat;
    return NULL;
}

void* gdk_wayland_window_get_wl_surface(void* window) {
    (void)window;
    return NULL;
}

void gdk_wayland_window_set_use_custom_surface(void* window) {
    (void)window;
}
