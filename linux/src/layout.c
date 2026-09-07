#define _GNU_SOURCE
#include "layout.h"

#include "path.h"
#include "util.h"

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

void ft_layout_free(FtLayoutFile *f) {
    if (!f) {
        return;
    }
    for (int i = 0; i < f->ntabs; i++) {
        ft_node_free(f->tabs[i]);
        f->tabs[i] = NULL;
        f->tab_names[i][0] = 0;
    }
    f->ntabs = 0;
}

typedef struct {
    int indent;
    int list;
    char text[1024];
} YLine;

static int split_lines(const char *yaml, YLine *lines, int max) {
    int n = 0;
    const char *p = yaml;
    while (*p && n < max) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char buf[1024];
        if (len >= sizeof(buf)) {
            len = sizeof(buf) - 1;
        }
        memcpy(buf, p, len);
        buf[len] = 0;
        if (len && buf[len - 1] == '\r') {
            buf[--len] = 0;
        }
        int indent = 0;
        char *s = buf;
        while (*s == ' ') {
            indent++;
            s++;
        }
        if (*s == '#' || *s == 0) {
            p = nl ? nl + 1 : p + len;
            continue;
        }
        /* strip unquoted comment */
        char *hash = strchr(s, '#');
        if (hash && (hash == s || hash[-1] == ' ')) {
            *hash = 0;
        }
        while (s[0] && (s[strlen(s) - 1] == ' ' || s[strlen(s) - 1] == '\t')) {
            s[strlen(s) - 1] = 0;
        }
        if (!s[0]) {
            p = nl ? nl + 1 : p + len;
            continue;
        }
        lines[n].indent = indent;
        lines[n].list = 0;
        if (s[0] == '-' && (s[1] == ' ' || s[1] == '\0')) {
            lines[n].list = 1;
            s += 1;
            if (*s == ' ') {
                s++;
            }
            lines[n].indent = indent + 2;
        }
        snprintf(lines[n].text, sizeof(lines[n].text), "%s", s);
        n++;
        p = nl ? nl + 1 : p + len;
        if (!nl) {
            break;
        }
    }
    return n;
}

static void unquote(char *s) {
    size_t n = strlen(s);
    if (n >= 2 && ((s[0] == '"' && s[n - 1] == '"') || (s[0] == '\'' && s[n - 1] == '\''))) {
        s[n - 1] = 0;
        memmove(s, s + 1, n - 1);
    }
}

static FtNode *parse_node(YLine *lines, int n, int *i, int indent);

static FtNode *parse_split_body(YLine *lines, int n, int *i, int indent) {
    char dir[32] = "horizontal";
    char ratio[32] = "0.5";
    FtNode *first = NULL;
    FtNode *second = NULL;
    while (*i < n && lines[*i].indent >= indent) {
        if (lines[*i].indent < indent) {
            break;
        }
        if (lines[*i].list && lines[*i].indent == indent) {
            break;
        }
        YLine *ln = &lines[*i];
        if (ln->indent > indent && !first && !second) {
            /* still in body */
        }
        if (ln->indent < indent) {
            break;
        }
        char *colon = strchr(ln->text, ':');
        if (!colon) {
            (*i)++;
            continue;
        }
        char k[32];
        size_t kl = (size_t)(colon - ln->text);
        if (kl >= sizeof(k)) {
            (*i)++;
            continue;
        }
        memcpy(k, ln->text, kl);
        k[kl] = 0;
        while (k[0] && k[strlen(k) - 1] == ' ') {
            k[strlen(k) - 1] = 0;
        }
        char *rest = colon + 1;
        while (*rest == ' ') {
            rest++;
        }
        if (strcmp(k, "direction") == 0) {
            unquote(rest);
            ft_str_set(dir, sizeof(dir), rest);
            (*i)++;
        } else if (strcmp(k, "ratio") == 0) {
            ft_str_set(ratio, sizeof(ratio), rest);
            (*i)++;
        } else if (strcmp(k, "first") == 0 || strcmp(k, "second") == 0) {
            int is_first = strcmp(k, "first") == 0;
            (*i)++;
            if (strcmp(rest, "{}") == 0) {
                FtNode *leaf = ft_node_pane("", "");
                if (is_first) {
                    first = leaf;
                } else {
                    second = leaf;
                }
            } else {
                int child_indent = *i < n ? lines[*i].indent : indent + 2;
                FtNode *child = parse_node(lines, n, i, child_indent);
                if (is_first) {
                    first = child;
                } else {
                    second = child;
                }
            }
        } else {
            (*i)++;
        }
    }
    if (!first) {
        first = ft_node_pane("", "");
    }
    if (!second) {
        second = ft_node_pane("", "");
    }
    int d = (strcmp(dir, "vertical") == 0) ? FT_SPLIT_V : FT_SPLIT_H;
    return ft_node_split(d, first, second, strtod(ratio, NULL));
}

