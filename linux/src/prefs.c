#define _GNU_SOURCE
#include "prefs.h"

#include "command.h"
#include "util.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t k_palette[16][3] = {
    {0, 0, 0},       {170, 0, 0},     {0, 170, 0},     {170, 85, 0},
    {0, 0, 170},     {170, 0, 170},   {0, 170, 170},   {170, 170, 170},
    {85, 85, 85},    {255, 85, 85},   {85, 255, 85},   {255, 255, 85},
    {85, 85, 255},   {255, 85, 255},   {85, 255, 255},  {255, 255, 255},
};

void ft_prefs_defaults(FtPrefs *p) {
    memset(p, 0, sizeof(*p));
    p->sidebar_visible = 1;
    p->window_opacity = 1.0;
    ft_str_set(p->font, sizeof(p->font), "Monospace");
    p->font_size = 12;
    memcpy(p->palette, k_palette, sizeof(k_palette));
    p->background[0] = 18;
    p->background[1] = 20;
    p->background[2] = 26;
    p->foreground[0] = 220;
    p->foreground[1] = 220;
    p->foreground[2] = 220;
    p->auto_name_tabs = 1;
    ft_str_set(p->quick_hotkey, sizeof(p->quick_hotkey), "ctrl+grave");
    int n = 0;
    const FtCommand *cmds = ft_commands(&n);
    p->nbinds = 0;
    for (int i = 0; i < n && p->nbinds < FT_PREFS_MAX_BINDS; i++) {
        ft_str_set(p->binds[p->nbinds].action, sizeof(p->binds[0].action), cmds[i].id);
        ft_str_set(p->binds[p->nbinds].shortcut, sizeof(p->binds[0].shortcut), cmds[i].default_shortcut);
        p->nbinds++;
    }
}

static void set_bind(FtPrefs *p, const char *action, const char *shortcut) {
    for (int i = 0; i < p->nbinds; i++) {
        if (strcmp(p->binds[i].action, action) == 0) {
            ft_str_set(p->binds[i].shortcut, sizeof(p->binds[i].shortcut), shortcut);
            return;
        }
    }
    if (p->nbinds < FT_PREFS_MAX_BINDS) {
        ft_str_set(p->binds[p->nbinds].action, sizeof(p->binds[0].action), action);
        ft_str_set(p->binds[p->nbinds].shortcut, sizeof(p->binds[0].shortcut), shortcut);
        p->nbinds++;
    }
}

const char *ft_prefs_shortcut(const FtPrefs *p, const char *action_id) {
    if (!p || !action_id) {
        return "none";
    }
    for (int i = 0; i < p->nbinds; i++) {
        if (strcmp(p->binds[i].action, action_id) == 0) {
            return p->binds[i].shortcut;
        }
    }
    const FtCommand *c = ft_command_by_id(action_id);
    return c ? c->default_shortcut : "none";
}

int ft_prefs_load(const char *path, FtPrefs *p) {
    ft_prefs_defaults(p);
    char buf[16384];
    if (ft_read_file(path, buf, sizeof(buf)) != 0) {
        return -1;
    }
    char *line = buf;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        if (nl) {
            *nl = 0;
        }
        char *eq = strchr(line, '=');
        if (eq && line[0] != '#') {
            *eq = 0;
            const char *k = line;
            const char *v = eq + 1;
            if (strcmp(k, "sidebar") == 0) {
                p->sidebar_visible = atoi(v);
            } else if (strcmp(k, "opacity") == 0) {
                p->window_opacity = strtod(v, NULL);
            } else if (strcmp(k, "font") == 0) {
                ft_str_set(p->font, sizeof(p->font), v);
            } else if (strcmp(k, "font_size") == 0) {
                p->font_size = atoi(v);
            } else if (strcmp(k, "auto_name_tabs") == 0) {
                p->auto_name_tabs = atoi(v);
            } else if (strcmp(k, "quick_hotkey") == 0) {
                ft_str_set(p->quick_hotkey, sizeof(p->quick_hotkey), v);
            } else if (strncmp(k, "key.", 4) == 0) {
                set_bind(p, k + 4, v);
            }
        }
        line = nl ? nl + 1 : NULL;
    }
    if (p->window_opacity < 0.4) {
        p->window_opacity = 0.4;
    }
    if (p->window_opacity > 1.0) {
        p->window_opacity = 1.0;
    }
    if (p->font_size < 8) {
        p->font_size = 8;
    }
    return 0;
}

int ft_prefs_save(const char *path, const FtPrefs *p) {
    char buf[16384];
    FtBuf b;
    ft_buf_init(&b, buf, sizeof(buf));
    ft_buf_printf(&b, "sidebar=%d\n", p->sidebar_visible ? 1 : 0);
    ft_buf_printf(&b, "opacity=%.2f\n", p->window_opacity);
    ft_buf_printf(&b, "font=%s\n", p->font);
    ft_buf_printf(&b, "font_size=%d\n", p->font_size);
    ft_buf_printf(&b, "auto_name_tabs=%d\n", p->auto_name_tabs ? 1 : 0);
    ft_buf_printf(&b, "quick_hotkey=%s\n", p->quick_hotkey);
    for (int i = 0; i < p->nbinds; i++) {
        ft_buf_printf(&b, "key.%s=%s\n", p->binds[i].action, p->binds[i].shortcut);
    }
    return ft_write_file(path, buf);
}

