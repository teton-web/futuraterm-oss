#define _GNU_SOURCE
#include "model.h"

#include "path.h"
#include "session.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void set_err(FtModel *m, const char *s) {
    ft_str_set(m->error, sizeof(m->error), s ? s : "");
}

static void tab_clear(FtTabRec *t) {
    ft_node_free(t->root);
    ft_node_free(t->declaration);
    memset(t, 0, sizeof(*t));
}

static void project_clear(FtProjectRec *p) {
    for (int i = 0; i < p->ntabs; i++) {
        tab_clear(&p->tabs[i]);
    }
    memset(p, 0, sizeof(*p));
}

static void init_pinned(FtModel *m) {
    memset(&m->pinned, 0, sizeof(m->pinned));
    ft_str_set(m->pinned.id, sizeof(m->pinned.id), FT_PINNED_ID);
    ft_str_set(m->pinned.name, sizeof(m->pinned.name), "Pinned");
    ft_str_set(m->pinned.path, sizeof(m->pinned.path), FT_PINNED_PATH_MARKER);
}

FtModel *ft_model_new(const char *data_dir, const char *config_dir) {
    FtModel *m = calloc(1, sizeof(*m));
    if (!m) {
        return NULL;
    }
    ft_str_set(m->data_dir, sizeof(m->data_dir), data_dir ? data_dir : ".");
    ft_str_set(m->config_dir, sizeof(m->config_dir), config_dir ? config_dir : ".");
    m->active = -1;
    init_pinned(m);
    return m;
}

void ft_model_free(FtModel *m) {
    if (!m) {
        return;
    }
    for (int i = 0; i < m->nprojects; i++) {
        project_clear(&m->projects[i]);
    }
    project_clear(&m->pinned);
    free(m);
}

void ft_model_fill_sessions(FtModel *m, FtNode *n, const char *project_name, const char *cwd) {
    (void)m;
    if (!n) {
        return;
    }
    if (n->is_split) {
        ft_model_fill_sessions(m, n->first, project_name, cwd);
        ft_model_fill_sessions(m, n->second, project_name, cwd);
        return;
    }
    if (!n->session[0]) {
        ft_linux_make_pane_session(project_name ? project_name : "linux", n->session, sizeof(n->session));
    }
    if (!n->cwd[0] && cwd) {
        ft_str_set(n->cwd, sizeof(n->cwd), cwd);
    }
    if (!n->pane_id[0]) {
        ft_uuid(n->pane_id);
    }
}

static int add_empty_tab(FtModel *m, FtProjectRec *p, const char *title, const char *run) {
    if (p->ntabs >= FT_MAX_TABS) {
        set_err(m, "too many tabs");
        return -1;
    }
    FtTabRec *t = &p->tabs[p->ntabs];
    memset(t, 0, sizeof(*t));
    ft_uuid(t->id);
    snprintf(t->title, sizeof(t->title), "%s", title ? title : "Tab");
    t->root = ft_node_pane("", p->path);
    if (run && run[0]) {
        ft_str_set(t->root->run, sizeof(t->root->run), run);
    }
    ft_model_fill_sessions(m, t->root, p->name, p->path);
    ft_str_set(t->focus, sizeof(t->focus), t->root->session);
    p->active_tab = p->ntabs;
    p->ntabs++;
    p->unloaded = 0;
    return p->active_tab;
}

FtProjectRec *ft_model_active(FtModel *m) {
    if (!m) {
        return NULL;
    }
    if (m->active == -2) {
        return &m->pinned;
    }
    if (m->active < 0 || m->active >= m->nprojects) {
        return NULL;
    }
    return &m->projects[m->active];
}

FtTabRec *ft_model_active_tab(FtModel *m) {
    FtProjectRec *p = ft_model_active(m);
    if (!p || p->ntabs == 0) {
        return NULL;
    }
    if (p->active_tab < 0 || p->active_tab >= p->ntabs) {
        p->active_tab = 0;
    }
    return &p->tabs[p->active_tab];
}

FtNode *ft_model_focused_pane(FtModel *m) {
    FtTabRec *t = ft_model_active_tab(m);
    if (!t || !t->root) {
        return NULL;
    }
    FtNode *n = ft_node_find(t->root, t->focus);
    if (n) {
        return n;
    }
    FtNode *panes[8];
    if (ft_node_collect(t->root, panes, 8) > 0) {
        return panes[0];
    }
    return NULL;
}

static int project_index(FtModel *m, const char *sel) {
    if (!sel || !sel[0]) {
        return m->active;
    }
    if (ft_str_ieq(sel, "pinned") || strcmp(sel, FT_PINNED_ID) == 0) {
        return -2;
    }
    char *end = NULL;
    long idx = strtol(sel, &end, 10);
    if (end && *end == 0 && idx >= 1 && idx <= m->nprojects) {
        return (int)idx - 1;
    }
    for (int i = 0; i < m->nprojects; i++) {
        if (strcmp(m->projects[i].id, sel) == 0 || ft_str_ieq(m->projects[i].name, sel)) {
            return i;
        }
    }
    return -1;
}

FtProjectRec *ft_model_find_project(FtModel *m, const char *sel) {
    int i = project_index(m, sel);
    if (i == -2) {
        return &m->pinned;
    }
    if (i < 0 || i >= m->nprojects) {
        return NULL;
    }
    return &m->projects[i];
}

static FtTabRec *find_tab(FtProjectRec *p, const char *sel, int *out_idx) {
    if (!p) {
        return NULL;
    }
    if (!sel || !sel[0]) {
        if (p->ntabs == 0) {
            return NULL;
        }
        int i = p->active_tab;
        if (i < 0 || i >= p->ntabs) {
            i = 0;
        }
        if (out_idx) {
            *out_idx = i;
        }
        return &p->tabs[i];
    }
    char *end = NULL;
    long idx = strtol(sel, &end, 10);
    if (end && *end == 0 && idx >= 1 && idx <= p->ntabs) {
        if (out_idx) {
            *out_idx = (int)idx - 1;
        }
        return &p->tabs[idx - 1];
    }
    if (strncmp(sel, "tab:", 4) == 0) {
        idx = strtol(sel + 4, &end, 10);
        if (idx >= 1 && idx <= p->ntabs) {
            if (out_idx) {
                *out_idx = (int)idx - 1;
            }
            return &p->tabs[idx - 1];
        }
    }
    for (int i = 0; i < p->ntabs; i++) {
        if (strcmp(p->tabs[i].id, sel) == 0 || strcmp(p->tabs[i].title, sel) == 0) {
            if (out_idx) {
                *out_idx = i;
            }
            return &p->tabs[i];
        }
    }
    return NULL;
}

