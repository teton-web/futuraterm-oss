#include "session.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int ft_linux_pty_finished(ssize_t n, int err, int hung_up) {
    if (hung_up) {
        return 1;
    }
    if (n == 0) {
        return 1;
    }
    if (n < 0 && err != EAGAIN && err != EINTR) {
        return 1;
    }
    return 0;
}

static int is_slug_char(char c) {
    return isalnum((unsigned char)c) || c == '-' || c == '_';
}

int ft_linux_normalize_session(const char *requested, char *out, size_t n) {
    if (out == NULL || n < 8) {
        return -1;
    }
    const char *src = requested && requested[0] ? requested : "linux";
    if (strncmp(src, FT_LINUX_SESSION_PREFIX, strlen(FT_LINUX_SESSION_PREFIX)) == 0) {
        src += strlen(FT_LINUX_SESSION_PREFIX);
    }
    char slug[64];
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < sizeof(slug); i++) {
        char c = src[i];
        if (c == '/' || c == '.' || c == ' ') {
            c = '-';
        }
        if (!is_slug_char(c)) {
            continue;
        }
        slug[j++] = (char)tolower((unsigned char)c);
    }
    slug[j] = '\0';
    if (j == 0) {
        snprintf(slug, sizeof(slug), "linux");
    }
    int written = snprintf(out, n, "%s%s", FT_LINUX_SESSION_PREFIX, slug);
    if (written < 0 || (size_t)written >= n) {
        return -1;
    }
    return 0;
}

static int copy_if_executable(const char *path, char *out, size_t n) {
    if (path == NULL || path[0] == '\0') {
        return -1;
    }
    if (access(path, X_OK) != 0) {
        return -1;
    }
    if (strlen(path) + 1 > n) {
        return -1;
    }
    memcpy(out, path, strlen(path) + 1);
    return 0;
}

int ft_linux_find_zmx(char *out, size_t n) {
    if (out == NULL || n == 0) {
        return -1;
    }
    const char *env = getenv("ZMX");
    if (copy_if_executable(env, out, n) == 0) {
        return 0;
    }
    const char *home = getenv("HOME");
    char candidate[512];
    if (home && home[0]) {
        const char *suffixes[] = {
            "/bin/zmx",
            "/.local/bin/zmx",
            "/.cargo/bin/zmx",
            "/.local/share/mise/shims/zmx",
        };
        for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
            snprintf(candidate, sizeof(candidate), "%s%s", home, suffixes[i]);
            if (copy_if_executable(candidate, out, n) == 0) {
                return 0;
            }
        }
    }
    const char *absolute[] = {
        "/usr/local/bin/zmx",
        "/opt/homebrew/bin/zmx",
        "/usr/bin/zmx",
    };
    for (size_t i = 0; i < sizeof(absolute) / sizeof(absolute[0]); i++) {
        if (copy_if_executable(absolute[i], out, n) == 0) {
            return 0;
        }
    }
    return -1;
}

int ft_linux_make_pane_session(const char *project_slug, char *out, size_t n) {
    char slug[64];
    if (ft_linux_normalize_session(project_slug, slug, sizeof(slug)) != 0) {
        return -1;
    }
    unsigned char raw[6];
    FILE *ur = fopen("/dev/urandom", "rb");
    if (ur) {
        size_t got = fread(raw, 1, sizeof(raw), ur);
        fclose(ur);
        if (got != sizeof(raw)) {
            return -1;
        }
    } else {
        unsigned seed = (unsigned)getpid();
        for (size_t i = 0; i < sizeof(raw); i++) {
            seed = seed * 1103515245u + 12345u;
            raw[i] = (unsigned char)(seed >> 16);
        }
    }
    char hex[13];
    for (size_t i = 0; i < sizeof(raw); i++) {
        snprintf(hex + i * 2, 3, "%02x", raw[i]);
    }
    int written = snprintf(out, n, "%s-%s", slug, hex);
    if (written < 0 || (size_t)written >= n) {
        return -1;
    }
    return 0;
}

int ft_linux_zmx_attach_argv(
    const char *session,
    char *zmx_buf,
    size_t zmx_buf_n,
    const char **argv_out
) {
    if (session == NULL || session[0] == '\0' || argv_out == NULL) {
        return -1;
    }
    if (ft_linux_find_zmx(zmx_buf, zmx_buf_n) != 0) {
        return -1;
    }
    argv_out[0] = zmx_buf;
    argv_out[1] = "attach";
    argv_out[2] = session;
    argv_out[3] = NULL;
    return 0;
}
