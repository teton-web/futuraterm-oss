#define _GNU_SOURCE
#include "split.h"

#include "util.h"

#include <stdlib.h>
#include <string.h>

FtNode *ft_node_pane(const char *session, const char *cwd) {
    FtNode *n = calloc(1, sizeof(*n));
    if (!n) {
        return NULL;
    }
    ft_uuid(n->pane_id);
    ft_str_set(n->session, sizeof(n->session), session ? session : "");
    ft_str_set(n->cwd, sizeof(n->cwd), cwd ? cwd : "");
    n->ratio = 0.5;
    return n;
}

FtNode *ft_node_split(int dir, FtNode *first, FtNode *second, double ratio) {
    FtNode *n = calloc(1, sizeof(*n));
    if (!n) {
        return NULL;
    }
    n->is_split = 1;
    n->dir = dir;
    n->ratio = ratio > 0 && ratio < 1 ? ratio : 0.5;
    n->first = first;
    n->second = second;
    return n;
}

void ft_node_free(FtNode *n) {
    if (!n) {
        return;
    }
    ft_node_free(n->first);
    ft_node_free(n->second);
    free(n);
}

FtNode *ft_node_clone(const FtNode *n) {
    if (!n) {
        return NULL;
    }
    FtNode *c = calloc(1, sizeof(*c));
    if (!c) {
        return NULL;
    }
    *c = *n;
    c->first = ft_node_clone(n->first);
    c->second = ft_node_clone(n->second);
    return c;
}

FtNode *ft_node_find(FtNode *n, const char *session) {
    if (!n || !session) {
        return NULL;
    }
    if (!n->is_split && strcmp(n->session, session) == 0) {
        return n;
    }
    FtNode *a = ft_node_find(n->first, session);
    return a ? a : ft_node_find(n->second, session);
}

int ft_node_collect(FtNode *n, FtNode **out, int max) {
    if (!n || !out || max <= 0) {
        return 0;
    }
    if (!n->is_split) {
        out[0] = n;
        return 1;
    }
    int a = ft_node_collect(n->first, out, max);
    int b = ft_node_collect(n->second, out + a, max - a);
    return a + b;
}

int ft_node_count(FtNode *n) {
    FtNode *tmp[128];
    return ft_node_collect(n, tmp, 128);
}

static int replace_child(FtNode **slot, const char *session, int dir, FtNode *fresh) {
    FtNode *n = *slot;
    if (!n) {
        return -1;
    }
    if (!n->is_split && strcmp(n->session, session) == 0) {
        *slot = ft_node_split(dir, n, fresh, 0.5);
        return 0;
    }
    if (n->is_split) {
        if (replace_child(&n->first, session, dir, fresh) == 0) {
            return 0;
        }
        return replace_child(&n->second, session, dir, fresh);
    }
    return -1;
}

int ft_node_split_at(FtNode **root, const char *session, int dir, FtNode *fresh) {
    if (!root || !*root || !fresh) {
        return -1;
    }
    return replace_child(root, session, dir, fresh);
}

static FtNode *close_rec(FtNode *n, const char *session, int *hit) {
    if (!n) {
        return NULL;
    }
    if (!n->is_split) {
        if (strcmp(n->session, session) == 0) {
            *hit = 1;
            free(n);
            return NULL;
        }
        return n;
    }
    n->first = close_rec(n->first, session, hit);
    n->second = close_rec(n->second, session, hit);
    if (!n->first && !n->second) {
        free(n);
        return NULL;
    }
    if (!n->first) {
        FtNode *keep = n->second;
        n->second = NULL;
        free(n);
        return keep;
    }
    if (!n->second) {
        FtNode *keep = n->first;
        n->first = NULL;
        free(n);
        return keep;
    }
    return n;
}

int ft_node_close(FtNode **root, const char *session) {
    if (!root || !*root) {
        return -1;
    }
    int hit = 0;
    *root = close_rec(*root, session, &hit);
    return hit ? 0 : -1;
}

static int opposite(int dir) {
    switch (dir) {
    case FT_DIR_LEFT:
        return FT_DIR_RIGHT;
    case FT_DIR_RIGHT:
        return FT_DIR_LEFT;
    case FT_DIR_UP:
        return FT_DIR_DOWN;
    default:
        return FT_DIR_UP;
    }
}

