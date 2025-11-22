#include <unistd.h>
#include <iostream>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <vector>
#include "lvgl/lvgl.h"
#include "../desktop/com_proto.h"

int g_sock = -1;

void socket_flush_cb(lv_disp_drv_t * disp_drv, const lv_area_t * area, lv_color_t * color_p) {
    if (g_sock < 0) {
        lv_disp_flush_ready(disp_drv);
        return;
    }

    int32_t w = area->x2 - area->x1 + 1;
    int32_t h = area->y2 - area->y1 + 1;

    MsgHeader hdr;
    hdr.type = MSG_FRAME;
    hdr.len = sizeof(FramePayload) + (w * h * 4); // ARGB

    FramePayload frame;
    frame.x = area->x1;
    frame.y = area->y1;
    frame.w = w;
    frame.h = h;

    // Send Header
    write(g_sock, &hdr, sizeof(hdr));
    // Send Payload Info
    write(g_sock, &frame, sizeof(frame));
    // Send Data (Convert if necessary, but LVGL 32bit is likely compatible with ARGB8888)
    // LV_COLOR_DEPTH 32 is usually ARGB or BGRA. We assume match for now.
    write(g_sock, color_p, w * h * 4);

    lv_disp_flush_ready(disp_drv);
}

static void btn_event_cb(lv_event_t * e) {
    lv_event_code_t code = lv_event_get_code(e);
    if(code == LV_EVENT_CLICKED) {
        std::cout << "[TestGUI] Closing..." << std::endl;
        close(g_sock);
        exit(0);
    }
}

int main(void) {
    // 1. Connect to Desktop
    g_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_sock < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, WM_SOCKET_PATH, sizeof(addr.sun_path)-1);

    if (connect(g_sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect to desktop failed");
        return 1;
    }

    // 2. Send Hello
    MsgHeader hdr;
    hdr.type = MSG_HELLO;
    hdr.len = sizeof(HelloPayload);
    write(g_sock, &hdr, sizeof(hdr));

    HelloPayload hello;
    hello.width = 300;
    hello.height = 200;
    strncpy(hello.title, "Test Client", 63);
    write(g_sock, &hello, sizeof(hello));

    // 3. Init LVGL
    lv_init();

    // 4. Setup Buffer & Display
    static lv_disp_draw_buf_t disp_buf;
    static lv_color_t buf[300 * 200]; // Full frame buffer for simplicity
    lv_disp_draw_buf_init(&disp_buf, buf, NULL, 300 * 200);

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.draw_buf = &disp_buf;
    disp_drv.flush_cb = socket_flush_cb;
    disp_drv.hor_res = 300;
    disp_drv.ver_res = 200;
    lv_disp_drv_register(&disp_drv);

    // Create UI
    // We treat the whole screen as our window
    lv_obj_set_style_bg_color(lv_scr_act(), lv_color_hex(0xFFFACD), 0);

    lv_obj_t * label = lv_label_create(lv_scr_act());
    lv_label_set_text(label, "Remote Rendering!\nVia Socket");
    lv_obj_center(label);

    lv_obj_t * btn = lv_btn_create(lv_scr_act());
    lv_obj_align(btn, LV_ALIGN_BOTTOM_MID, 0, -10);
    lv_obj_add_event_cb(btn, btn_event_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_set_style_bg_color(btn, lv_color_hex(0xFF0000), 0);

    lv_obj_t * btn_label = lv_label_create(btn);
    lv_label_set_text(btn_label, "Close");

    std::cout << "[TestGUI] Running..." << std::endl;

    while(1) {
        lv_timer_handler();
        usleep(10000); // 10ms
    }

    return 0;
}