static FtProjectRec *ensure_active(FtModel *m) {
    FtProjectRec *p = ft_model_active(m);
    if (p) {
        return p;
    }
    if (m->nprojects > 0) {
        m->active = 0;
        return &m->projects[0];
    }
    return NULL;
}

int ft_model_project_create(FtModel *m, const char *path, const char *name, int select) {
    if (!path || !path[0]) {
        set_err(m, "path required");
        return -1;
    }
    FtProjectPath parsed;
    if (ft_path_parse(path, &parsed) != 0) {
        set_err(m, "invalid project path");
        return -1;
    }
    if (m->nprojects >= FT_MAX_PROJECTS) {
        set_err(m, "too many projects");
        return -1;
    }
    FtProjectRec *p = &m->projects[m->nprojects];
    memset(p, 0, sizeof(*p));
    ft_uuid(p->id);
    char disp[64];
    if (name && name[0]) {
        ft_str_set(p->name, sizeof(p->name), name);
    } else {
        ft_path_display_name(path, disp, sizeof(disp));
        ft_str_set(p->name, sizeof(p->name), disp);
    }
    if (parsed.kind == FT_PATH_LOCAL) {
        char canon[512];
        ft_path_canonical_local(path, canon, sizeof(canon));
        ft_str_set(p->path, sizeof(p->path), canon);
    } else {
        ft_str_set(p->path, sizeof(p->path), path);
    }
    if (m->add_folder[0]) {
        ft_str_set(p->folder_id, sizeof(p->folder_id), m->add_folder);
    }
    m->nprojects++;
    if (select || m->active < 0) {
        m->active = m->nprojects - 1;
        add_empty_tab(m, p, "Tab 1", NULL);
    }
    return 0;
}

int ft_model_add_local(FtModel *m, const char *path) {
    if (!path || !path[0] || ft_path_is_remote(path)) {
        set_err(m, "local folder path required");
        return -1;
    }
    return ft_model_project_open(m, path, NULL);
}

int ft_model_add_remote(FtModel *m, const char *spec) {
    if (!ft_path_is_remote(spec)) {
        set_err(m, "remote spec required");
        return -1;
    }
    return ft_model_project_open(m, spec, NULL);
}

int ft_model_set_add_folder(FtModel *m, const char *folder_id) {
    if (!m) {
        return -1;
    }
    if (!folder_id || !folder_id[0]) {
        m->add_folder[0] = 0;
        return 0;
    }
    if (!ft_model_folder_find(m, folder_id)) {
        set_err(m, "folder not found");
        return -1;
    }
    ft_str_set(m->add_folder, sizeof(m->add_folder), folder_id);
    return 0;
}

FtFolderRec *ft_model_folder_find(FtModel *m, const char *id) {
    if (!m || !id || !id[0]) {
        return NULL;
    }
    for (int i = 0; i < m->nfolders; i++) {
        if (strcmp(m->folders[i].id, id) == 0) {
            return &m->folders[i];
        }
    }
    return NULL;
}

int ft_model_folder_create(FtModel *m, const char *name, const char *parent_id, char *id_out, size_t n) {
    if (!m || !name || !name[0]) {
        if (m) {
            set_err(m, "folder name required");
        }
        return -1;
    }
    if (m->nfolders >= FT_MAX_FOLDERS) {
        set_err(m, "too many folders");
        return -1;
    }
    if (parent_id && parent_id[0] && !ft_model_folder_find(m, parent_id)) {
        set_err(m, "parent folder not found");
        return -1;
    }
    FtFolderRec *f = &m->folders[m->nfolders];
    memset(f, 0, sizeof(*f));
    ft_uuid(f->id);
    ft_str_set(f->name, sizeof(f->name), name);
    if (parent_id && parent_id[0]) {
        ft_str_set(f->parent, sizeof(f->parent), parent_id);
    }
    f->expanded = 1;
    m->nfolders++;
    if (id_out && n) {
        ft_str_set(id_out, n, f->id);
    }
    return 0;
}

int ft_model_project_open(FtModel *m, const char *path, const char *name) {
    for (int i = 0; i < m->nprojects; i++) {
        if (ft_path_matches(m->projects[i].path, path)) {
            m->active = i;
            m->projects[i].unloaded = 0;
            if (m->projects[i].ntabs == 0) {
                add_empty_tab(m, &m->projects[i], "Tab 1", NULL);
            }
            return 0;
        }
    }
    return ft_model_project_create(m, path, name, 1);
}

int ft_model_project_select(FtModel *m, const char *sel) {
    int i = project_index(m, sel);
    if (i == -2) {
        m->active = -2;
        return 0;
    }
    if (i < 0) {
        set_err(m, "project not found");
        return -1;
    }
    m->active = i;
    m->projects[i].unloaded = 0;
    if (m->projects[i].ntabs == 0) {
        add_empty_tab(m, &m->projects[i], "Tab 1", NULL);
    }
    return 0;
}

int ft_model_project_rename(FtModel *m, const char *name) {
    FtProjectRec *p = ft_model_active(m);
    if (!p || p == &m->pinned) {
        set_err(m, "no project");
        return -1;
    }
    ft_str_set(p->name, sizeof(p->name), name);
    return 0;
}

int ft_model_project_unload(FtModel *m, const char *sel) {
    FtProjectRec *p = sel && sel[0] ? ft_model_find_project(m, sel) : ft_model_active(m);
    if (!p || p == &m->pinned) {
        set_err(m, "no project");
        return -1;
    }
    /* Keep trees and session names so relaunch/select reattaches; do not mint
     * new hex or drop names (drop_unused_terms keys off all_sessions). */
    p->unloaded = 1;
    return 0;
}

