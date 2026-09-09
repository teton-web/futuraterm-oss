#include "../src/command.h"
#include "../src/prefs.h"
#include "../src/util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;

static void expect(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        fails++;
    }
}

int main(void) {
    FtPrefs p;
    ft_prefs_defaults(&p);
    expect(p.sidebar_visible == 1, "sidebar default");
    expect(p.auto_name_tabs == 1, "auto name");
    p.window_opacity = 0.85;
    p.font_size = 14;
    ft_str_set(p.font, sizeof(p.font), "JetBrains Mono");

    char dir[] = "/tmp/ft-prefs-XXXXXX";
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    char path[256];
    snprintf(path, sizeof(path), "%s/prefs", dir);
    expect(ft_prefs_save(path, &p) == 0, "save");

    FtPrefs loaded;
    expect(ft_prefs_load(path, &loaded) == 0, "load");
    expect(loaded.font_size == 14, "font size round-trip");
    expect(strcmp(loaded.font, "JetBrains Mono") == 0, "font round-trip");
    expect(loaded.window_opacity > 0.84 && loaded.window_opacity < 0.86, "opacity round-trip");
    expect(strcmp(ft_prefs_shortcut(&loaded, "newTab"), "super+t") == 0, "default newTab bind");

    const char *ghostty =
        "font-family = Iosevka\n"
        "font-size = 16\n"
        "background = #1a1b26\n"
        "foreground = #c0caf5\n"
        "palette = 0=#000000\n"
        "palette = 1=#ff0000\n";
    FtPrefs g;
    ft_prefs_defaults(&g);
    expect(ft_ghostty_parse(ghostty, &g) == 0, "parse ghostty");
    expect(strcmp(g.font, "Iosevka") == 0, "ghostty font");
    expect(g.font_size == 16, "ghostty size");
    expect(g.background[0] == 0x1a, "bg r");
    expect(g.palette[1][0] == 0xff, "palette 1 red");

    int n = 0;
    int idx[16];
    n = ft_command_filter("split", idx, 16);
    expect(n > 0, "filter split");
    int ncmds = 0;
    const FtCommand *cmds = ft_commands(&ncmds);
    int found_split = 0, found_tab = 0, found_open = 0;
    n = ft_command_filter("split", idx, 16);
    for (int i = 0; i < n; i++) {
        if (strstr(cmds[idx[i]].id, "split") || strstr(cmds[idx[i]].title, "Split")) {
            found_split = 1;
        }
    }
    n = ft_command_filter("new tab", idx, 16);
    for (int i = 0; i < n; i++) {
        if (strcmp(cmds[idx[i]].id, "newTab") == 0) {
            found_tab = 1;
        }
    }
    n = ft_command_filter("open", idx, 16);
    for (int i = 0; i < n; i++) {
        if (strcmp(cmds[idx[i]].id, "openProject") == 0) {
            found_open = 1;
        }
    }
    expect(found_split, "palette includes split");
    expect(found_tab, "palette includes new tab");
    expect(found_open, "palette includes open project");

    unlink(path);
    rmdir(dir);

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_prefs: ok");
    return 0;
}
