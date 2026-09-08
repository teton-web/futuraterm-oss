#define _GNU_SOURCE
#include "util.h"

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void ft_str_set(char *dst, size_t n, const char *src) {
    if (!dst || n == 0) {
        return;
    }
    if (!src) {
        dst[0] = 0;
        return;
    }
    snprintf(dst, n, "%s", src);
}

int ft_str_eq(const char *a, const char *b) {
    if (!a || !b) {
        return a == b;
    }
    return strcmp(a, b) == 0;
}

int ft_str_ieq(const char *a, const char *b) {
    if (!a || !b) {
        return a == b;
    }
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) {
            return 0;
        }
        a++;
        b++;
    }
    return *a == *b;
}

void ft_uuid(char *out) {
    unsigned char raw[16];
    FILE *ur = fopen("/dev/urandom", "rb");
    if (ur) {
        size_t got = fread(raw, 1, sizeof(raw), ur);
        fclose(ur);
        if (got != sizeof(raw)) {
            memset(raw, 0, sizeof(raw));
        }
    } else {
        unsigned seed = (unsigned)getpid();
        for (size_t i = 0; i < sizeof(raw); i++) {
            seed = seed * 1103515245u + 12345u;
            raw[i] = (unsigned char)(seed >> 16);
        }
    }
    raw[6] = (unsigned char)((raw[6] & 0x0f) | 0x40);
    raw[8] = (unsigned char)((raw[8] & 0x3f) | 0x80);
    snprintf(
        out,
        37,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        raw[0],
        raw[1],
        raw[2],
        raw[3],
        raw[4],
        raw[5],
        raw[6],
        raw[7],
        raw[8],
        raw[9],
        raw[10],
        raw[11],
        raw[12],
        raw[13],
        raw[14],
        raw[15]
    );
}

int ft_mkdir_p(const char *path) {
    if (!path || !path[0]) {
        return -1;
    }
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t len = strlen(tmp);
    if (len == 0) {
        return -1;
    }
    if (tmp[len - 1] == '/') {
        tmp[len - 1] = 0;
    }
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                return -1;
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        return -1;
    }
    return 0;
}

int ft_read_file(const char *path, char *out, size_t n) {
    if (!path || !out || n == 0) {
        return -1;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        return -1;
    }
    size_t got = fread(out, 1, n - 1, f);
    fclose(f);
    out[got] = 0;
    return 0;
}

int ft_write_file(const char *path, const char *s) {
    if (!path || !s) {
        return -1;
    }
    FILE *f = fopen(path, "wb");
    if (!f) {
        return -1;
    }
    size_t n = strlen(s);
    size_t w = fwrite(s, 1, n, f);
    fclose(f);
    return w == n ? 0 : -1;
}

static const char *skip_ws(const char *p) {
    while (p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) {
        p++;
    }
    return p;
}

static const char *find_key(const char *json, const char *key) {
    if (!json || !key) {
        return NULL;
    }
    char pat[80];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = json;
    while ((p = strstr(p, pat)) != NULL) {
        const char *after = p + strlen(pat);
        after = skip_ws(after);
        if (*after == ':') {
            return skip_ws(after + 1);
        }
        p = after;
    }
    return NULL;
}

static int value_span(const char *p, int *len) {
    p = skip_ws(p);
    if (!p || !*p) {
        return -1;
    }
    if (*p == '"') {
        const char *q = p + 1;
        while (*q && *q != '"') {
            if (*q == '\\' && q[1]) {
                q += 2;
            } else {
                q++;
            }
        }
        if (*q != '"') {
            return -1;
        }
        *len = (int)(q - p + 1);
        return 0;
    }
    if (*p == '{' || *p == '[') {
        char open = *p;
        char close = open == '{' ? '}' : ']';
        int depth = 0;
        int in_str = 0;
        const char *q = p;
        for (; *q; q++) {
            if (in_str) {
                if (*q == '\\' && q[1]) {
                    q++;
                } else if (*q == '"') {
                    in_str = 0;
                }
                continue;
            }
            if (*q == '"') {
                in_str = 1;
                continue;
            }
            if (*q == open) {
                depth++;
            } else if (*q == close) {
                depth--;
                if (depth == 0) {
                    *len = (int)(q - p + 1);
                    return 0;
                }
            }
        }
        return -1;
    }
    const char *q = p;
    while (*q && *q != ',' && *q != '}' && *q != ']' && *q != ' ' && *q != '\n' && *q != '\r' && *q != '\t') {
        q++;
    }
    *len = (int)(q - p);
    return *len > 0 ? 0 : -1;
}

const char *ft_json_raw(const char *json, const char *key, int *len) {
    const char *p = find_key(json, key);
    if (!p) {
        return NULL;
    }
    int n = 0;
    if (value_span(p, &n) != 0) {
        return NULL;
    }
    if (len) {
        *len = n;
    }
    return p;
}