int ft_model_project_remove(FtModel *m, const char *sel) {
    int i = project_index(m, sel && sel[0] ? sel : NULL);
    if (i < 0) {
        set_err(m, "no project");
        return -1;
    }
    project_clear(&m->projects[i]);
    for (int j = i; j < m->nprojects - 1; j++) {
        m->projects[j] = m->projects[j + 1];
        memset(&m->projects[j + 1], 0, sizeof(m->projects[j + 1]));
    }
    m->nprojects--;
    if (m->active == i) {
        m->active = m->nprojects ? 0 : -1;
    } else if (m->active > i) {
        m->active--;
    }
    return 0;
}

int ft_model_tab_new(FtModel *m, const char *project_sel, const char *run, char *session_out, size_t n) {
    FtProjectRec *p = project_sel && project_sel[0] ? ft_model_find_project(m, project_sel) : ensure_active(m);
    if (!p) {
        set_err(m, "no project");
        return -1;
    }
    if (p != &m->pinned) {
        m->active = (int)(p - m->projects);
    } else {
        m->active = -2;
    }
    char title[32];
    snprintf(title, sizeof(title), "Tab %d", p->ntabs + 1);
    int idx = add_empty_tab(m, p, title, run);
    if (idx < 0) {
        return -1;
    }
    if (p == &m->pinned) {
        p->tabs[idx].pinned = 1;
        ft_str_set(p->tabs[idx].origin, sizeof(p->tabs[idx].origin), p->id);
    }
    if (session_out && n) {
        ft_str_set(session_out, n, p->tabs[idx].root->session);
    }
    return 0;
}

int ft_model_tab_select(FtModel *m, const char *tab_sel) {
    FtProjectRec *p = ensure_active(m);
    int idx = 0;
    FtTabRec *t = find_tab(p, tab_sel, &idx);
    if (!t) {
        set_err(m, "tab not found");
        return -1;
    }
    p->recent_tab = p->active_tab;
    p->active_tab = idx;
    if (t->unloaded && t->pinned) {
        return ft_model_restore_pinned(m, t->id);
    }
    return 0;
}

int ft_model_tab_close(FtModel *m, const char *tab_sel, int force, int (*busy)(void *, const char *), void *busy_user) {
    FtProjectRec *p = ensure_active(m);
    int idx = 0;
    FtTabRec *t = find_tab(p, tab_sel, &idx);
    if (!t) {
        set_err(m, "tab not found");
        return -1;
    }
    if (!force && busy) {
        FtNode *panes[64];
        int n = ft_node_collect(t->root, panes, 64);
        for (int i = 0; i < n; i++) {
            if (busy(busy_user, panes[i]->session)) {
                set_err(m, "busy");
                return -2;
            }
        }
    }
    if (t->pinned) {
        t->unloaded = 1;
        if (!t->declaration && t->root) {
            t->declaration = ft_node_clone(t->root);
        }
        /* Keep root (session names + split) so a dimmed-row restore reattaches
         * the same zmx sessions instead of minting a blank pane. */
        return 0;
    }
    tab_clear(t);
    for (int i = idx; i < p->ntabs - 1; i++) {
        p->tabs[i] = p->tabs[i + 1];
        memset(&p->tabs[i + 1], 0, sizeof(p->tabs[i + 1]));
    }
    p->ntabs--;
    if (p->ntabs == 0) {
        add_empty_tab(m, p, "Tab 1", NULL);
    }
    if (p->active_tab >= p->ntabs) {
        p->active_tab = p->ntabs - 1;
    }
    return 0;
}

int ft_model_tab_move(FtModel *m, const char *tab_sel, int slot) {
    FtProjectRec *p = ensure_active(m);
    int idx = 0;
    if (!find_tab(p, tab_sel, &idx)) {
        set_err(m, "tab not found");
        return -1;
    }
    int dest = slot - 1;
    if (dest < 0) {
        dest = 0;
    }
    if (dest >= p->ntabs) {
        dest = p->ntabs - 1;
    }
    if (dest == idx) {
        return 0;
    }
    FtTabRec tmp = p->tabs[idx];
    if (dest > idx) {
        for (int i = idx; i < dest; i++) {
            p->tabs[i] = p->tabs[i + 1];
        }
    } else {
        for (int i = idx; i > dest; i--) {
            p->tabs[i] = p->tabs[i - 1];
        }
    }
    p->tabs[dest] = tmp;
    p->active_tab = dest;
    return 0;
}

int ft_model_tab_rename(FtModel *m, const char *title) {
    FtTabRec *t = ft_model_active_tab(m);
    if (!t) {
        return -1;
    }
    ft_str_set(t->title, sizeof(t->title), title);
    t->custom_title = 1;
    return 0;
}

int ft_model_tab_cycle(FtModel *m, int delta, int in_project) {
    if (in_project) {
        FtProjectRec *p = ensure_active(m);
        if (!p || p->ntabs == 0) {
            return -1;
        }
        p->recent_tab = p->active_tab;
        p->active_tab = (p->active_tab + delta) % p->ntabs;
        if (p->active_tab < 0) {
            p->active_tab += p->ntabs;
        }
        return 0;
    }
    /* global: pinned records first, then each project's tabs */
    typedef struct {
        int proj; /* -2 pinned */
        int tab;
    } Loc;
    Loc locs[256];
    int n = 0;
    for (int i = 0; i < m->pinned.ntabs && n < 256; i++) {
        locs[n].proj = -2;
        locs[n].tab = i;
        n++;
    }
    for (int p = 0; p < m->nprojects; p++) {
        for (int t = 0; t < m->projects[p].ntabs && n < 256; t++) {
            locs[n].proj = p;
            locs[n].tab = t;
            n++;
        }
    }
    if (n == 0) {
        return -1;
    }
    int cur = 0;
    int ap = m->active;
    int at = 0;
    FtProjectRec *pr = ft_model_active(m);
    if (pr) {
        at = pr->active_tab;
    }
    for (int i = 0; i < n; i++) {
        if (locs[i].proj == ap && locs[i].tab == at) {
            cur = i;
            break;
        }
    }
    cur = (cur + delta) % n;
    if (cur < 0) {
        cur += n;
    }
    m->active = locs[cur].proj;
    FtProjectRec *np = locs[cur].proj == -2 ? &m->pinned : &m->projects[locs[cur].proj];
    np->recent_tab = np->active_tab;
    np->active_tab = locs[cur].tab;
    return 0;
}

