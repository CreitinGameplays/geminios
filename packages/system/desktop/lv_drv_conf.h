#ifndef LV_DRV_CONF_H
#define LV_DRV_CONF_H

#include "lv_conf.h"

/*-------------------
 *  Frame Buffer
 *-------------------*/
#define USE_FBDEV           1
#define FBDEV_PATH          "/dev/fb0"

/*-------------------
 *  Input (evdev)
 *-------------------*/
#define USE_EVDEV           1
#define EVDEV_NAME          "/dev/input/event0"
#define EVDEV_SWAP_AXES     0
#define EVDEV_CALIBRATE     0
#define EVDEV_SCALE         0
#define EVDEV_SCALE_HOR_RES (0)
#define EVDEV_SCALE_VER_RES (0)

#endif /*LV_DRV_CONF_H*/