static int parse_hex_color(const char *s, uint8_t *rgb) {
    if (!s) {
        return -1;
    }
    if (s[0] == '#') {
        s++;
    }
    unsigned int v = 0;
    if (strlen(s) != 6) {
        return -1;
    }
    if (sscanf(s, "%06x", &v) != 1) {
        return -1;
    }
    rgb[0] = (uint8_t)((v >> 16) & 0xff);
    rgb[1] = (uint8_t)((v >> 8) & 0xff);
    rgb[2] = (uint8_t)(v & 0xff);
    return 0;
}

static void trim(char *s) {
    char *a = s;
    while (*a == ' ' || *a == '\t') {
        a++;
    }
    if (a != s) {
        memmove(s, a, strlen(a) + 1);
    }
    size_t n = strlen(s);
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r')) {
        s[--n] = 0;
    }
    if ((s[0] == '"' && s[n - 1] == '"') || (s[0] == '\'' && s[n - 1] == '\'')) {
        s[n - 1] = 0;
        memmove(s, s + 1, n - 1);
    }
}

int ft_ghostty_parse(const char *text, FtPrefs *p) {
    if (!text || !p) {
        return -1;
    }
    char buf[32768];
    snprintf(buf, sizeof(buf), "%s", text);
    char *line = buf;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        if (nl) {
            *nl = 0;
        }
        char *hash = strchr(line, '#');
        if (hash && (hash == line || hash[-1] == ' ' || hash[-1] == '\t') && !isxdigit((unsigned char)hash[1])) {
            *hash = 0;
        }
        char *eq = strchr(line, '=');
        if (eq) {
            *eq = 0;
            trim(line);
            trim(eq + 1);
            const char *k = line;
            const char *v = eq + 1;
            if (strcmp(k, "font-family") == 0 || strcmp(k, "font-family-bold") == 0) {
                if (k[11] == 0 || p->font[0] == 0 || strcmp(p->font, "Monospace") == 0) {
                    ft_str_set(p->font, sizeof(p->font), v);
                }
            } else if (strcmp(k, "font-size") == 0) {
                p->font_size = atoi(v);
            } else if (strcmp(k, "background") == 0) {
                parse_hex_color(v, p->background);
            } else if (strcmp(k, "foreground") == 0) {
                parse_hex_color(v, p->foreground);
            } else if (strcmp(k, "palette") == 0) {
                const char *eq2 = strchr(v, '=');
                if (eq2) {
                    int idx = atoi(v);
                    if (idx >= 0 && idx < 16) {
                        parse_hex_color(eq2 + 1, p->palette[idx]);
                        p->has_palette = 1;
                    }
                }
            } else if (strcmp(k, "keybind") == 0) {
                /* ghostty: chord=action. Map a few actions onto ours. */
                char chord[64], action[64];
                const char *eq2 = strchr(v, '=');
                if (eq2) {
                    size_t cl = (size_t)(eq2 - v);
                    if (cl < sizeof(chord)) {
                        memcpy(chord, v, cl);
                        chord[cl] = 0;
                        ft_str_set(action, sizeof(action), eq2 + 1);
                        if (strstr(action, "new_tab") || strcmp(action, "new_tab") == 0) {
                            set_bind(p, "newTab", chord);
                        } else if (strstr(action, "close_surface") || strstr(action, "close_tab")) {
                            set_bind(p, "closePane", chord);
                        }
                    }
                }
            }
        }
        line = nl ? nl + 1 : NULL;
    }
    return 0;
}

int ft_ghostty_load_default_files(FtPrefs *p) {
    const char *home = getenv("HOME");
    const char *xdg = getenv("XDG_CONFIG_HOME");
    char bases[4][512];
    int nb = 0;
    if (xdg && xdg[0]) {
        snprintf(bases[nb++], sizeof(bases[0]), "%s/ghostty", xdg);
    }
    if (home && home[0]) {
        snprintf(bases[nb++], sizeof(bases[0]), "%s/.config/ghostty", home);
    }
    const char *names[] = {"config", "config.ghostty"};
    char text[32768];
    text[0] = 0;
    p->nghostty_files = 0;
    for (int b = 0; b < nb; b++) {
        for (int i = 0; i < 2; i++) {
            char path[640];
            snprintf(path, sizeof(path), "%s/%s", bases[b], names[i]);
            char chunk[16384];
            if (ft_read_file(path, chunk, sizeof(chunk)) == 0) {
                if (p->nghostty_files < 8) {
                    ft_str_set(p->ghostty_files[p->nghostty_files], sizeof(p->ghostty_files[0]), path);
                    p->nghostty_files++;
                }
                size_t used = strlen(text);
                snprintf(text + used, sizeof(text) - used, "%s\n", chunk);
            }
        }
    }
    if (text[0]) {
        return ft_ghostty_parse(text, p);
    }
    return -1;
}
