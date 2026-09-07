#ifndef FUTURATERM_LINUX_DESKTOP_H
#define FUTURATERM_LINUX_DESKTOP_H

#include <stddef.h>

#define FT_DESKTOP_MOONLIGHT_MISSING \
    "Moonlight is not installed on this computer. Install moonlight-qt to view a remote screen."
#define FT_DESKTOP_LAUNCH_FAILED \
    "Moonlight could not open this remote. If Moonlight is installed, the host may not be streaming — Sunshine must be running there (re-run the FuturaTerm Linux installer on that machine)."
#define FT_DESKTOP_VNC_MISSING \
    "A VNC viewer is not installed. Install a VNC viewer to view this machine's screen."
#define FT_DESKTOP_NOT_REMOTE "View Desktop is available on a remote project."
#define FT_DESKTOP_STREAM "stream"
#define FT_DESKTOP_APP "Desktop"

typedef enum {
    FT_DESKTOP_MOONLIGHT = 1,
    FT_DESKTOP_VNC = 2,
    FT_DESKTOP_MISSING = 3
} FtDesktopKind;

typedef struct {
    FtDesktopKind kind;
    char host[128];
    char url[280];
    char reason[256];
} FtDesktopPlan;

/* os_hint: Tailscale OS string or NULL. moonlight_available / vnc_available are 0/1. */
int ft_desktop_plan(
    const char *host,
    const char *os_hint,
    int moonlight_available,
    int vnc_available,
    FtDesktopPlan *out
);

/* argv after the binary: stream, host, Desktop, NULL. max >= 4. */
int ft_desktop_moonlight_argv(const char *host, const char **argv, int max);

#endif