int ft_json_str(const char *json, const char *key, char *out, size_t n) {
    int len = 0;
    const char *p = ft_json_raw(json, key, &len);
    if (!p || !out || n == 0) {
        return -1;
    }
    if (*p != '"') {
        return -1;
    }
    p++;
    len -= 2;
    size_t i = 0;
    while (len > 0 && i + 1 < n) {
        if (*p == '\\' && len > 1) {
            p++;
            len--;
            if (*p == 'n') {
                out[i++] = '\n';
            } else if (*p == 't') {
                out[i++] = '\t';
            } else {
                out[i++] = *p;
            }
            p++;
            len--;
            continue;
        }
        out[i++] = *p++;
        len--;
    }
    out[i] = 0;
    return 0;
}

int ft_json_int(const char *json, const char *key, int *out) {
    int len = 0;
    const char *p = ft_json_raw(json, key, &len);
    if (!p || !out) {
        return -1;
    }
    *out = atoi(p);
    return 0;
}

int ft_json_bool(const char *json, const char *key, int *out) {
    int len = 0;
    const char *p = ft_json_raw(json, key, &len);
    if (!p || !out) {
        return -1;
    }
    if (strncmp(p, "true", 4) == 0) {
        *out = 1;
        return 0;
    }
    if (strncmp(p, "false", 5) == 0) {
        *out = 0;
        return 0;
    }
    return -1;
}

int ft_json_double(const char *json, const char *key, double *out) {
    int len = 0;
    const char *p = ft_json_raw(json, key, &len);
    if (!p || !out) {
        return -1;
    }
    *out = strtod(p, NULL);
    return 0;
}

void ft_json_esc(const char *s, char *out, size_t n) {
    if (!out || n == 0) {
        return;
    }
    size_t i = 0;
    for (; s && *s && i + 2 < n; s++) {
        if (*s == '"' || *s == '\\') {
            out[i++] = '\\';
            out[i++] = *s;
        } else if (*s == '\n') {
            if (i + 2 >= n) {
                break;
            }
            out[i++] = '\\';
            out[i++] = 'n';
        } else if (*s == '\r') {
            continue;
        } else {
            out[i++] = *s;
        }
    }
    out[i] = 0;
}

int ft_json_array(const char *json, int (*cb)(const char *elem, int len, void *user), void *user) {
    const char *p = skip_ws(json);
    if (!p || *p != '[') {
        return -1;
    }
    p++;
    while (*p) {
        p = skip_ws(p);
        if (*p == ']') {
            return 0;
        }
        int len = 0;
        if (value_span(p, &len) != 0) {
            return -1;
        }
        if (cb && cb(p, len, user) != 0) {
            return -1;
        }
        p += len;
        p = skip_ws(p);
        if (*p == ',') {
            p++;
        }
    }
    return -1;
}

void ft_xdg_data(char *out, size_t n) {
    const char *xdg = getenv("XDG_DATA_HOME");
    if (xdg && xdg[0]) {
        snprintf(out, n, "%s/futuraterm", xdg);
        return;
    }
    const char *home = getenv("HOME");
    snprintf(out, n, "%s/.local/share/futuraterm", home ? home : ".");
}

void ft_xdg_config(char *out, size_t n) {
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0]) {
        snprintf(out, n, "%s/futuraterm", xdg);
        return;
    }
    const char *home = getenv("HOME");
    snprintf(out, n, "%s/.config/futuraterm", home ? home : ".");
}

void ft_xdg_runtime(char *out, size_t n) {
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    if (xdg && xdg[0]) {
        snprintf(out, n, "%s", xdg);
        return;
    }
    snprintf(out, n, "/tmp");
}

int ft_is_shell_name(const char *comm) {
    static const char *shells[] = {
        "bash",
        "zsh",
        "fish",
        "sh",
        "dash",
        "ksh",
        "csh",
        "tcsh",
        "nu",
        "nushell",
        "elvish",
        "xonsh",
        "pwsh",
        "oksh",
        "ash",
        NULL
    };
    if (!comm || !comm[0]) {
        return 1;
    }
    const char *base = strrchr(comm, '/');
    base = base ? base + 1 : comm;
    if (base[0] == '-') {
        base++;
    }
    for (int i = 0; shells[i]; i++) {
        if (ft_str_ieq(base, shells[i])) {
            return 1;
        }
    }
    return 0;
}

void ft_buf_init(FtBuf *b, char *s, size_t n) {
    b->s = s;
    b->n = n;
    b->i = 0;
    if (s && n) {
        s[0] = 0;
    }
}

int ft_buf_printf(FtBuf *b, const char *fmt, ...) {
    if (!b || !b->s || b->i >= b->n) {
        return -1;
    }
    va_list ap;
    va_start(ap, fmt);
    int w = vsnprintf(b->s + b->i, b->n - b->i, fmt, ap);
    va_end(ap);
    if (w < 0) {
        return -1;
    }
    if ((size_t)w >= b->n - b->i) {
        b->i = b->n - 1;
        return -1;
    }
    b->i += (size_t)w;
    return 0;
}
