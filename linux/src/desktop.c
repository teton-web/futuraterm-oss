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

int ft_desktop_vnc_argv(const char *host, const char **argv, int max) {
    if (!host || !host[0] || !argv || max < 2) {
        return -1;
    }
    argv[0] = host;
    argv[1] = NULL;
    return 1;
}

static void strip_trailing_dots(char *s) {
    size_t n = strlen(s);
    while (n > 0 && s[n - 1] == '.') {
        s[--n] = 0;
    }
}

static int host_eq_stripped(const char *a, const char *b) {
    char aa[256];
    char bb[256];
    if (!a || !b) {
        return 0;
    }
    snprintf(aa, sizeof(aa), "%s", a);
    snprintf(bb, sizeof(bb), "%s", b);
    strip_trailing_dots(aa);
    strip_trailing_dots(bb);
    return ft_str_ieq(aa, bb);
}

static int host_matches_name(const char *host, const char *candidate) {
    char cand[256];
    char *dot;
    if (host_eq_stripped(host, candidate)) {
        return 1;
    }
    snprintf(cand, sizeof(cand), "%s", candidate ? candidate : "");
    strip_trailing_dots(cand);
    dot = strchr(cand, '.');
    if (dot) {
        *dot = 0;
        if (ft_str_ieq(host, cand)) {
            return 1;
        }
    }
    return 0;
}

typedef struct {
    const char *host;
    int hit;
} FtDesktopIpHunt;

static int ip_matches_host(const char *elem, int len, void *user) {
    FtDesktopIpHunt *hunt = user;
    char ip[64];
    int n;
    if (!hunt || !elem || len < 2 || elem[0] != '"') {
        return 0;
    }
    n = len - 2;
    if (n >= (int)sizeof(ip)) {
        n = (int)sizeof(ip) - 1;
    }
    memcpy(ip, elem + 1, (size_t)n);
    ip[n] = 0;
    if (ft_str_ieq(ip, hunt->host)) {
        hunt->hit = 1;
        return 1;
    }
    return 0;
}

static int node_matches_host(const char *obj, const char *host) {
    char name[128];
    char dns[256];
    int ips_len = 0;
    const char *ips;
    FtDesktopIpHunt hunt = {host, 0};
    if (ft_json_str(obj, "HostName", name, sizeof(name)) == 0 && host_matches_name(host, name)) {
        return 1;
    }
    if (ft_json_str(obj, "DNSName", dns, sizeof(dns)) == 0 && host_matches_name(host, dns)) {
        return 1;
    }
    ips = ft_json_raw(obj, "TailscaleIPs", &ips_len);
    (void)ips_len;
    if (ips) {
        ft_json_array(ips, ip_matches_host, &hunt);
        if (hunt.hit) {
            return 1;
        }
    }
    return 0;
}

static int copy_os_if_match(const char *obj, int len, const char *host, char *out, size_t n) {
    char buf[16384];
    if (len < 2 || (size_t)len + 1 > sizeof(buf)) {
        return -1;
    }
    memcpy(buf, obj, (size_t)len);
    buf[len] = 0;
    if (!node_matches_host(buf, host)) {
        return -1;
    }
    return ft_json_str(buf, "OS", out, n);
}

static const char *skip_ws_local(const char *p) {
    while (p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) {
        p++;
    }
    return p;
}

static int object_span(const char *p, int *len) {
    int depth = 0;
    int in_str = 0;
    const char *q;
    p = skip_ws_local(p);
    if (!p || *p != '{') {
        return -1;
    }
    for (q = p; *q; q++) {
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
        if (*q == '{') {
            depth++;
        } else if (*q == '}') {
            depth--;
            if (depth == 0) {
                *len = (int)(q - p + 1);
                return 0;
            }
        }
    }
    return -1;
}

static int scan_peer_map(const char *peer, const char *host, char *out, size_t n) {
    const char *p = skip_ws_local(peer);
    if (!p || *p != '{') {
        return -1;
    }
    p++;
    while (*p) {
        int len = 0;
        p = skip_ws_local(p);
        if (*p == '}') {
            return -1;
        }
        if (*p == ',') {
            p++;
            continue;
        }
        if (*p != '"') {
            return -1;
        }
        p++;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) {
                p += 2;
            } else {
                p++;
            }
        }
        if (*p == '"') {
            p++;
        }
        p = skip_ws_local(p);
        if (*p != ':') {
            return -1;
        }
        p = skip_ws_local(p + 1);
        if (object_span(p, &len) != 0) {
            return -1;
        }
        if (copy_os_if_match(p, len, host, out, n) == 0) {
            return 0;
        }
        p += len;
    }
    return -1;
}

int ft_desktop_os_from_tailscale_json(const char *host, const char *json, char *out, size_t n) {
    int self_len = 0;
    int peer_len = 0;
    const char *self;
    const char *peer;
    if (!host || !host[0] || !json || !out || n == 0) {
        return -1;
    }
    out[0] = 0;
    self = ft_json_raw(json, "Self", &self_len);
    if (self && copy_os_if_match(self, self_len, host, out, n) == 0) {
        return 0;
    }
    peer = ft_json_raw(json, "Peer", &peer_len);
    if (peer && scan_peer_map(peer, host, out, n) == 0) {
        return 0;
    }
    return -1;
}
