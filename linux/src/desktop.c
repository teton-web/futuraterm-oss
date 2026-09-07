#define _GNU_SOURCE
#include "desktop.h"

#include "util.h"

#include <stdio.h>
#include <string.h>

static int hint_macos(const char *hint) {
    if (!hint || !hint[0]) {
        return 0;
    }
    return strcasestr(hint, "mac") != NULL || ft_str_ieq(hint, "ios") || ft_str_ieq(hint, "ipados")
        || strcasestr(hint, "darwin") != NULL;
}

int ft_desktop_plan(
    const char *host,
    const char *os_hint,
    int moonlight_available,
    int vnc_available,
    FtDesktopPlan *out
) {
    if (!out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    const char *h = host ? host : "";
    while (*h == ' ' || *h == '\t') {
        h++;
    }
    if (!h[0]) {
        out->kind = FT_DESKTOP_MISSING;
        ft_str_set(out->reason, sizeof(out->reason), FT_DESKTOP_NOT_REMOTE);
        return 0;
    }
    ft_str_set(out->host, sizeof(out->host), h);
    if (hint_macos(os_hint)) {
        if (!vnc_available) {
            out->kind = FT_DESKTOP_MISSING;
            ft_str_set(out->reason, sizeof(out->reason), FT_DESKTOP_VNC_MISSING);
            return 0;
        }
        out->kind = FT_DESKTOP_VNC;
        snprintf(out->url, sizeof(out->url), "vnc://%s", out->host);
        return 0;
    }
    if (!moonlight_available) {
        out->kind = FT_DESKTOP_MISSING;
        ft_str_set(out->reason, sizeof(out->reason), FT_DESKTOP_MOONLIGHT_MISSING);
        return 0;
    }
    out->kind = FT_DESKTOP_MOONLIGHT;
    return 0;
}

int ft_desktop_moonlight_argv(const char *host, const char **argv, int max) {
    if (!host || !host[0] || !argv || max < 4) {
        return -1;
    }
    argv[0] = FT_DESKTOP_STREAM;
    argv[1] = host;
    argv[2] = FT_DESKTOP_APP;
    argv[3] = NULL;
    return 3;
}