static FtNode *parse_node(YLine *lines, int n, int *i, int indent) {
    FtNode *pane = ft_node_pane("", "");
    int saw_split = 0;
    FtNode *split = NULL;
    int first = 1;
    while (*i < n && lines[*i].indent >= indent) {
        YLine *ln = &lines[*i];
        if (!first && ln->indent < indent) {
            break;
        }
        if (!first && ln->list && ln->indent <= indent) {
            break;
        }
        first = 0;
        char *colon = strchr(ln->text, ':');
        if (!colon) {
            (*i)++;
            continue;
        }
        char k[32];
        size_t kl = (size_t)(colon - ln->text);
        if (kl >= sizeof(k)) {
            (*i)++;
            continue;
        }
        memcpy(k, ln->text, kl);
        k[kl] = 0;
        while (k[0] && k[strlen(k) - 1] == ' ') {
            k[strlen(k) - 1] = 0;
        }
        char *rest = colon + 1;
        while (*rest == ' ') {
            rest++;
        }
        unquote(rest);
        if (strcmp(k, "cwd") == 0) {
            ft_str_set(pane->cwd, sizeof(pane->cwd), rest);
            (*i)++;
        } else if (strcmp(k, "run") == 0) {
            ft_str_set(pane->run, sizeof(pane->run), rest);
            (*i)++;
        } else if (strcmp(k, "shell") == 0) {
            ft_str_set(pane->shell, sizeof(pane->shell), rest);
            (*i)++;
        } else if (strcmp(k, "name") == 0) {
            (*i)++; /* tab name handled by caller */
        } else if (strcmp(k, "split") == 0) {
            (*i)++;
            int body_indent = *i < n ? lines[*i].indent : indent + 2;
            split = parse_split_body(lines, n, i, body_indent);
            saw_split = 1;
        } else {
            (*i)++;
        }
        if (*i < n && lines[*i].list && lines[*i].indent <= indent) {
            break;
        }
    }
    if (saw_split && split) {
        ft_node_free(pane);
        return split;
    }
    return pane;
}

static int parse_tab(YLine *lines, int n, int *i, FtLayoutFile *out) {
    if (out->ntabs >= FT_LAYOUT_MAX_TABS) {
        return -1;
    }
    int indent = lines[*i].indent;
    char name[64] = "";
    /* peek name on this or nested lines */
    int j = *i;
    int start = *i;
    if (lines[start].list && strncmp(lines[start].text, "name:", 5) == 0) {
        char *v = lines[start].text + 5;
        while (*v == ' ') {
            v++;
        }
        unquote(v);
        ft_str_set(name, sizeof(name), v);
    }
    FtNode *node = parse_node(lines, n, i, indent);
    /* If parse_node skipped name, collect from the block. */
    for (int k = start; k < *i && k < n; k++) {
        if (strncmp(lines[k].text, "name:", 5) == 0 && !name[0]) {
            char *v = lines[k].text + 5;
            while (*v == ' ') {
                v++;
            }
            char tmp[64];
            snprintf(tmp, sizeof(tmp), "%s", v);
            unquote(tmp);
            ft_str_set(name, sizeof(name), tmp);
        }
    }
    (void)j;
    int idx = out->ntabs;
    out->tabs[idx] = node ? node : ft_node_pane("", "");
    ft_str_set(out->tab_names[idx], sizeof(out->tab_names[0]), name);
    out->ntabs++;
    return 0;
}

