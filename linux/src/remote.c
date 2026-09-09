#define _GNU_SOURCE
#include "remote.h"

#include "util.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

static void posix_dquote(const char *value, char *out, size_t n) {
    size_t i = 0;
    if (i + 1 < n) {
        out[i++] = '"';
    }
    for (; value && *value && i + 2 < n; value++) {
        char c = *value;
        if (c == '\\' || c == '"' || c == '$' || c == '`') {
            out[i++] = '\\';
        }
        out[i++] = c;
    }
    if (i + 1 < n) {
        out[i++] = '"';
    }
    out[i] = 0;
}

static int username_safe(const char *s) {
    if (!s || !s[0]) {
        return 1;
    }
    for (; *s; s++) {
        if (!isalnum((unsigned char)*s) && *s != '.' && *s != '_' && *s != '-') {
            return 0;
        }
    }
    return 1;
}

static void quote_dir(const char *directory, char *out, size_t n) {
    if (!directory || directory[0] != '~') {
        posix_dquote(directory ? directory : "", out, n);
        return;
    }
    const char *slash = strchr(directory + 1, '/');
    char user[128];
    size_t ulen = slash ? (size_t)(slash - (directory + 1)) : strlen(directory + 1);
    if (ulen >= sizeof(user)) {
        posix_dquote(directory, out, n);
        return;
    }
    memcpy(user, directory + 1, ulen);
    user[ulen] = 0;
    if (!username_safe(user)) {
        posix_dquote(directory, out, n);
        return;
    }
    if (!slash) {
        snprintf(out, n, "%s", directory);
        return;
    }
    char rest[512];
    posix_dquote(slash, rest, sizeof(rest));
    snprintf(out, n, "%.*s%s", (int)(slash - directory), directory, rest);
}

static void shell_quote(const char *value, char *out, size_t n) {
    size_t i = 0;
    if (i + 1 < n) {
        out[i++] = '\'';
    }
    for (; value && *value && i + 4 < n; value++) {
        if (*value == '\'') {
            out[i++] = '\'';
            out[i++] = '\\';
            out[i++] = '\'';
            out[i++] = '\'';
        } else {
            out[i++] = *value;
        }
    }
    if (i + 1 < n) {
        out[i++] = '\'';
    }
    out[i] = 0;
}

int ft_remote_script(
    const FtProjectPath *remote,
    const char *session,
    const char *zmx_path,
    char *out,
    size_t n
) {
    if (!remote || remote->kind != FT_PATH_REMOTE || !out || n < 32) {
        return -1;
    }
    char qdir[640];
    char qsess[200];
    quote_dir(remote->dir, qdir, sizeof(qdir));
    posix_dquote(session ? session : "", qsess, sizeof(qsess));
    char zmx[300];
    int path_mode = !(zmx_path && zmx_path[0]);
    if (path_mode) {
        snprintf(zmx, sizeof(zmx), "zmx");
    } else {
        posix_dquote(zmx_path, zmx, sizeof(zmx));
    }
    FtBuf b;
    ft_buf_init(&b, out, n);
    ft_buf_printf(&b, "%s%s%s", FT_REMOTE_ENV_PREAMBLE, FT_REMOTE_TERM_PREAMBLE, FT_REMOTE_COLOR_PREAMBLE);
    if (path_mode) {
        ft_buf_printf(
            &b,
            "command -v zmx >/dev/null 2>&1 || "
            "{ echo \"futuraterm: zmx not found in PATH on this host ($PATH)\" >&2; exec ${SHELL:-/bin/sh}; }; "
        );
    }
    ft_buf_printf(
        &b,
        "cd %s || { echo \"futuraterm: cannot cd to %s\" >&2; exec ${SHELL:-/bin/sh}; }; "
        "exec %s attach %s",
        qdir,
        qdir,
        zmx,
        qsess
    );
    if (strchr(out, '\'')) {
        snprintf(
            out,
            n,
            "%secho \"futuraterm: remote path contains an unsupported single quote\" >&2; exec ${SHELL:-/bin/sh}",
            FT_REMOTE_ENV_PREAMBLE
        );
    }
    return 0;
}

int ft_remote_pane_command(
    const FtProjectPath *remote,
    const char *session,
    const char *zmx_path,
    char *out,
    size_t n
) {
    char script[4096];
    char dest[192];
    char qdest[256];
    char qcmd[4608];
    char inner[4300];
    if (ft_remote_script(remote, session, zmx_path, script, sizeof(script)) != 0) {
        return -1;
    }
    ft_path_destination(remote, dest, sizeof(dest));
    shell_quote(dest, qdest, sizeof(qdest));
    snprintf(inner, sizeof(inner), "sh -c %s", ""); /* filled below */
    char qscript[4200];
    shell_quote(script, qscript, sizeof(qscript));
    snprintf(inner, sizeof(inner), "sh -c %s", qscript);
    shell_quote(inner, qcmd, sizeof(qcmd));
    snprintf(out, n, "ssh -t %s %s", qdest, qcmd);
    return 0;
}