int ft_model_tab_recent(FtModel *m) {
    FtProjectRec *p = ensure_active(m);
    if (!p || p->ntabs == 0) {
        return -1;
    }
    int r = p->recent_tab;
    if (r < 0 || r >= p->ntabs) {
        r = 0;
    }
    int cur = p->active_tab;
    p->active_tab = r;
    p->recent_tab = cur;
    return 0;
}

static FtNode *resolve_pane(FtModel *m, const char *session, FtTabRec **tab_out) {
    FtTabRec *t = ft_model_active_tab(m);
    if (tab_out) {
        *tab_out = t;
    }
    if (!t || !t->root) {
        return NULL;
    }
    if (session && session[0]) {
        FtNode *n = ft_node_find(t->root, session);
        if (n) {
            return n;
        }
        /* search all */
        for (int pi = 0; pi < m->nprojects; pi++) {
            for (int ti = 0; ti < m->projects[pi].ntabs; ti++) {
                n = ft_node_find(m->projects[pi].tabs[ti].root, session);
                if (n) {
                    m->active = pi;
                    m->projects[pi].active_tab = ti;
                    if (tab_out) {
                        *tab_out = &m->projects[pi].tabs[ti];
                    }
                    return n;
                }
            }
        }
        for (int ti = 0; ti < m->pinned.ntabs; ti++) {
            n = ft_node_find(m->pinned.tabs[ti].root, session);
            if (n) {
                m->active = -2;
                m->pinned.active_tab = ti;
                if (tab_out) {
                    *tab_out = &m->pinned.tabs[ti];
                }
                return n;
            }
        }
        return NULL;
    }
    return ft_node_find(t->root, t->focus);
}

int ft_model_split(FtModel *m, const char *session, const char *direction, const char *run, char *session_out, size_t n) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    FtProjectRec *p = ft_model_active(m);
    if (!pane || !tab || !p) {
        set_err(m, "no pane");
        return -1;
    }
    int dir = FT_SPLIT_H;
    if (direction && (strcmp(direction, "down") == 0 || strcmp(direction, "vertical") == 0)) {
        dir = FT_SPLIT_V;
    } else if (direction && strcmp(direction, "auto") == 0) {
        dir = FT_SPLIT_H;
    }
    FtNode *fresh = ft_node_pane("", pane->cwd[0] ? pane->cwd : p->path);
    if (run && run[0]) {
        ft_str_set(fresh->run, sizeof(fresh->run), run);
    }
    ft_model_fill_sessions(m, fresh, p->name, p->path);
    if (ft_node_split_at(&tab->root, pane->session, dir, fresh) != 0) {
        ft_node_free(fresh);
        return -1;
    }
    ft_str_set(tab->focus, sizeof(tab->focus), fresh->session);
    if (session_out) {
        ft_str_set(session_out, n, fresh->session);
    }
    return 0;
}

int ft_model_focus(FtModel *m, const char *session, const char *direction) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    if (!pane || !tab) {
        set_err(m, "no pane");
        return -1;
    }
    const char *target = pane->session;
    if (direction && direction[0]) {
        int d = FT_DIR_RIGHT;
        if (strcmp(direction, "left") == 0) {
            d = FT_DIR_LEFT;
        } else if (strcmp(direction, "up") == 0) {
            d = FT_DIR_UP;
        } else if (strcmp(direction, "down") == 0) {
            d = FT_DIR_DOWN;
        } else if (strcmp(direction, "right") == 0) {
            d = FT_DIR_RIGHT;
        } else if (strcmp(direction, "next") == 0) {
            target = ft_node_cycle(tab->root, pane->session, 1);
            ft_str_set(tab->focus, sizeof(tab->focus), target ? target : pane->session);
            return 0;
        } else if (strcmp(direction, "previous") == 0 || strcmp(direction, "prev") == 0) {
            target = ft_node_cycle(tab->root, pane->session, -1);
            ft_str_set(tab->focus, sizeof(tab->focus), target ? target : pane->session);
            return 0;
        }
        const char *nb = ft_node_neighbor(tab->root, pane->session, d);
        if (nb) {
            target = nb;
        }
    }
    ft_str_set(tab->focus, sizeof(tab->focus), target);
    return 0;
}

int ft_model_close_pane(FtModel *m, const char *session, int force, int (*busy)(void *, const char *), void *busy_user) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    if (!pane || !tab) {
        set_err(m, "no pane");
        return -1;
    }
    if (!force && busy && busy(busy_user, pane->session)) {
        set_err(m, "busy");
        return -2;
    }
    if (ft_node_count(tab->root) <= 1) {
        return ft_model_tab_close(m, tab->id, force, busy, busy_user);
    }
    char gone[80];
    ft_str_set(gone, sizeof(gone), pane->session);
    ft_node_close(&tab->root, gone);
    FtNode *left[8];
    if (ft_node_collect(tab->root, left, 8) > 0) {
        ft_str_set(tab->focus, sizeof(tab->focus), left[0]->session);
    }
    return 0;
}

int ft_model_zoom(FtModel *m, const char *session) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    if (!pane || !tab) {
        return -1;
    }
    if (tab->zoom[0] && strcmp(tab->zoom, pane->session) == 0) {
        tab->zoom[0] = 0;
    } else {
        ft_str_set(tab->zoom, sizeof(tab->zoom), pane->session);
    }
    return 0;
}

int ft_model_resize(FtModel *m, const char *session, int dir, double delta) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    if (!pane || !tab) {
        return -1;
    }
    return ft_node_resize(tab->root, pane->session, dir, delta);
}

