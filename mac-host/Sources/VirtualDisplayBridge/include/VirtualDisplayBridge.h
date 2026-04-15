#ifndef VIRTUAL_DISPLAY_BRIDGE_H
#define VIRTUAL_DISPLAY_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool cc_create_virtual_display(
    uint32_t width,
    uint32_t height,
    uint32_t refresh_rate,
    bool hi_dpi,
    bool mirror_main,
    const char* display_name
);

bool cc_destroy_virtual_display(void);
bool cc_is_virtual_display_active(void);
uint32_t cc_virtual_display_id(void);

#ifdef __cplusplus
}
#endif

#endif
