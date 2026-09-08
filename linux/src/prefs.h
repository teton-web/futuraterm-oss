#ifndef FUTURATERM_LINUX_PREFS_H
#define FUTURATERM_LINUX_PREFS_H

#include <stddef.h>
#include <stdint.h>

#define FT_PREFS_MAX_BINDS 64

typedef struct {
    char action[40];
    char shortcut[40];
} FtKeybind;

typedef struct {
    int sidebar_visible;
    double window_opacity;
    char font[128];
    int font_size;
    uint8_t palette[16][3];
    uint8_t background[3];
    uint8_t foreground[3];
    int has_palette;
    int auto_name_tabs;
    char quick_hotkey[40];
    FtKeybind binds[FT_PREFS_MAX_BINDS];
    int nbinds;
    char ghostty_files[8][512];
    int nghostty_files;
} FtPrefs;

void ft_prefs_defaults(FtPrefs *p);
int ft_prefs_load(const char *path, FtPrefs *p);
int ft_prefs_save(const char *path, const FtPrefs *p);
int ft_ghostty_parse(const char *text, FtPrefs *p);
int ft_ghostty_load_default_files(FtPrefs *p);
const char *ft_prefs_shortcut(const FtPrefs *p, const char *action_id);

#endif