int ft_model_grid(FtModel *m, const char *session, int rows, int cols, const char *run) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    FtProjectRec *p = ft_model_active(m);
    if (!pane || !tab || !p) {
        return -1;
    }
    FtNode *created[64];
    int n = ft_node_grid(&tab->root, pane->session, rows, cols, created, 64);
    if (n < 0) {
        return -1;
    }
    for (int i = 0; i < n; i++) {
        if (run && run[0]) {
            ft_str_set(created[i]->run, sizeof(created[i]->run), run);
        }
        ft_model_fill_sessions(m, created[i], p->name, p->path);
    }
    return 0;
}

int ft_model_separate_pane(FtModel *m, const char *session) {
    FtTabRec *tab = NULL;
    FtNode *pane = resolve_pane(m, session, &tab);
    FtProjectRec *p = ft_model_active(m);
    if (!pane || !tab || !p) {
        return -1;
    }
    if (ft_node_count(tab->root) <= 1) {
        return 0;
    }
    FtNode *taken = ft_node_detach(&tab->root, pane->session);
    if (!taken) {
        return -1;
    }
    if (p->ntabs >= FT_MAX_TABS) {
        ft_node_free(taken);
        return -1;
    }
    FtNode *left[8];
    if (ft_node_collect(tab->root, left, 8) > 0) {
        ft_str_set(tab->focus, sizeof(tab->focus), left[0]->session);
    }
    FtTabRec *nt = &p->tabs[p->ntabs];
    memset(nt, 0, sizeof(*nt));
    ft_uuid(nt->id);
    ft_str_set(nt->title, sizeof(nt->title), taken->session);
    nt->root = taken;
    ft_str_set(nt->focus, sizeof(nt->focus), taken->session);
    p->active_tab = p->ntabs;
    p->ntabs++;
    return 0;
}

int ft_model_separate_all(FtModel *m) {
    FtTabRec *tab = ft_model_active_tab(m);
    FtProjectRec *p = ft_model_active(m);
    if (!tab || !p) {
        return -1;
    }
    FtNode *leaves[64];
    int n = ft_node_detach_all(&tab->root, leaves, 64);
    if (n <= 1) {
        if (n == 1) {
            tab->root = leaves[0];
            ft_str_set(tab->focus, sizeof(tab->focus), leaves[0]->session);
        }
        return 0;
    }
    tab->root = leaves[0];
    ft_str_set(tab->focus, sizeof(tab->focus), leaves[0]->session);
    for (int i = 1; i < n && p->ntabs < FT_MAX_TABS; i++) {
        FtTabRec *nt = &p->tabs[p->ntabs];
        memset(nt, 0, sizeof(*nt));
        ft_uuid(nt->id);
        snprintf(nt->title, sizeof(nt->title), "Tab %d", p->ntabs + 1);
        nt->root = leaves[i];
        ft_str_set(nt->focus, sizeof(nt->focus), leaves[i]->session);
        p->ntabs++;
    }
    return 0;
}

int ft_model_pin(FtModel *m) {
    FtProjectRec *p = ft_model_active(m);
    FtTabRec *t = ft_model_active_tab(m);
    if (!p || !t || p == &m->pinned) {
        return -1;
    }
    if (m->pinned.ntabs >= FT_MAX_TABS) {
        return -1;
    }
    int idx = (int)(t - p->tabs);
    FtTabRec rec = *t;
    rec.pinned = 1;
    ft_str_set(rec.origin, sizeof(rec.origin), p->id);
    if (!rec.declaration && rec.root) {
        rec.declaration = ft_node_clone(rec.root);
    }
    memset(t, 0, sizeof(*t));
    for (int i = idx; i < p->ntabs - 1; i++) {
        p->tabs[i] = p->tabs[i + 1];
        memset(&p->tabs[i + 1], 0, sizeof(p->tabs[i + 1]));
    }
    p->ntabs--;
    if (p->ntabs == 0) {
        add_empty_tab(m, p, "Tab 1", NULL);
    } else if (p->active_tab >= p->ntabs) {
        p->active_tab = p->ntabs - 1;
    }
    m->pinned.tabs[m->pinned.ntabs] = rec;
    m->pinned.active_tab = m->pinned.ntabs;
    m->pinned.ntabs++;
    m->active = -2;
    return 0;
}

int ft_model_unpin(FtModel *m) {
    if (m->active != -2) {
        set_err(m, "not a pinned tab");
        return -1;
    }
    FtTabRec *t = ft_model_active_tab(m);
    if (!t) {
        return -1;
    }
    int dest = 0;
    for (int i = 0; i < m->nprojects; i++) {
        if (strcmp(m->projects[i].id, t->origin) == 0) {
            dest = i;
            break;
        }
    }
    if (m->nprojects == 0) {
        set_err(m, "no project to unpin into");
        return -1;
    }
    FtProjectRec *p = &m->projects[dest];
    if (p->ntabs >= FT_MAX_TABS) {
        return -1;
    }
    int idx = (int)(t - m->pinned.tabs);
    FtTabRec rec = *t;
    rec.pinned = 0;
    rec.origin[0] = 0;
    rec.unloaded = 0;
    memset(t, 0, sizeof(*t));
    for (int i = idx; i < m->pinned.ntabs - 1; i++) {
        m->pinned.tabs[i] = m->pinned.tabs[i + 1];
        memset(&m->pinned.tabs[i + 1], 0, sizeof(m->pinned.tabs[i + 1]));
    }
    m->pinned.ntabs--;
    p->tabs[p->ntabs] = rec;
    p->active_tab = p->ntabs;
    p->ntabs++;
    m->active = dest;
    return 0;
}

int ft_model_restore_pinned(FtModel *m, const char *tab_sel) {
    m->active = -2;
    int idx = 0;
    FtTabRec *t = find_tab(&m->pinned, tab_sel, &idx);
    if (!t) {
        return -1;
    }
    m->pinned.active_tab = idx;
    t->unloaded = 0;
    if (!t->root && t->declaration) {
        t->root = ft_node_clone(t->declaration);
    }
    if (!t->root) {
        t->root = ft_node_pane("", "");
    }
    ft_model_fill_sessions(m, t->root, "pinned", getenv("HOME"));
    if (!t->focus[0]) {
        FtNode *panes[8];
        if (ft_node_collect(t->root, panes, 8) > 0) {
            ft_str_set(t->focus, sizeof(t->focus), panes[0]->session);
        }
    }
    return 0;
}