int ft_remote_pane_argv(
    const FtProjectPath *remote,
    const char *session,
    const char *zmx_path,
    char *dest_buf,
    size_t dest_n,
    char *wrap_buf,
    size_t wrap_n,
    const char **argv_out
) {
    char script[4096];
    char qscript[4200];
    if (ft_remote_script(remote, session, zmx_path, script, sizeof(script)) != 0 || !argv_out) {
        return -1;
    }
    ft_path_destination(remote, dest_buf, dest_n);
    shell_quote(script, qscript, sizeof(qscript));
    snprintf(wrap_buf, wrap_n, "sh -c %s", qscript);
    argv_out[0] = "ssh";
    argv_out[1] = "-t";
    argv_out[2] = dest_buf;
    argv_out[3] = wrap_buf;
    argv_out[4] = NULL;
    return 0;
}

static int named_key(const char *tok, char *out, size_t n) {
    if (ft_str_ieq(tok, "escape") || ft_str_ieq(tok, "esc")) {
        ft_str_set(out, n, "\x1b");
        return 0;
    }
    if (ft_str_ieq(tok, "enter") || ft_str_ieq(tok, "return")) {
        ft_str_set(out, n, "\r");
        return 0;
    }
    if (ft_str_ieq(tok, "tab")) {
        ft_str_set(out, n, "\t");
        return 0;
    }
    if (ft_str_ieq(tok, "backspace")) {
        ft_str_set(out, n, "\x7f");
        return 0;
    }
    if (ft_str_ieq(tok, "space")) {
        ft_str_set(out, n, " ");
        return 0;
    }
    if (ft_str_ieq(tok, "up")) {
        ft_str_set(out, n, "\x1b[A");
        return 0;
    }
    if (ft_str_ieq(tok, "down")) {
        ft_str_set(out, n, "\x1b[B");
        return 0;
    }
    if (ft_str_ieq(tok, "right")) {
        ft_str_set(out, n, "\x1b[C");
        return 0;
    }
    if (ft_str_ieq(tok, "left")) {
        ft_str_set(out, n, "\x1b[D");
        return 0;
    }
    if (ft_str_ieq(tok, "home")) {
        ft_str_set(out, n, "\x1b[H");
        return 0;
    }
    if (ft_str_ieq(tok, "end")) {
        ft_str_set(out, n, "\x1b[F");
        return 0;
    }
    if (ft_str_ieq(tok, "delete") || ft_str_ieq(tok, "del")) {
        ft_str_set(out, n, "\x1b[3~");
        return 0;
    }
    return -1;
}

int ft_remote_should_reattach(int is_remote, int process_exited) {
    return is_remote && process_exited;
}

int ft_key_chord_bytes(const char *chord, char *out, size_t n) {
    if (!chord || !out || n < 2) {
        return -1;
    }
    out[0] = 0;
    int ctrl = 0, shift = 0, alt = 0;
    char tok[32];
    tok[0] = 0;
    const char *p = chord;
    while (*p) {
        const char *plus = strchr(p, '+');
        size_t len = plus ? (size_t)(plus - p) : strlen(p);
        char part[32];
        if (len >= sizeof(part)) {
            return -1;
        }
        memcpy(part, p, len);
        part[len] = 0;
        if (ft_str_ieq(part, "ctrl") || ft_str_ieq(part, "control")) {
            ctrl = 1;
        } else if (ft_str_ieq(part, "shift")) {
            shift = 1;
        } else if (ft_str_ieq(part, "alt") || ft_str_ieq(part, "opt") || ft_str_ieq(part, "option")) {
            alt = 1;
        } else if (ft_str_ieq(part, "cmd") || ft_str_ieq(part, "super") || ft_str_ieq(part, "meta")) {
            /* treated as alt for encoding purposes on Linux */
            alt = 1;
        } else {
            ft_str_set(tok, sizeof(tok), part);
        }
        if (!plus) {
            break;
        }
        p = plus + 1;
    }
    (void)shift;
    if (!tok[0]) {
        return -1;
    }
    if (named_key(tok, out, n) == 0) {
        if (alt && out[0] != '\x1b') {
            char tmp[16];
            snprintf(tmp, sizeof(tmp), "\x1b%s", out);
            ft_str_set(out, n, tmp);
        }
        return 0;
    }
    if (ctrl) {
        unsigned char c = (unsigned char)tolower((unsigned char)tok[0]);
        if ((c >= 'a' && c <= 'z') || (c >= '@' && c <= '_')) {
            out[0] = (char)(c & 0x1f);
            out[1] = 0;
            return 0;
        }
        if (tok[0] == '\\') {
            out[0] = 0x1c;
            out[1] = 0;
            return 0;
        }
    }
    if (strlen(tok) == 1) {
        out[0] = tok[0];
        out[1] = 0;
        return 0;
    }
    return -1;
}
