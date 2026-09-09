#define _GNU_SOURCE
#include "path.h"

#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void strip_slash(char *s) {
    size_t n = strlen(s);
    while (n > 1 && s[n - 1] == '/') {
        s[--n] = 0;
    }
}

static void standardize(char *path) {
    char parts[64][256];
    int n = 0;
    int abs = path[0] == '/';
    char *p = path;
    while (*p) {
        while (*p == '/') {
            p++;
        }
        if (!*p) {
            break;
        }
        char *slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        if (len == 1 && p[0] == '.') {
            p += len;
            continue;
        }
        if (len == 2 && p[0] == '.' && p[1] == '.') {
            if (n > 0) {
                n--;
            }
            p += len;
            continue;
        }
        if (n < 64 && len < sizeof(parts[0])) {
            memcpy(parts[n], p, len);
            parts[n][len] = 0;
            n++;
        }
        p += len;
    }
    char out[1024];
    size_t o = 0;
    if (abs) {
        out[o++] = '/';
    }
    for (int i = 0; i < n; i++) {
        if (i && o + 1 < sizeof(out)) {
            out[o++] = '/';
        }
        size_t l = strlen(parts[i]);
        if (o + l >= sizeof(out)) {
            break;
        }
        memcpy(out + o, parts[i], l);
        o += l;
    }
    if (o == 0) {
        out[o++] = abs ? '/' : '.';
    }
    out[o] = 0;
    if (o == 0 || (abs && o == 1)) {
        snprintf(path, 1024, "%s", abs ? "/" : ".");
        return;
    }
    snprintf(path, 1024, "%s", out);
}

int ft_path_parse(const char *raw, FtProjectPath *out) {
    if (!out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    if (!raw) {
        return -1;
    }
    while (*raw == ' ' || *raw == '\t') {
        raw++;
    }
    if (!raw[0]) {
        return -1;
    }
    ft_str_set(out->raw, sizeof(out->raw), raw);
    if (strcmp(raw, FT_PINNED_PATH_MARKER) == 0) {
        out->kind = FT_PATH_PINNED;
        ft_str_set(out->dir, sizeof(out->dir), FT_PINNED_PATH_MARKER);
        return 0;
    }
    const char *slash = strchr(raw, '/');
    const char *colon = strchr(raw, ':');
    if (colon && (!slash || colon < slash)) {
        char userhost[192];
        size_t uh = (size_t)(colon - raw);
        if (uh == 0 || uh >= sizeof(userhost)) {
            return -1;
        }
        memcpy(userhost, raw, uh);
        userhost[uh] = 0;
        const char *directory = colon + 1;
        if (!directory[0]) {
            return -1;
        }
        char *at = strrchr(userhost, '@');
        if (at) {
            *at = 0;
            if (!userhost[0] || !at[1] || at[1] == '~') {
                return -1;
            }
            ft_str_set(out->user, sizeof(out->user), userhost);
            ft_str_set(out->host, sizeof(out->host), at + 1);
        } else {
            if (userhost[0] == '~') {
                return -1;
            }
            ft_str_set(out->host, sizeof(out->host), userhost);
        }
        ft_str_set(out->dir, sizeof(out->dir), directory);
        out->kind = FT_PATH_REMOTE;
        return 0;
    }
    if (raw[0] != '/' && raw[0] != '~') {
        return -1;
    }
    out->kind = FT_PATH_LOCAL;
    ft_str_set(out->dir, sizeof(out->dir), raw);
    return 0;
}

int ft_path_is_remote(const char *raw) {
    FtProjectPath p;
    return ft_path_parse(raw, &p) == 0 && p.kind == FT_PATH_REMOTE;
}

int ft_path_is_local(const char *raw) {
    FtProjectPath p;
    return ft_path_parse(raw, &p) == 0 && p.kind == FT_PATH_LOCAL;
}

void ft_path_canonical_local(const char *path, char *out, size_t n) {
    const char *home = getenv("HOME");
    if (!home || !home[0]) {
        home = ".";
    }
    char expanded[1024];
    if (!path) {
        ft_str_set(out, n, "");
        return;
    }
    if (strcmp(path, "~") == 0) {
        snprintf(expanded, sizeof(expanded), "%s", home);
    } else if (strncmp(path, "~/", 2) == 0) {
        snprintf(expanded, sizeof(expanded), "%s%s", home, path + 1);
    } else {
        snprintf(expanded, sizeof(expanded), "%s", path);
    }
    standardize(expanded);
    strip_slash(expanded);
    ft_str_set(out, n, expanded);
}

void ft_path_home_contract(const char *path, char *out, size_t n) {
    const char *home = getenv("HOME");
    if (!home || !path) {
        ft_str_set(out, n, path ? path : "");
        return;
    }
    size_t hl = strlen(home);
    if (strcmp(path, home) == 0) {
        ft_str_set(out, n, "~");
        return;
    }
    if (strncmp(path, home, hl) == 0 && path[hl] == '/') {
        snprintf(out, n, "~%s", path + hl);
        return;
    }
    ft_str_set(out, n, path);
}

int ft_path_matches(const char *a, const char *b) {
    FtProjectPath pa, pb;
    if (ft_path_parse(a, &pa) != 0 || ft_path_parse(b, &pb) != 0) {
        return 0;
    }
    if (pa.kind != pb.kind) {
        return 0;
    }
    if (pa.kind == FT_PATH_PINNED) {
        return 1;
    }
    if (pa.kind == FT_PATH_LOCAL) {
        char ca[1024], cb[1024];
        ft_path_canonical_local(pa.dir, ca, sizeof(ca));
        ft_path_canonical_local(pb.dir, cb, sizeof(cb));
        return strcmp(ca, cb) == 0;
    }
    return strcmp(pa.user, pb.user) == 0 && strcmp(pa.host, pb.host) == 0 && strcmp(pa.dir, pb.dir) == 0;
}

void ft_path_destination(const FtProjectPath *p, char *out, size_t n) {
    if (!p || p->kind != FT_PATH_REMOTE) {
        ft_str_set(out, n, "");
        return;
    }
    if (p->user[0]) {
        snprintf(out, n, "%s@%s", p->user, p->host);
    } else {
        ft_str_set(out, n, p->host);
    }
}

void ft_path_display_name(const char *raw, char *out, size_t n) {
    FtProjectPath p;
    if (ft_path_parse(raw, &p) != 0) {
        ft_str_set(out, n, "project");
        return;
    }
    if (p.kind == FT_PATH_PINNED) {
        ft_str_set(out, n, "Pinned");
        return;
    }
    const char *dir = p.dir;
    const char *slash = strrchr(dir, '/');
    const char *base = slash && slash[1] ? slash + 1 : dir;
    if (strcmp(base, "~") == 0 || base[0] == 0) {
        if (p.kind == FT_PATH_REMOTE) {
            ft_str_set(out, n, p.host);
            return;
        }
        ft_str_set(out, n, "Home");
        return;
    }
    ft_str_set(out, n, base);
}