int ft_model_save_layout(FtModel *m, const char *project_sel, char *written, size_t n) {
    FtProjectRec *p = project_sel && project_sel[0] ? ft_model_find_project(m, project_sel) : ft_model_active(m);
    if (!p || p == &m->pinned) {
        set_err(m, "no project");
        return -1;
    }
    FtLayoutFile f;
    memset(&f, 0, sizeof(f));
    ft_str_set(f.name, sizeof(f.name), p->name);
    if (ft_path_is_local(p->path)) {
        ft_path_home_contract(p->path, f.path, sizeof(f.path));
    } else {
        ft_str_set(f.path, sizeof(f.path), p->path);
    }
    ft_str_set(f.zmx_path, sizeof(f.zmx_path), p->zmx_path);
    for (int i = 0; i < p->ntabs && i < FT_LAYOUT_MAX_TABS; i++) {
        f.tabs[i] = ft_node_clone(p->tabs[i].root);
        if (p->tabs[i].custom_title) {
            ft_str_set(f.tab_names[i], sizeof(f.tab_names[0]), p->tabs[i].title);
        }
        f.ntabs++;
    }
    char dir[768];
    snprintf(dir, sizeof(dir), "%s/projects", m->config_dir);
    int rc = ft_layout_write_dir(&f, dir, written, n);
    ft_layout_free(&f);
    return rc;
}

typedef struct {
    char session[80];
    char cwd[512];
    char run[512];
    int used;
} FtLivePane;

static int cwd_matches(const char *declared, const char *live, const char *root) {
    const char *a = (declared && declared[0]) ? declared : root;
    const char *b = (live && live[0]) ? live : root;
    if (!a) {
        a = "";
    }
    if (!b) {
        b = "";
    }
    if (ft_path_is_local(a) && ft_path_is_local(b)) {
        char ca[1024], cb[1024];
        ft_path_canonical_local(a, ca, sizeof(ca));
        ft_path_canonical_local(b, cb, sizeof(cb));
        return strcmp(ca, cb) == 0;
    }
    return strcmp(a, b) == 0;
}

static void collect_live_panes(FtProjectRec *p, FtLivePane *out, int *n, int max) {
    *n = 0;
    if (!p) {
        return;
    }
    for (int t = 0; t < p->ntabs && *n < max; t++) {
        FtNode *panes[64];
        int c = ft_node_collect(p->tabs[t].root, panes, 64);
        for (int i = 0; i < c && *n < max; i++) {
            ft_str_set(out[*n].session, sizeof(out[*n].session), panes[i]->session);
            ft_str_set(out[*n].cwd, sizeof(out[*n].cwd), panes[i]->cwd);
            ft_str_set(out[*n].run, sizeof(out[*n].run), panes[i]->run);
            out[*n].used = 0;
            (*n)++;
        }
    }
}

static int stamp_from_live(FtNode *n, FtLivePane *live, int nlive, const char *root) {
    if (!n) {
        return 0;
    }
    if (n->is_split) {
        return stamp_from_live(n->first, live, nlive, root) + stamp_from_live(n->second, live, nlive, root);
    }
    int want_run = n->run[0] != 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < nlive; i++) {
            if (live[i].used) {
                continue;
            }
            int run_ok = strcmp(n->run, live[i].run) == 0;
            if (pass == 0 && want_run && run_ok && cwd_matches(n->cwd, live[i].cwd, root)) {
                ft_str_set(n->session, sizeof(n->session), live[i].session);
                live[i].used = 1;
                return 1;
            }
            if (pass == 1 && !want_run && live[i].run[0] == 0 && cwd_matches(n->cwd, live[i].cwd, root)) {
                ft_str_set(n->session, sizeof(n->session), live[i].session);
                live[i].used = 1;
                return 1;
            }
        }
    }
    n->session[0] = 0;
    return 0;
}

int ft_model_apply_layout(FtModel *m, const char *project_sel, int force) {
    (void)force;
    FtProjectRec *p = project_sel && project_sel[0] ? ft_model_find_project(m, project_sel) : ft_model_active(m);
    if (!p || p == &m->pinned) {
        set_err(m, "no project");
        return -1;
    }
    char dir[768], found[768];
    snprintf(dir, sizeof(dir), "%s/projects", m->config_dir);
    if (ft_layout_find_for_project(dir, p->path, p->name, found, sizeof(found)) != 0) {
        set_err(m, "no layout file");
        return -1;
    }
    FtLayoutFile f;
    if (ft_layout_load_path(found, &f) != 0) {
        set_err(m, "layout parse failed");
        return -1;
    }
    FtLivePane live[128];
    int nlive = 0;
    collect_live_panes(p, live, &nlive, 128);
    FtTabRec next[FT_MAX_TABS];
    memset(next, 0, sizeof(next));
    int nnext = 0;
    for (int i = 0; i < f.ntabs && nnext < FT_MAX_TABS; i++) {
        FtTabRec *t = &next[nnext];
        ft_uuid(t->id);
        ft_str_set(t->title, sizeof(t->title), f.tab_names[i][0] ? f.tab_names[i] : "Tab");
        if (f.tab_names[i][0]) {
            t->custom_title = 1;
        }
        t->root = ft_node_clone(f.tabs[i]);
        stamp_from_live(t->root, live, nlive, p->path);
        ft_model_fill_sessions(m, t->root, p->name, p->path);
        FtNode *panes[8];
        if (ft_node_collect(t->root, panes, 8) > 0) {
            ft_str_set(t->focus, sizeof(t->focus), panes[0]->session);
        }
        nnext++;
    }
    for (int i = 0; i < p->ntabs; i++) {
        tab_clear(&p->tabs[i]);
    }
    for (int i = 0; i < nnext; i++) {
        p->tabs[i] = next[i];
    }
    p->ntabs = nnext;
    p->active_tab = 0;
    p->unloaded = 0;
    ft_layout_free(&f);
    if (p->ntabs == 0) {
        add_empty_tab(m, p, "Tab 1", NULL);
    }
    return 0;
}