int ft_layout_parse(const char *yaml, FtLayoutFile *out) {
    if (!out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    if (!yaml) {
        return -1;
    }
    YLine lines[512];
    int n = split_lines(yaml, lines, 512);
    int i = 0;
    while (i < n) {
        if (lines[i].indent == 0 && !lines[i].list) {
            char *colon = strchr(lines[i].text, ':');
            if (colon) {
                char k[32];
                size_t kl = (size_t)(colon - lines[i].text);
                if (kl < sizeof(k)) {
                    memcpy(k, lines[i].text, kl);
                    k[kl] = 0;
                    char *v = colon + 1;
                    while (*v == ' ') {
                        v++;
                    }
                    unquote(v);
                    if (strcmp(k, "name") == 0) {
                        ft_str_set(out->name, sizeof(out->name), v);
                        i++;
                        continue;
                    }
                    if (strcmp(k, "path") == 0) {
                        ft_str_set(out->path, sizeof(out->path), v);
                        i++;
                        continue;
                    }
                    if (strcmp(k, "zmxPath") == 0) {
                        ft_str_set(out->zmx_path, sizeof(out->zmx_path), v);
                        i++;
                        continue;
                    }
                    if (strcmp(k, "tabs") == 0) {
                        i++;
                        while (i < n && (lines[i].list || lines[i].indent > 0)) {
                            if (!lines[i].list && lines[i].indent == 0) {
                                break;
                            }
                            if (lines[i].list) {
                                if (parse_tab(lines, n, &i, out) != 0) {
                                    return -1;
                                }
                            } else {
                                i++;
                            }
                        }
                        continue;
                    }
                }
            }
        }
        i++;
    }
    if (!out->path[0]) {
        ft_layout_free(out);
        return -1;
    }
    return 0;
}

static void pad_n(char *pad, int indent) {
    if (indent < 0) {
        indent = 0;
    }
    if (indent > 62) {
        indent = 62;
    }
    memset(pad, ' ', (size_t)indent);
    pad[indent] = 0;
}

static int pane_empty(const FtNode *n) {
    return !n || (!n->is_split && !n->cwd[0] && !n->run[0] && !n->shell[0]);
}

static int emit_fields(const FtNode *n, int indent, FtBuf *b) {
    char pad[64];
    pad_n(pad, indent);
    if (n->cwd[0]) {
        ft_buf_printf(b, "%scwd: %s\n", pad, n->cwd);
    }
    if (n->run[0]) {
        ft_buf_printf(b, "%srun: \"%s\"\n", pad, n->run);
    }
    if (n->shell[0]) {
        ft_buf_printf(b, "%sshell: %s\n", pad, n->shell);
    }
    return 0;
}

static int emit_node_block(const FtNode *n, int indent, FtBuf *b) {
    char pad[64];
    pad_n(pad, indent);
    if (pane_empty(n)) {
        return 0;
    }
    if (!n->is_split) {
        return emit_fields(n, indent, b);
    }
    ft_buf_printf(b, "%ssplit:\n", pad);
    ft_buf_printf(b, "%s  direction: %s\n", pad, n->dir == FT_SPLIT_V ? "vertical" : "horizontal");
    ft_buf_printf(b, "%s  ratio: %.2f\n", pad, n->ratio <= 0 ? 0.5 : n->ratio);
    if (pane_empty(n->first)) {
        ft_buf_printf(b, "%s  first: {}\n", pad);
    } else {
        ft_buf_printf(b, "%s  first:\n", pad);
        emit_node_block(n->first, indent + 4, b);
    }
    if (pane_empty(n->second)) {
        ft_buf_printf(b, "%s  second: {}\n", pad);
    } else {
        ft_buf_printf(b, "%s  second:\n", pad);
        emit_node_block(n->second, indent + 4, b);
    }
    return 0;
}

int ft_layout_emit(const FtLayoutFile *f, char *out, size_t n) {
    FtBuf b;
    ft_buf_init(&b, out, n);
    ft_buf_printf(&b, "# yaml-language-server: $schema=https://futuraterm.com/schema/project.json\n");
    if (f->name[0]) {
        ft_buf_printf(&b, "name: %s\n", f->name);
    }
    ft_buf_printf(&b, "path: %s\n", f->path);
    if (f->zmx_path[0]) {
        ft_buf_printf(&b, "zmxPath: %s\n", f->zmx_path);
    }
    if (f->ntabs == 0) {
        return 0;
    }
    ft_buf_printf(&b, "tabs:\n");
    for (int i = 0; i < f->ntabs; i++) {
        if (f->tab_names[i][0]) {
            ft_buf_printf(&b, "- name: %s\n", f->tab_names[i]);
            emit_node_block(f->tabs[i], 2, &b);
        } else if (pane_empty(f->tabs[i])) {
            ft_buf_printf(&b, "- {}\n");
        } else if (f->tabs[i] && !f->tabs[i]->is_split) {
            ft_buf_printf(&b, "- ");
            int wrote = 0;
            if (f->tabs[i]->cwd[0]) {
                ft_buf_printf(&b, "cwd: %s\n", f->tabs[i]->cwd);
                wrote = 1;
            }
            if (f->tabs[i]->run[0]) {
                ft_buf_printf(&b, wrote ? "  run: \"%s\"\n" : "run: \"%s\"\n", f->tabs[i]->run);
                wrote = 1;
            }
            if (f->tabs[i]->shell[0]) {
                ft_buf_printf(&b, wrote ? "  shell: %s\n" : "shell: %s\n", f->tabs[i]->shell);
            }
        } else {
            ft_buf_printf(&b, "- split:\n");
            ft_buf_printf(
                &b,
                "    direction: %s\n    ratio: %.2f\n",
                f->tabs[i]->dir == FT_SPLIT_V ? "vertical" : "horizontal",
                f->tabs[i]->ratio <= 0 ? 0.5 : f->tabs[i]->ratio
            );
            if (pane_empty(f->tabs[i]->first)) {
                ft_buf_printf(&b, "    first: {}\n");
            } else {
                ft_buf_printf(&b, "    first:\n");
                emit_node_block(f->tabs[i]->first, 6, &b);
            }
            if (pane_empty(f->tabs[i]->second)) {
                ft_buf_printf(&b, "    second: {}\n");
            } else {
                ft_buf_printf(&b, "    second:\n");
                emit_node_block(f->tabs[i]->second, 6, &b);
            }
        }
    }
    return 0;
}

int ft_layout_from_tree(
    const char *name,
    const char *path,
    FtNode **tab_roots,
    const char **tab_names,
    int ntabs,
    FtLayoutFile *out
) {
    memset(out, 0, sizeof(*out));
    ft_str_set(out->name, sizeof(out->name), name ? name : "");
    ft_str_set(out->path, sizeof(out->path), path ? path : "");
    for (int i = 0; i < ntabs && i < FT_LAYOUT_MAX_TABS; i++) {
        out->tabs[i] = ft_node_clone(tab_roots[i]);
        if (tab_names && tab_names[i]) {
            ft_str_set(out->tab_names[i], sizeof(out->tab_names[0]), tab_names[i]);
        }
        out->ntabs++;
    }
    return 0;
}

int ft_layout_slug(const char *name, char *out, size_t n) {
    size_t j = 0;
    for (size_t i = 0; name && name[i] && j + 1 < n; i++) {
        unsigned char c = (unsigned char)name[i];
        if (isspace(c)) {
            out[j++] = '_';
        } else if (isalnum(c) || c == '-' || c == '_') {
            out[j++] = (char)tolower(c);
        }
    }
    out[j] = 0;
    if (j == 0) {
        ft_str_set(out, n, "project");
    }
    return 0;
}

int ft_layout_write_dir(const FtLayoutFile *f, const char *dir, char *written_path, size_t n) {
    if (ft_mkdir_p(dir) != 0) {
        return -1;
    }
    char slug[80];
    ft_layout_slug(f->name[0] ? f->name : f->path, slug, sizeof(slug));
    char path[768];
    snprintf(path, sizeof(path), "%s/%s.yaml", dir, slug);
    char yaml[16384];
    if (ft_layout_emit(f, yaml, sizeof(yaml)) != 0) {
        return -1;
    }
    if (ft_write_file(path, yaml) != 0) {
        return -1;
    }
    if (written_path) {
        ft_str_set(written_path, n, path);
    }
    return 0;
}

int ft_layout_load_path(const char *path, FtLayoutFile *out) {
    char buf[32768];
    if (ft_read_file(path, buf, sizeof(buf)) != 0) {
        return -1;
    }
    return ft_layout_parse(buf, out);
}

int ft_layout_find_for_project(const char *dir, const char *project_path, const char *name, char *found, size_t n) {
    DIR *d = opendir(dir ? dir : "");
    if (!d) {
        return -1;
    }
    char slug[80];
    ft_layout_slug(name ? name : "", slug, sizeof(slug));
    char first_match[768] = "";
    char owned[768] = "";
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        size_t len = strlen(ent->d_name);
        if (len < 6 || strcmp(ent->d_name + len - 5, ".yaml") != 0) {
            continue;
        }
        char path[768];
        snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
        char buf[8192];
        if (ft_read_file(path, buf, sizeof(buf)) != 0) {
            continue;
        }
        /* header-only: look for path: */
        char pth[512];
        const char *line = buf;
        pth[0] = 0;
        while (*line) {
            const char *nl = strchr(line, '\n');
            char tmp[1024];
            size_t ll = nl ? (size_t)(nl - line) : strlen(line);
            if (ll >= sizeof(tmp)) {
                ll = sizeof(tmp) - 1;
            }
            memcpy(tmp, line, ll);
            tmp[ll] = 0;
            char *s = tmp;
            while (*s == ' ') {
                s++;
            }
            if (strncmp(s, "path:", 5) == 0) {
                s += 5;
                while (*s == ' ') {
                    s++;
                }
                unquote(s);
                ft_str_set(pth, sizeof(pth), s);
                break;
            }
            if (!nl) {
                break;
            }
            line = nl + 1;
        }
        if (!pth[0] || !ft_path_matches(pth, project_path)) {
            continue;
        }
        if (!first_match[0]) {
            ft_str_set(first_match, sizeof(first_match), path);
        }
        char base[80];
        snprintf(base, sizeof(base), "%s", ent->d_name);
        base[len - 5] = 0;
        if (strcmp(base, slug) == 0) {
            ft_str_set(owned, sizeof(owned), path);
        }
    }
    closedir(d);
    const char *pick = owned[0] ? owned : first_match;
    if (!pick[0]) {
        return -1;
    }
    ft_str_set(found, n, pick);
    return 0;
}
