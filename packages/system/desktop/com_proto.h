#ifndef COM_PROTO_H
#define COM_PROTO_H

#include <cstdint>

#define WM_SOCKET_PATH "/tmp/gemini_wm.sock"

enum MsgType : uint8_t {
    MSG_HELLO = 1,
    MSG_FRAME = 2,
    MSG_INPUT = 3,
    MSG_BYE   = 4
};

struct __attribute__((packed)) MsgHeader {
    uint8_t type;
    uint32_t len;
};

struct __attribute__((packed)) HelloPayload {
    uint32_t width;
    uint32_t height;
    char title[64];
};

struct __attribute__((packed)) FramePayload {
    int32_t x;
    int32_t y;
    int32_t w;
    int32_t h;
};

struct __attribute__((packed)) InputPayload {
    int32_t x;
    int32_t y;
    uint32_t state; // 0=Released, 1=Pressed
};

#endif