static int dir_matches_split(int want, int split_dir, int toward_second) {
    if (split_dir == FT_SPLIT_H) {
        if (want == FT_DIR_LEFT) {
            return !toward_second;
        }
        if (want == FT_DIR_RIGHT) {
            return toward_second;
        }
        return 0;
    }
    if (want == FT_DIR_UP) {
        return !toward_second;
    }
    if (want == FT_DIR_DOWN) {
        return toward_second;
    }
    return 0;
}

static const char *first_leaf(FtNode *n, int from_second) {
    if (!n) {
        return NULL;
    }
    if (!n->is_split) {
        return n->session;
    }
    const char *a = first_leaf(from_second ? n->second : n->first, 0);
    return a ? a : first_leaf(from_second ? n->first : n->second, 0);
}

static const char *neighbor_rec(FtNode *n, const char *session, int want, const char **found) {
    if (!n) {
        return NULL;
    }
    if (!n->is_split) {
        if (strcmp(n->session, session) == 0) {
            *found = n->session;
        }
        return NULL;
    }
    const char *hit = neighbor_rec(n->first, session, want, found);
    if (hit) {
        return hit;
    }
    if (*found && dir_matches_split(want, n->dir, 1)) {
        return first_leaf(n->second, 0);
    }
    const char *saved = *found;
    *found = NULL;
    hit = neighbor_rec(n->second, session, want, found);
    if (hit) {
        return hit;
    }
    if (*found && dir_matches_split(want, n->dir, 0)) {
        return first_leaf(n->first, 1);
    }
    if (!*found) {
        *found = saved;
    }
    return NULL;
}

const char *ft_node_neighbor(FtNode *root, const char *session, int want_dir) {
    const char *found = NULL;
    const char *n = neighbor_rec(root, session, want_dir, &found);
    (void)opposite;
    return n;
}

const char *ft_node_cycle(FtNode *root, const char *session, int delta) {
    FtNode *panes[128];
    int n = ft_node_collect(root, panes, 128);
    if (n == 0) {
        return NULL;
    }
    int idx = 0;
    for (int i = 0; i < n; i++) {
        if (session && strcmp(panes[i]->session, session) == 0) {
            idx = i;
            break;
        }
    }
    idx = (idx + delta) % n;
    if (idx < 0) {
        idx += n;
    }
    return panes[idx]->session;
}

static int resize_rec(FtNode *n, const char *session, int want, double delta, int *found) {
    if (!n) {
        return -1;
    }
    if (!n->is_split) {
        if (strcmp(n->session, session) == 0) {
            *found = 1;
        }
        return -1;
    }
    int before = *found;
    if (resize_rec(n->first, session, want, delta, found) == 0) {
        return 0;
    }
    if (*found && !before && dir_matches_split(want, n->dir, 1)) {
        n->ratio += delta;
        if (n->ratio < 0.15) {
            n->ratio = 0.15;
        }
        if (n->ratio > 0.85) {
            n->ratio = 0.85;
        }
        return 0;
    }
    before = *found;
    *found = 0;
    if (resize_rec(n->second, session, want, delta, found) == 0) {
        return 0;
    }
    if (*found && dir_matches_split(want, n->dir, 0)) {
        n->ratio -= delta;
        if (n->ratio < 0.15) {
            n->ratio = 0.15;
        }
        if (n->ratio > 0.85) {
            n->ratio = 0.85;
        }
        return 0;
    }
    if (!*found) {
        *found = before;
    }
    return -1;
}

int ft_node_resize(FtNode *root, const char *session, int want_dir, double delta) {
    int found = 0;
    return resize_rec(root, session, want_dir, delta, &found);
}

static int set_ratio_rec(FtNode *n, const char *session, int axis, double ratio, int *found) {
    if (!n) {
        return -1;
    }
    if (!n->is_split) {
        if (strcmp(n->session, session) == 0) {
            *found = 1;
        }
        return -1;
    }
    int before = *found;
    if (set_ratio_rec(n->first, session, axis, ratio, found) == 0) {
        return 0;
    }
    if (*found && !before && n->dir == axis) {
        n->ratio = ratio;
        return 0;
    }
    before = *found;
    *found = 0;
    if (set_ratio_rec(n->second, session, axis, ratio, found) == 0) {
        return 0;
    }
    if (*found && n->dir == axis) {
        n->ratio = ratio;
        return 0;
    }
    if (!*found) {
        *found = before;
    }
    return -1;
}