int ft_model_all_sessions(FtModel *m, char sessions[][80], int max) {
    int n = 0;
    FtProjectRec *sets[FT_MAX_PROJECTS + 1];
    int ns = 0;
    sets[ns++] = &m->pinned;
    for (int i = 0; i < m->nprojects; i++) {
        sets[ns++] = &m->projects[i];
    }
    for (int s = 0; s < ns; s++) {
        for (int t = 0; t < sets[s]->ntabs; t++) {
            FtNode *panes[64];
            int c = ft_node_collect(sets[s]->tabs[t].root, panes, 64);
            for (int i = 0; i < c && n < max; i++) {
                ft_str_set(sessions[n], 80, panes[i]->session);
                n++;
            }
        }
    }
    return n;
}

static int emit_node_json(const FtNode *n, FtBuf *b) {
    if (!n) {
        return ft_buf_printf(b, "null");
    }
    if (!n->is_split) {
        char esc[1024];
        ft_json_esc(n->run, esc, sizeof(esc));
        return ft_buf_printf(
            b,
            "{\"kind\":\"pane\",\"id\":\"%s\",\"session\":\"%s\",\"cwd\":\"%s\",\"run\":\"%s\",\"shell\":\"%s\"}",
            n->pane_id,
            n->session,
            n->cwd,
            esc,
            n->shell
        );
    }
    ft_buf_printf(
        b,
        "{\"kind\":\"split\",\"dir\":\"%s\",\"ratio\":%.3f,\"first\":",
        n->dir == FT_SPLIT_V ? "vertical" : "horizontal",
        n->ratio
    );
    emit_node_json(n->first, b);
    ft_buf_printf(b, ",\"second\":");
    emit_node_json(n->second, b);
    return ft_buf_printf(b, "}");
}

static FtNode *parse_node_json(const char *json, int len) {
    if (!json || len <= 0) {
        return NULL;
    }
    char buf[8192];
    if (len >= (int)sizeof(buf)) {
        len = (int)sizeof(buf) - 1;
    }
    memcpy(buf, json, (size_t)len);
    buf[len] = 0;
    char kind[16] = "";
    ft_json_str(buf, "kind", kind, sizeof(kind));
    if (strcmp(kind, "split") == 0) {
        char dir[16] = "horizontal";
        double ratio = 0.5;
        ft_json_str(buf, "dir", dir, sizeof(dir));
        ft_json_double(buf, "ratio", &ratio);
        int l1 = 0, l2 = 0;
        const char *f = ft_json_raw(buf, "first", &l1);
        const char *s = ft_json_raw(buf, "second", &l2);
        FtNode *a = parse_node_json(f, l1);
        FtNode *b = parse_node_json(s, l2);
        return ft_node_split(strcmp(dir, "vertical") == 0 ? FT_SPLIT_V : FT_SPLIT_H, a, b, ratio);
    }
    FtNode *n = ft_node_pane("", "");
    ft_json_str(buf, "id", n->pane_id, sizeof(n->pane_id));
    ft_json_str(buf, "session", n->session, sizeof(n->session));
    ft_json_str(buf, "cwd", n->cwd, sizeof(n->cwd));
    ft_json_str(buf, "run", n->run, sizeof(n->run));
    ft_json_str(buf, "shell", n->shell, sizeof(n->shell));
    return n;
}

typedef struct {
    FtModel *m;
    FtProjectRec *p;
} LoadCtx;

static int load_tab(const char *elem, int len, void *user) {
    LoadCtx *c = user;
    FtProjectRec *p = c->p;
    if (p->ntabs >= FT_MAX_TABS) {
        return 0;
    }
    char buf[16384];
    if (len >= (int)sizeof(buf)) {
        len = (int)sizeof(buf) - 1;
    }
    memcpy(buf, elem, (size_t)len);
    buf[len] = 0;
    FtTabRec *t = &p->tabs[p->ntabs];
    memset(t, 0, sizeof(*t));
    ft_json_str(buf, "id", t->id, sizeof(t->id));
    ft_json_str(buf, "title", t->title, sizeof(t->title));
    ft_json_bool(buf, "custom", &t->custom_title);
    ft_json_str(buf, "origin", t->origin, sizeof(t->origin));
    ft_json_bool(buf, "unloaded", &t->unloaded);
    ft_json_bool(buf, "pinned", &t->pinned);
    ft_json_str(buf, "focus", t->focus, sizeof(t->focus));
    ft_json_str(buf, "zoom", t->zoom, sizeof(t->zoom));
    int rl = 0;
    const char *root = ft_json_raw(buf, "root", &rl);
    t->root = parse_node_json(root, rl);
    if (!t->id[0]) {
        ft_uuid(t->id);
    }
    p->ntabs++;
    return 0;
}

static int load_project(const char *elem, int len, void *user) {
    FtModel *m = user;
    if (m->nprojects >= FT_MAX_PROJECTS) {
        return 0;
    }
    char buf[4096];
    if (len >= (int)sizeof(buf)) {
        len = (int)sizeof(buf) - 1;
    }
    memcpy(buf, elem, (size_t)len);
    buf[len] = 0;
    FtProjectRec *p = &m->projects[m->nprojects];
    memset(p, 0, sizeof(*p));
    ft_json_str(buf, "id", p->id, sizeof(p->id));
    ft_json_str(buf, "name", p->name, sizeof(p->name));
    ft_json_str(buf, "path", p->path, sizeof(p->path));
    ft_json_str(buf, "zmxPath", p->zmx_path, sizeof(p->zmx_path));
    ft_json_bool(buf, "unloaded", &p->unloaded);
    ft_json_str(buf, "folder", p->folder_id, sizeof(p->folder_id));
    if (!p->id[0]) {
        ft_uuid(p->id);
    }
    m->nprojects++;
    return 0;
}

