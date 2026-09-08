#include "../src/command.h"
#include "../src/desktop.h"

#include <stdio.h>
#include <string.h>

static int fails;

static void expect(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        fails++;
    }
}

int main(void) {
    const FtCommand *cmd = ft_command_by_id("viewDesktop");
    expect(cmd != NULL, "viewDesktop command exists");
    expect(cmd && strcmp(cmd->title, "View Desktop") == 0, "title");
    expect(
        cmd && strcmp(cmd->help, "Open a live view of this remote machine's screen.") == 0,
        "help"
    );
    expect(cmd && strcmp(cmd->category, "projects") == 0, "category");
    expect(cmd && strcmp(cmd->default_shortcut, "none") == 0, "unbound");

    FtDesktopPlan p;
    expect(ft_desktop_plan("dts-3.tailnet.ts.net", "linux", 1, 1, &p) == 0, "linux plan");
    expect(p.kind == FT_DESKTOP_MOONLIGHT, "linux moonlight");
    expect(strcmp(p.host, "dts-3.tailnet.ts.net") == 0, "linux host");
    expect(p.url[0] == 0, "no moonlight url scheme");
    const char *argv[4];
    expect(ft_desktop_moonlight_argv(p.host, argv, 4) == 3, "moonlight argv count");
    expect(strcmp(argv[0], "stream") == 0, "argv stream");
    expect(strcmp(argv[1], "dts-3.tailnet.ts.net") == 0, "argv host");
    expect(strcmp(argv[2], "Desktop") == 0, "argv Desktop");
    expect(argv[3] == NULL, "argv nil");
    expect(strchr(argv[1], '@') == NULL, "no user@ in host");
    expect(ft_desktop_moonlight_argv("", argv, 4) == -1, "empty host argv");

    expect(ft_desktop_plan("dts-0.tailnet.ts.net", "macOS", 1, 1, &p) == 0, "mac plan");
    expect(p.kind == FT_DESKTOP_VNC, "macos vnc");
    expect(strcmp(p.url, "vnc://dts-0.tailnet.ts.net") == 0, "vnc url");

    expect(ft_desktop_plan("box", "linux", 0, 1, &p) == 0, "linux no moonlight");
    expect(p.kind == FT_DESKTOP_MISSING, "missing moonlight");
    expect(strcmp(p.reason, FT_DESKTOP_MOONLIGHT_MISSING) == 0, "moonlight reason");
    expect(strstr(p.reason, "brew") == NULL, "no brew");
    expect(strstr(p.reason, "omarchy-install") == NULL, "no omarchy-install");
    expect(strstr(p.reason, "ssh") == NULL, "no ssh install");
    expect(strstr(FT_DESKTOP_LAUNCH_FAILED, "Sunshine") != NULL, "launch failed names host");
    expect(strstr(FT_DESKTOP_LAUNCH_FAILED, "ssh") == NULL, "launch failed no ssh");
    expect(strstr(FT_DESKTOP_LAUNCH_FAILED, "brew") == NULL, "launch failed no brew");

    expect(ft_desktop_plan("box", "macOS", 1, 0, &p) == 0, "mac no vnc");
    expect(p.kind == FT_DESKTOP_MISSING, "missing vnc");
    expect(strcmp(p.reason, FT_DESKTOP_VNC_MISSING) == 0, "vnc reason");

    expect(ft_desktop_plan("box", NULL, 1, 1, &p) == 0, "unknown os");
    expect(p.kind == FT_DESKTOP_MOONLIGHT, "unknown leans moonlight");

    expect(ft_desktop_plan("", NULL, 1, 1, &p) == 0, "empty host");
    expect(p.kind == FT_DESKTOP_MISSING, "empty missing");
    expect(strcmp(p.reason, FT_DESKTOP_NOT_REMOTE) == 0, "empty not remote");

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_desktop: ok");
    return 0;
}