int ft_node_set_ratio(FtNode *root, const char *session, int axis, double ratio) {
    if (ratio < 0.15) {
        ratio = 0.15;
    }
    if (ratio > 0.85) {
        ratio = 0.85;
    }
    int found = 0;
    return set_ratio_rec(root, session, axis, ratio, &found);
}

static FtNode *detach_rec(FtNode **slot, const char *session, FtNode **taken) {
    FtNode *n = *slot;
    if (!n) {
        return NULL;
    }
    if (!n->is_split) {
        if (strcmp(n->session, session) == 0) {
            *taken = n;
            *slot = NULL;
            return n;
        }
        return NULL;
    }
    if (detach_rec(&n->first, session, taken)) {
        if (!n->first) {
            *slot = n->second;
            n->second = NULL;
            free(n);
        }
        return *taken;
    }
    if (detach_rec(&n->second, session, taken)) {
        if (!n->second) {
            *slot = n->first;
            n->first = NULL;
            free(n);
        }
        return *taken;
    }
    return NULL;
}

FtNode *ft_node_detach(FtNode **root, const char *session) {
    if (!root || !*root) {
        return NULL;
    }
    FtNode *taken = NULL;
    if (!(*root)->is_split && strcmp((*root)->session, session) == 0) {
        return NULL;
    }
    detach_rec(root, session, &taken);
    return taken;
}

int ft_node_detach_all(FtNode **root, FtNode **out, int max) {
    if (!root || !*root) {
        return 0;
    }
    FtNode *panes[128];
    int n = ft_node_collect(*root, panes, 128);
    int k = 0;
    for (int i = 0; i < n && k < max; i++) {
        FtNode *leaf = calloc(1, sizeof(*leaf));
        if (!leaf) {
            break;
        }
        *leaf = *panes[i];
        leaf->first = leaf->second = NULL;
        leaf->is_split = 0;
        out[k++] = leaf;
    }
    ft_node_free(*root);
    *root = NULL;
    return k;
}

int ft_node_grid(FtNode **root, const char *session, int rows, int cols, FtNode **created, int max_created) {
    if (!root || !*root || rows < 1 || cols < 1) {
        return -1;
    }
    if (rows == 1 && cols == 1) {
        return 0;
    }
    FtNode *origin = ft_node_find(*root, session);
    if (!origin) {
        return -1;
    }
    char cwd[512];
    ft_str_set(cwd, sizeof(cwd), origin->cwd);
    int made = 0;
    /* First expand columns on the origin row, then split each cell down. */
    FtNode *row_sessions[32];
    row_sessions[0] = origin;
    int ncol = 1;
    for (int c = 1; c < cols && c < 32; c++) {
        FtNode *fresh = ft_node_pane("", cwd);
        if (!fresh) {
            return -1;
        }
        if (ft_node_split_at(root, row_sessions[ncol - 1]->session[0] ? row_sessions[ncol - 1]->session : session, FT_SPLIT_H, fresh) != 0) {
            ft_node_free(fresh);
            return -1;
        }
        if (created && made < max_created) {
            created[made++] = fresh;
        }
        row_sessions[ncol++] = fresh;
    }
    /* After splits, re-collect the origin row as the first `cols` leaves from origin's containing split is hard;
     * instead split each known new pane downward. Origin is still the original session. */
    FtNode *tops[32];
    tops[0] = ft_node_find(*root, session);
    int nt = tops[0] ? 1 : 0;
    for (int i = 0; i < made && nt < 32; i++) {
        tops[nt++] = created[i];
    }
    int extra = made;
    for (int c = 0; c < nt; c++) {
        FtNode *cell = tops[c];
        if (!cell) {
            continue;
        }
        const char *cur = cell->session[0] ? cell->session : session;
        for (int r = 1; r < rows; r++) {
            FtNode *fresh = ft_node_pane("", cwd);
            if (!fresh) {
                return -1;
            }
            if (ft_node_split_at(root, cur, FT_SPLIT_V, fresh) != 0) {
                ft_node_free(fresh);
                return -1;
            }
            if (created && extra < max_created) {
                created[extra++] = fresh;
            }
            cur = fresh->session;
        }
    }
    return extra;
}