static int load_folder(const char *elem, int len, void *user) {
    FtModel *m = user;
    if (m->nfolders >= FT_MAX_FOLDERS) {
        return 0;
    }
    char buf[1024];
    if (len >= (int)sizeof(buf)) {
        len = (int)sizeof(buf) - 1;
    }
    memcpy(buf, elem, (size_t)len);
    buf[len] = 0;
    FtFolderRec *f = &m->folders[m->nfolders];
    memset(f, 0, sizeof(*f));
    ft_json_str(buf, "id", f->id, sizeof(f->id));
    ft_json_str(buf, "name", f->name, sizeof(f->name));
    ft_json_str(buf, "parent", f->parent, sizeof(f->parent));
    int expanded = 1;
    ft_json_bool(buf, "expanded", &expanded);
    f->expanded = expanded;
    if (!f->id[0] || !f->name[0]) {
        return 0;
    }
    m->nfolders++;
    return 0;
}

static int load_ws(const char *elem, int len, void *user) {
    FtModel *m = user;
    char buf[65536];
    if (len >= (int)sizeof(buf)) {
        len = (int)sizeof(buf) - 1;
    }
    memcpy(buf, elem, (size_t)len);
    buf[len] = 0;
    char pid[40] = "";
    ft_json_str(buf, "project", pid, sizeof(pid));
    FtProjectRec *p = NULL;
    if (strcmp(pid, FT_PINNED_ID) == 0) {
        p = &m->pinned;
    } else {
        for (int i = 0; i < m->nprojects; i++) {
            if (strcmp(m->projects[i].id, pid) == 0) {
                p = &m->projects[i];
                break;
            }
        }
    }
    if (!p) {
        return 0;
    }
    ft_json_int(buf, "activeTab", &p->active_tab);
    int alen = 0;
    const char *tabs = ft_json_raw(buf, "tabs", &alen);
    LoadCtx ctx = {.m = m, .p = p};
    if (tabs) {
        ft_json_array(tabs, load_tab, &ctx);
    }
    return 0;
}

int ft_model_save(FtModel *m) {
    if (ft_mkdir_p(m->data_dir) != 0) {
        return -1;
    }
    char path[768];
    snprintf(path, sizeof(path), "%s/projects.json", m->data_dir);
    char buf[65536];
    FtBuf b;
    ft_buf_init(&b, buf, sizeof(buf));
    ft_buf_printf(&b, "{\"v\":1,\"active\":%d,\"projects\":[", m->active);
    for (int i = 0; i < m->nprojects; i++) {
        if (i) {
            ft_buf_printf(&b, ",");
        }
        FtProjectRec *p = &m->projects[i];
        char esc[1024];
        ft_json_esc(p->path, esc, sizeof(esc));
        ft_buf_printf(
            &b,
            "{\"id\":\"%s\",\"name\":\"%s\",\"path\":\"%s\",\"zmxPath\":\"%s\",\"folder\":\"%s\",\"unloaded\":%s}",
            p->id,
            p->name,
            esc,
            p->zmx_path,
            p->folder_id,
            p->unloaded ? "true" : "false"
        );
    }
    ft_buf_printf(&b, "],\"folders\":[");
    for (int i = 0; i < m->nfolders; i++) {
        if (i) {
            ft_buf_printf(&b, ",");
        }
        FtFolderRec *f = &m->folders[i];
        ft_buf_printf(
            &b,
            "{\"id\":\"%s\",\"name\":\"%s\",\"parent\":\"%s\",\"expanded\":%s}",
            f->id,
            f->name,
            f->parent,
            f->expanded ? "true" : "false"
        );
    }
    ft_buf_printf(&b, "],\"workspaces\":[");
    int first = 1;
    FtProjectRec *sets[FT_MAX_PROJECTS + 1];
    int ns = 0;
    sets[ns++] = &m->pinned;
    for (int i = 0; i < m->nprojects; i++) {
        sets[ns++] = &m->projects[i];
    }
    for (int s = 0; s < ns; s++) {
        FtProjectRec *p = sets[s];
        if (!first) {
            ft_buf_printf(&b, ",");
        }
        first = 0;
        ft_buf_printf(&b, "{\"project\":\"%s\",\"activeTab\":%d,\"tabs\":[", p->id, p->active_tab);
        for (int t = 0; t < p->ntabs; t++) {
            if (t) {
                ft_buf_printf(&b, ",");
            }
            FtTabRec *tb = &p->tabs[t];
            ft_buf_printf(
                &b,
                "{\"id\":\"%s\",\"title\":\"%s\",\"custom\":%s,\"origin\":\"%s\",\"unloaded\":%s,\"pinned\":%s,"
                "\"focus\":\"%s\",\"zoom\":\"%s\",\"root\":",
                tb->id,
                tb->title,
                tb->custom_title ? "true" : "false",
                tb->origin,
                tb->unloaded ? "true" : "false",
                tb->pinned ? "true" : "false",
                tb->focus,
                tb->zoom
            );
            emit_node_json(tb->root, &b);
            ft_buf_printf(&b, "}");
        }
        ft_buf_printf(&b, "]}");
    }
    ft_buf_printf(&b, "]}");
    return ft_write_file(path, buf);
}

int ft_model_load(FtModel *m) {
    char path[768];
    snprintf(path, sizeof(path), "%s/projects.json", m->data_dir);
    char buf[131072];
    if (ft_read_file(path, buf, sizeof(buf)) != 0) {
        /* first launch: persist a Home project, never a GitHub scan */
        const char *home = getenv("HOME");
        if (!home || !home[0]) {
            home = ".";
        }
        return ft_model_project_open(m, home, "Home");
    }
    int alen = 0;
    const char *projects = ft_json_raw(buf, "projects", &alen);
    if (projects) {
        ft_json_array(projects, load_project, m);
    }
    const char *folders = ft_json_raw(buf, "folders", &alen);
    if (folders) {
        ft_json_array(folders, load_folder, m);
    }
    ft_json_int(buf, "active", &m->active);
    const char *ws = ft_json_raw(buf, "workspaces", &alen);
    if (ws) {
        ft_json_array(ws, load_ws, m);
    }
    if (m->nprojects == 0) {
        const char *home = getenv("HOME");
        return ft_model_project_open(m, home ? home : ".", "Home");
    }
    if (m->active >= m->nprojects) {
        m->active = 0;
    }
    return 0;
}
