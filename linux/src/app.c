/* FuturaTerm Linux: GTK chrome over portable workspace/control units. */
#define _GNU_SOURCE
#include "command.h"
#include "control.h"
#include "desktop.h"
#include "model.h"
#include "path.h"
#include "prefs.h"
#include "remote.h"
#include "session.h"
#include "term.h"
#include "util.h"

#include <gdk/gdkkeysyms.h>
#include <gio/gio.h>
#include <gio/gunixsocketaddress.h>
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    FtModel *model;
    FtPrefs prefs;
    GtkWidget *window;
    GtkWidget *sidebar_scroll;
    GtkWidget *sidebar;
    GtkWidget *stack;
    GtkWidget *palette_win;
    GtkWidget *palette_entry;
    GtkWidget *palette_list;
    GtkWidget *prefs_win;
    GtkWidget *quick_win;
    FtTerm *quick_term;
    GHashTable *terms;
    GHashTable *notebooks;
    GHashTable *sent_run;
    GSocketService *service;
    char socket_path[256];
    char data_dir[512];
    char config_dir[512];
    int palette_hits[64];
    int npalette;
    guint title_src;
} FtApp;

static FtApp *g_app;

static void sync_ui(void);
static void run_action(const char *id);
static void show_palette(void);
static void show_prefs(void);
static void show_sessions(void);
static void toggle_quick(void);
static void confirm_busy_then(const char *what, void (*go)(void));
static void clicked_action(GtkButton *b, gpointer user);
static void on_term_exited(FtTerm *term, void *user);
static void reconnect_dropped_remotes(void);

static FtTerm *term_by_session(const char *session) {
    if (!session || !g_app->terms) {
        return NULL;
    }
    return g_hash_table_lookup(g_app->terms, session);
}

static void zmx_kill_session(const char *session, const char *project_path, const char *zmx_path) {
    if (!session || !session[0]) {
        return;
    }
    if (project_path && ft_path_is_remote(project_path)) {
        FtProjectPath p;
        if (ft_path_parse(project_path, &p) != 0) {
            return;
        }
        char dest[192];
        ft_path_destination(&p, dest, sizeof(dest));
        char script[1024];
        snprintf(
            script,
            sizeof(script),
            "%sexec zmx kill \"%s\"",
            FT_REMOTE_ENV_PREAMBLE,
            session
        );
        if (zmx_path && zmx_path[0]) {
            snprintf(script, sizeof(script), "%sexec \"%s\" kill \"%s\"", FT_REMOTE_ENV_PREAMBLE, zmx_path, session);
        }
        pid_t pid = fork();
        if (pid == 0) {
            execlp("ssh", "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", dest, "sh", "-c", script, (char *)NULL);
            _exit(127);
        }
        return;
    }
    char zmx[512];
    if (ft_linux_find_zmx(zmx, sizeof(zmx)) != 0) {
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {
        execl(zmx, zmx, "kill", session, (char *)NULL);
        _exit(127);
    }
}

static void release_term(const char *session, int kill_zmx) {
    FtTerm *t = term_by_session(session);
    if (!t) {
        return;
    }
    if (kill_zmx) {
        zmx_kill_session(session, t->project_path, t->zmx_path);
    }
    g_hash_table_steal(g_app->terms, session);
    ft_term_free(t);
}

static FtTerm *ensure_term(const char *session, const char *cwd, const char *zmx_path) {
    FtTerm *t = term_by_session(session);
    if (t) {
        return t;
    }
    t = ft_term_new(session, cwd, zmx_path);
    if (!t) {
        return NULL;
    }
    ft_term_apply_prefs(t, &g_app->prefs);
    t->exited_cb = on_term_exited;
    t->exited_user = NULL;
    g_hash_table_insert(g_app->terms, g_strdup(session), t);
    return t;
}

static void drop_unused_terms(void) {
    char live[256][80];
    int n = ft_model_all_sessions(g_app->model, live, 256);
    GHashTableIter it;
    gpointer key, val;
    g_hash_table_iter_init(&it, g_app->terms);
    while (g_hash_table_iter_next(&it, &key, &val)) {
        const char *sess = key;
        int keep = 0;
        for (int i = 0; i < n; i++) {
            if (strcmp(live[i], sess) == 0) {
                keep = 1;
                break;
            }
        }
        if (!keep) {
            FtTerm *t = val;
            zmx_kill_session(sess, t->project_path, t->zmx_path);
            g_hash_table_iter_remove(&it);
            ft_term_free(t);
        }
    }
}

static gboolean reconnect_idle(gpointer user) {
    (void)user;
    reconnect_dropped_remotes();
    return G_SOURCE_REMOVE;
}

static void reconnect_dropped_remotes(void) {
    if (!g_app || !g_app->terms) {
        return;
    }
    char dead[64][80];
    int n = 0;
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, g_app->terms);
    while (g_hash_table_iter_next(&it, &k, &v) && n < 64) {
        FtTerm *t = v;
        if (ft_remote_should_reattach(t->remote, t->exited)) {
            ft_str_set(dead[n], sizeof(dead[0]), (const char *)k);
            n++;
        }
    }
    if (n == 0) {
        return;
    }
    for (int i = 0; i < n; i++) {
        release_term(dead[i], 0);
    }
    sync_ui();
}

static void on_term_exited(FtTerm *term, void *user) {
    (void)user;
    if (term && term->remote) {
        g_idle_add(reconnect_idle, NULL);
    }
}

static void on_is_active(GObject *obj, GParamSpec *pspec, gpointer user) {
    (void)obj;
    (void)pspec;
    (void)user;
    if (g_app->window && gtk_window_is_active(GTK_WINDOW(g_app->window))) {
        reconnect_dropped_remotes();
    }
}

typedef struct {
    char session[80];
    char run[512];
} RunLater;

static gboolean send_run_later(gpointer user) {
    RunLater *r = user;
    FtTerm *t = term_by_session(r->session);
    if (t && r->run[0]) {
        ft_term_write(t, r->run);
        ft_term_write(t, "\n");
    }
    g_free(r);
    return G_SOURCE_REMOVE;
}

static GtkWidget *build_node(FtNode *n, FtProjectRec *proj, FtTabRec *tab) {
    if (!n) {
        return gtk_label_new("");
    }
    FtNode *view = n;
    if (tab->zoom[0]) {
        FtNode *z = ft_node_find(n, tab->zoom);
        if (z) {
            view = z;
        }
    }
    if (!view->is_split) {
        FtTerm *t = ensure_term(view->session, view->cwd[0] ? view->cwd : proj->path, proj->zmx_path);
        if (!t) {
            return gtk_label_new("failed to spawn");
        }
        if (view->run[0] && !g_hash_table_contains(g_app->sent_run, view->session)) {
            g_hash_table_add(g_app->sent_run, g_strdup(view->session));
            RunLater *r = g_new0(RunLater, 1);
            ft_str_set(r->session, sizeof(r->session), view->session);
            ft_str_set(r->run, sizeof(r->run), view->run);
            g_timeout_add(400, send_run_later, r);
        }
        return t->area;
    }
    GtkOrientation o = view->dir == FT_SPLIT_V ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL;
    GtkWidget *paned = gtk_paned_new(o);
    gtk_widget_set_hexpand(paned, TRUE);
    gtk_widget_set_vexpand(paned, TRUE);
    gtk_paned_set_start_child(GTK_PANED(paned), build_node(view->first, proj, tab));
    gtk_paned_set_end_child(GTK_PANED(paned), build_node(view->second, proj, tab));
    gtk_paned_set_resize_start_child(GTK_PANED(paned), TRUE);
    gtk_paned_set_resize_end_child(GTK_PANED(paned), TRUE);
    gtk_widget_set_visible(paned, TRUE);
    return paned;
}

static void clear_list(GtkListBox *box) {
    GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(box));
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_list_box_remove(box, child);
        child = next;
    }
}

typedef struct {
    int kind; /* 0 project, 1 tab, 2 pinned, 3 folder */
    char id[40];
    char project[40];
    int indent;
} RowRef;

static void sidebar_row(const char *label, int dim, RowRef ref) {
    GtkWidget *lab = gtk_label_new(label);
    gtk_widget_set_halign(lab, GTK_ALIGN_START);
    gtk_widget_set_margin_start(lab, ref.indent > 0 ? ref.indent : (ref.kind == 1 ? 18 : 10));
    gtk_widget_set_margin_end(lab, 10);
    gtk_widget_set_margin_top(lab, 4);
    gtk_widget_set_margin_bottom(lab, 4);
    if (dim) {
        gtk_widget_set_opacity(lab, 0.45);
    }
    gtk_list_box_append(GTK_LIST_BOX(g_app->sidebar), lab);
    RowRef *heap = g_malloc(sizeof(*heap));
    *heap = ref;
    g_object_set_data_full(G_OBJECT(gtk_widget_get_parent(lab)), "ref", heap, g_free);
}

static void add_project_rows(FtProjectRec *p, int indent) {
    RowRef pr = {.kind = 0, .indent = indent};
    ft_str_set(pr.id, sizeof(pr.id), p->id);
    sidebar_row(p->name, p->unloaded, pr);
    for (int t = 0; t < p->ntabs; t++) {
        RowRef tr = {.kind = 1, .indent = indent + 12};
        ft_str_set(tr.id, sizeof(tr.id), p->tabs[t].id);
        ft_str_set(tr.project, sizeof(tr.project), p->id);
        sidebar_row(p->tabs[t].title, p->unloaded, tr);
    }
}

static void add_folder_rows(const char *parent, int indent) {
    for (int i = 0; i < g_app->model->nfolders; i++) {
        FtFolderRec *f = &g_app->model->folders[i];
        int is_root = !parent || !parent[0];
        int match = is_root ? !f->parent[0] : strcmp(f->parent, parent) == 0;
        if (!match) {
            continue;
        }
        char lab[80];
        snprintf(lab, sizeof(lab), "%s %s", f->expanded ? "▾" : "▸", f->name);
        RowRef r = {.kind = 3, .indent = indent};
        ft_str_set(r.id, sizeof(r.id), f->id);
        sidebar_row(lab, 0, r);
        if (!f->expanded) {
            continue;
        }
        add_folder_rows(f->id, indent + 12);
        for (int p = 0; p < g_app->model->nprojects; p++) {
            if (strcmp(g_app->model->projects[p].folder_id, f->id) == 0) {
                add_project_rows(&g_app->model->projects[p], indent + 12);
            }
        }
    }
}

static int folder_known(const char *id) {
    return id && id[0] && ft_model_folder_find(g_app->model, id) != NULL;
}

static void rebuild_sidebar(void) {
    clear_list(GTK_LIST_BOX(g_app->sidebar));
    for (int i = 0; i < g_app->model->pinned.ntabs; i++) {
        FtTabRec *t = &g_app->model->pinned.tabs[i];
        char lab[80];
        snprintf(lab, sizeof(lab), "📌 %s", t->title[0] ? t->title : "Pinned");
        RowRef r = {.kind = 2};
        ft_str_set(r.id, sizeof(r.id), t->id);
        sidebar_row(lab, t->unloaded, r);
    }
    add_folder_rows("", 10);
    for (int i = 0; i < g_app->model->nprojects; i++) {
        FtProjectRec *p = &g_app->model->projects[i];
        if (folder_known(p->folder_id)) {
            continue;
        }
        add_project_rows(p, 10);
    }
}

static GtkWidget *ensure_notebook(FtProjectRec *p) {
    GtkWidget *nb = g_hash_table_lookup(g_app->notebooks, p->id);
    if (nb) {
        return nb;
    }
    nb = gtk_notebook_new();
    gtk_notebook_set_scrollable(GTK_NOTEBOOK(nb), TRUE);
    gtk_widget_set_hexpand(nb, TRUE);
    gtk_widget_set_vexpand(nb, TRUE);
    gtk_stack_add_named(GTK_STACK(g_app->stack), nb, p->id);
    g_hash_table_insert(g_app->notebooks, g_strdup(p->id), nb);
    return nb;
}

static GPtrArray *g_unparent_refs;

static void rebuild_project(FtProjectRec *p) {
    GtkWidget *nb = ensure_notebook(p);
    if (g_unparent_refs) {
        g_ptr_array_unref(g_unparent_refs);
        g_unparent_refs = NULL;
    }
    g_unparent_refs = g_ptr_array_new();
    char mine[128][80];
    int nmine = 0;
    for (int t = 0; t < p->ntabs && nmine < 128; t++) {
        int skip = p->unloaded || p->tabs[t].unloaded;
        FtNode *panes[64];
        int c = ft_node_collect(p->tabs[t].root, panes, 64);
        for (int i = 0; i < c && nmine < 128; i++) {
            if (skip) {
                release_term(panes[i]->session, 0);
                continue;
            }
            ft_str_set(mine[nmine++], 80, panes[i]->session);
        }
    }
    for (int i = 0; i < nmine; i++) {
        FtTerm *t = term_by_session(mine[i]);
        if (t && t->area) {
            g_object_ref(t->area);
            g_ptr_array_add(g_unparent_refs, t->area);
        }
    }
    while (gtk_notebook_get_n_pages(GTK_NOTEBOOK(nb)) > 0) {
        gtk_notebook_remove_page(GTK_NOTEBOOK(nb), 0);
    }
    for (int i = 0; i < nmine; i++) {
        FtTerm *t = term_by_session(mine[i]);
        if (t && t->area && gtk_widget_get_parent(t->area)) {
            gtk_widget_unparent(t->area);
        }
    }
    for (int t = 0; t < p->ntabs; t++) {
        FtTabRec *tab = &p->tabs[t];
        int skip = p->unloaded || tab->unloaded;
        GtkWidget *page = (!skip && tab->root) ? build_node(tab->root, p, tab) : gtk_label_new("(unloaded)");
        gtk_notebook_append_page(GTK_NOTEBOOK(nb), page, gtk_label_new(tab->title));
    }
    if (p->active_tab >= 0 && p->active_tab < p->ntabs) {
        gtk_notebook_set_current_page(GTK_NOTEBOOK(nb), p->active_tab);
    }
    if (g_unparent_refs) {
        for (guint i = 0; i < g_unparent_refs->len; i++) {
            g_object_unref(g_ptr_array_index(g_unparent_refs, i));
        }
        g_ptr_array_unref(g_unparent_refs);
        g_unparent_refs = NULL;
    }
}

static void sync_ui(void) {
    drop_unused_terms();
    rebuild_sidebar();
    FtProjectRec *active = ft_model_active(g_app->model);
    if (active) {
        rebuild_project(active);
        GtkWidget *nb = g_hash_table_lookup(g_app->notebooks, active->id);
        if (nb) {
            gtk_stack_set_visible_child(GTK_STACK(g_app->stack), nb);
        }
        gtk_window_set_title(GTK_WINDOW(g_app->window), active->name);
        FtTabRec *tab = ft_model_active_tab(g_app->model);
        if (tab && !tab->unloaded && !active->unloaded && tab->focus[0]) {
            FtTerm *t = term_by_session(tab->focus);
            if (t && t->area) {
                gtk_widget_grab_focus(t->area);
            }
        }
    }
    gtk_widget_set_visible(g_app->sidebar_scroll, g_app->prefs.sidebar_visible);
    ft_model_save(g_app->model);
}

static int pane_busy(void *user, const char *session) {
    (void)user;
    FtTerm *t = term_by_session(session);
    if (!t) {
        return 0;
    }
    char comm[64];
    if (ft_term_foreground(t, comm, sizeof(comm)) != 0) {
        return 0;
    }
    return !ft_is_shell_name(comm);
}

static int hook_dump(void *user, const char *session, char *out, size_t n) {
    (void)user;
    FtTerm *t = term_by_session(session);
    if (!t) {
        t = g_app->quick_term;
    }
    GString *s = g_string_new("");
    if (t) {
        ft_term_dump(t, s);
    }
    snprintf(out, n, "%s", s->str);
    g_string_free(s, TRUE);
    return 0;
}

static int hook_run(void *user, const char *session, const char *cmd) {
    (void)user;
    FtTerm *t = term_by_session(session);
    if (t && cmd) {
        ft_term_write(t, cmd);
        ft_term_write(t, "\n");
    }
    return 0;
}

static int hook_key(void *user, const char *session, const char *chord) {
    (void)user;
    FtTerm *t = term_by_session(session);
    if (t) {
        ft_term_send_chord(t, chord);
    }
    return 0;
}

static int hook_kill(void *user, const char *name) {
    (void)user;
    FtTerm *t = term_by_session(name);
    zmx_kill_session(name, t ? t->project_path : NULL, t ? t->zmx_path : NULL);
    return 0;
}

static FtControlHooks hooks(void) {
    FtControlHooks h = {0};
    h.dump = hook_dump;
    h.run = hook_run;
    h.key = hook_key;
    h.session_kill = hook_kill;
    h.busy = pane_busy;
    return h;
}

static void dispatch_json(const char *req, GString *resp) {
    FtControlReq parsed;
    if (ft_control_parse(req, &parsed) != 0) {
        g_string_append(resp, "{\"ok\":false,\"error\":{\"code\":\"bad_request\",\"message\":\"invalid json\"}}\n");
        return;
    }
    char out[131072];
    FtControlHooks h = hooks();
    ft_control_dispatch(g_app->model, &parsed, &h, out, sizeof(out));
    g_string_append(resp, out);
    if (resp->len == 0 || resp->str[resp->len - 1] != '\n') {
        g_string_append_c(resp, '\n');
    }
    const char *c = parsed.command;
    int mutate = !(
        strcmp(c, "status") == 0 || strstr(c, ".list") || strcmp(c, "pane.dump") == 0
        || strcmp(c, "session.info") == 0
    );
    if (mutate) {
        sync_ui();
    }
}

static gboolean on_control(GSocketService *service, GSocketConnection *conn, GObject *src, gpointer user) {
    (void)service;
    (void)src;
    (void)user;
    GInputStream *in = g_io_stream_get_input_stream(G_IO_STREAM(conn));
    GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(conn));
    gchar buf[65536];
    gssize n = g_input_stream_read(in, buf, sizeof(buf) - 1, NULL, NULL);
    if (n <= 0) {
        return FALSE;
    }
    buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) {
        buf[--n] = 0;
    }
    GString *resp = g_string_new("");
    if (buf[0] == '{') {
        dispatch_json(buf, resp);
    } else {
        g_string_append(resp, "{\"ok\":false,\"error\":{\"code\":\"bad_request\",\"message\":\"expected json\"}}\n");
    }
    g_output_stream_write_all(out, resp->str, resp->len, NULL, NULL, NULL);
    g_string_free(resp, TRUE);
    return FALSE;
}

static void start_control(void) {
    const char *env = getenv("FUTURATERM_SOCKET");
    if (env && env[0]) {
        snprintf(g_app->socket_path, sizeof(g_app->socket_path), "%s", env);
        char dir[256];
        snprintf(dir, sizeof(dir), "%s", env);
        char *slash = strrchr(dir, '/');
        if (slash) {
            *slash = 0;
            ft_mkdir_p(dir);
        }
    } else {
        char runtime[256];
        ft_xdg_runtime(runtime, sizeof(runtime));
        char dir[300];
        snprintf(dir, sizeof(dir), "%s/futuraterm", runtime);
        ft_mkdir_p(dir);
        snprintf(g_app->socket_path, sizeof(g_app->socket_path), "%s/control.sock", dir);
    }
    unlink(g_app->socket_path);
    GError *err = NULL;
    g_app->service = g_socket_service_new();
    GSocketAddress *addr = g_unix_socket_address_new(g_app->socket_path);
    if (!g_socket_listener_add_address(G_SOCKET_LISTENER(g_app->service), addr, G_SOCKET_TYPE_STREAM, G_SOCKET_PROTOCOL_DEFAULT, NULL, NULL, &err)) {
        fprintf(stderr, "control socket: %s\n", err ? err->message : "failed");
        g_clear_error(&err);
    } else {
        g_signal_connect(g_app->service, "incoming", G_CALLBACK(on_control), NULL);
        g_socket_service_start(g_app->service);
        chmod(g_app->socket_path, 0600);
    }
    g_object_unref(addr);
}

static void on_sidebar_row(GtkListBox *box, GtkListBoxRow *row, gpointer user) {
    (void)box;
    (void)user;
    if (!row) {
        return;
    }
    RowRef *ref = g_object_get_data(G_OBJECT(row), "ref");
    if (!ref) {
        return;
    }
    if (ref->kind == 0) {
        ft_model_project_select(g_app->model, ref->id);
    } else if (ref->kind == 2) {
        ft_model_project_select(g_app->model, "pinned");
        ft_model_tab_select(g_app->model, ref->id);
    } else if (ref->kind == 3) {
        FtFolderRec *f = ft_model_folder_find(g_app->model, ref->id);
        if (f) {
            f->expanded = !f->expanded;
            ft_model_set_add_folder(g_app->model, f->id);
        }
        rebuild_sidebar();
        return;
    } else {
        ft_model_project_select(g_app->model, ref->project);
        ft_model_tab_select(g_app->model, ref->id);
    }
    sync_ui();
}

static void go_close_pane(void) {
    FtNode *n = ft_model_focused_pane(g_app->model);
    if (n) {
        ft_model_close_pane(g_app->model, n->session, 1, NULL, NULL);
        sync_ui();
    }
}

static void go_close_tab(void) {
    FtTabRec *t = ft_model_active_tab(g_app->model);
    if (t) {
        ft_model_tab_close(g_app->model, t->id, 1, NULL, NULL);
        sync_ui();
    }
}

static void (*g_prompt_fn)(const char *);

static void prompt_ok(GtkButton *b, gpointer user) {
    (void)user;
    GtkEntry *e = g_object_get_data(G_OBJECT(b), "entry");
    GtkWidget *w = g_object_get_data(G_OBJECT(b), "win");
    if (g_prompt_fn) {
        g_prompt_fn(gtk_editable_get_text(GTK_EDITABLE(e)));
    }
    gtk_window_destroy(GTK_WINDOW(w));
}

static int have_on_path(const char *name) {
    char *found = g_find_program_in_path(name);
    int ok = found != NULL;
    g_free(found);
    return ok;
}

static void show_note(const char *title, const char *msg) {
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), title);
    gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(g_app->window));
    gtk_window_set_modal(GTK_WINDOW(win), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(win), 420, 120);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    GtkWidget *lab = gtk_label_new(msg);
    gtk_label_set_wrap(GTK_LABEL(lab), TRUE);
    gtk_box_append(GTK_BOX(box), lab);
    GtkWidget *ok = gtk_button_new_with_label("OK");
    gtk_box_append(GTK_BOX(box), ok);
    gtk_window_set_child(GTK_WINDOW(win), box);
    g_signal_connect_swapped(ok, "clicked", G_CALLBACK(gtk_window_destroy), win);
    gtk_window_present(GTK_WINDOW(win));
}

static void view_desktop(void) {
    FtProjectRec *p = ft_model_active(g_app->model);
    if (!p || !ft_path_is_remote(p->path)) {
        show_note("View Desktop", FT_DESKTOP_NOT_REMOTE);
        return;
    }
    FtProjectPath parsed;
    if (ft_path_parse(p->path, &parsed) != 0 || !parsed.host[0]) {
        show_note("View Desktop", FT_DESKTOP_NOT_REMOTE);
        return;
    }
    int moon = have_on_path("moonlight-qt") || have_on_path("moonlight");
    int vnc = have_on_path("vncviewer") || have_on_path("xtigervncviewer") || have_on_path("remmina");
    FtDesktopPlan plan;
    ft_desktop_plan(parsed.host, NULL, moon, vnc, &plan);
    if (plan.kind == FT_DESKTOP_MISSING) {
        show_note("View Desktop", plan.reason);
        return;
    }
    pid_t pid = fork();
    if (pid != 0) {
        return;
    }
    if (plan.kind == FT_DESKTOP_MOONLIGHT) {
        const char *args[4];
        if (ft_desktop_moonlight_argv(plan.host, args, 4) != 3) {
            _exit(127);
        }
        execlp("moonlight-qt", "moonlight-qt", args[0], args[1], args[2], (char *)NULL);
        execlp("moonlight", "moonlight", args[0], args[1], args[2], (char *)NULL);
        _exit(127);
    }
    execlp("vncviewer", "vncviewer", plan.host, (char *)NULL);
    execlp("xtigervncviewer", "xtigervncviewer", plan.host, (char *)NULL);
    execlp("remmina", "remmina", plan.host, (char *)NULL);
    _exit(127);
}

static void prompt_text2(const char *title, const char *initial, void (*done)(const char *)) {
    g_prompt_fn = done;
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), title);
    gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(g_app->window));
    gtk_window_set_modal(GTK_WINDOW(win), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(win), 360, 80);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    GtkWidget *entry = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(entry), initial ? initial : "");
    gtk_box_append(GTK_BOX(box), entry);
    GtkWidget *ok = gtk_button_new_with_label("OK");
    gtk_box_append(GTK_BOX(box), ok);
    gtk_window_set_child(GTK_WINDOW(win), box);
    g_object_set_data(G_OBJECT(ok), "entry", entry);
    g_object_set_data(G_OBJECT(ok), "win", win);
    g_signal_connect(ok, "clicked", G_CALLBACK(prompt_ok), NULL);
    gtk_window_present(GTK_WINDOW(win));
}

static void finish_rename_tab(const char *s) {
    ft_model_tab_rename(g_app->model, s);
    sync_ui();
}

static void finish_rename_project(const char *s) {
    ft_model_project_rename(g_app->model, s);
    sync_ui();
}

static void finish_remote(const char *spec) {
    if (spec && spec[0]) {
        ft_model_add_remote(g_app->model, spec);
        sync_ui();
    }
}

static void finish_new_folder(const char *name) {
    if (!name || !name[0]) {
        return;
    }
    const char *parent = g_app->model->add_folder[0] ? g_app->model->add_folder : NULL;
    char id[40];
    if (ft_model_folder_create(g_app->model, name, parent, id, sizeof(id)) == 0) {
        ft_model_set_add_folder(g_app->model, id);
        sync_ui();
    }
}

static void on_open_folder(GObject *src, GAsyncResult *res, gpointer user) {
    (void)user;
    GError *err = NULL;
    GFile *f = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(src), res, &err);
    if (!f) {
        g_clear_error(&err);
        return;
    }
    char *path = g_file_get_path(f);
    if (path) {
        ft_model_add_local(g_app->model, path);
        sync_ui();
        g_free(path);
    }
    g_object_unref(f);
}

static void open_project_dialog(void) {
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, "Local Folder…");
    gtk_file_dialog_select_folder(d, GTK_WINDOW(g_app->window), NULL, on_open_folder, NULL);
}

static void on_new_folder_clicked(GtkButton *b, gpointer user) {
    (void)b;
    (void)user;
    prompt_text2("New Folder", "", finish_new_folder);
}

static void on_remote_machine_clicked(GtkButton *b, gpointer user) {
    (void)b;
    (void)user;
    prompt_text2("Remote Machine…", "", finish_remote);
}

static GtkWidget *new_project_control(void) {
    GtkWidget *btn = gtk_menu_button_new();
    gtk_menu_button_set_label(GTK_MENU_BUTTON(btn), "New Project");
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_margin_start(box, 6);
    gtk_widget_set_margin_end(box, 6);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);
    GtkWidget *local = gtk_button_new_with_label("Local Folder…");
    GtkWidget *remote = gtk_button_new_with_label("Remote Machine…");
    GtkWidget *folder = gtk_button_new_with_label("New Folder");
    gtk_button_set_has_frame(GTK_BUTTON(local), FALSE);
    gtk_button_set_has_frame(GTK_BUTTON(remote), FALSE);
    gtk_button_set_has_frame(GTK_BUTTON(folder), FALSE);
    gtk_widget_set_halign(local, GTK_ALIGN_START);
    gtk_widget_set_halign(remote, GTK_ALIGN_START);
    gtk_widget_set_halign(folder, GTK_ALIGN_START);
    g_signal_connect(local, "clicked", G_CALLBACK(clicked_action), "openProject");
    g_signal_connect(remote, "clicked", G_CALLBACK(on_remote_machine_clicked), NULL);
    g_signal_connect(folder, "clicked", G_CALLBACK(on_new_folder_clicked), NULL);
    gtk_box_append(GTK_BOX(box), local);
    gtk_box_append(GTK_BOX(box), remote);
    gtk_box_append(GTK_BOX(box), folder);
    GtkWidget *pop = gtk_popover_new();
    gtk_popover_set_child(GTK_POPOVER(pop), box);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(btn), pop);
    return btn;
}

static void show_sessions(void) {
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "Sessions");
    gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(g_app->window));
    gtk_window_set_default_size(GTK_WINDOW(win), 420, 320);
    GtkWidget *sc = gtk_scrolled_window_new();
    GtkWidget *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_start(list, 12);
    gtk_widget_set_margin_end(list, 12);
    gtk_widget_set_margin_top(list, 12);
    char sessions[128][80];
    int n = ft_model_all_sessions(g_app->model, sessions, 128);
    if (n == 0) {
        gtk_box_append(GTK_BOX(list), gtk_label_new("No sessions"));
    }
    for (int i = 0; i < n; i++) {
        gtk_box_append(GTK_BOX(list), gtk_label_new(sessions[i]));
    }
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), list);
    gtk_window_set_child(GTK_WINDOW(win), sc);
    gtk_window_present(GTK_WINDOW(win));
}

static void run_action(const char *id) {
    FtNode *pane = ft_model_focused_pane(g_app->model);
    const char *sess = pane ? pane->session : "";
    if (strcmp(id, "newTab") == 0) {
        ft_model_tab_new(g_app->model, NULL, NULL, NULL, 0);
    } else if (strcmp(id, "closePane") == 0) {
        if (pane && pane_busy(NULL, sess)) {
            confirm_busy_then("Close this pane?", go_close_pane);
            return;
        }
        go_close_pane();
        return;
    } else if (strcmp(id, "closeTab") == 0) {
        confirm_busy_then("Close this tab?", go_close_tab);
        return;
    } else if (strcmp(id, "renameTab") == 0) {
        FtTabRec *t = ft_model_active_tab(g_app->model);
        prompt_text2("Rename Tab", t ? t->title : "", finish_rename_tab);
        return;
    } else if (strcmp(id, "nextTab") == 0) {
        ft_model_tab_cycle(g_app->model, 1, 0);
    } else if (strcmp(id, "previousTab") == 0) {
        ft_model_tab_cycle(g_app->model, -1, 0);
    } else if (strcmp(id, "nextTabInProject") == 0) {
        ft_model_tab_cycle(g_app->model, 1, 1);
    } else if (strcmp(id, "previousTabInProject") == 0) {
        ft_model_tab_cycle(g_app->model, -1, 1);
    } else if (strcmp(id, "recentTab") == 0) {
        ft_model_tab_recent(g_app->model);
    } else if (strcmp(id, "separateAllPanes") == 0) {
        ft_model_separate_all(g_app->model);
    } else if (strcmp(id, "pinTab") == 0) {
        ft_model_pin(g_app->model);
    } else if (strcmp(id, "unpinTab") == 0) {
        ft_model_unpin(g_app->model);
    } else if (strcmp(id, "splitRight") == 0) {
        ft_model_split(g_app->model, sess, "right", NULL, NULL, 0);
    } else if (strcmp(id, "splitDown") == 0) {
        ft_model_split(g_app->model, sess, "down", NULL, NULL, 0);
    } else if (strcmp(id, "splitAuto") == 0) {
        ft_model_split(g_app->model, sess, "auto", NULL, NULL, 0);
    } else if (strcmp(id, "separateCurrentPane") == 0) {
        ft_model_separate_pane(g_app->model, sess);
    } else if (strcmp(id, "zoomPane") == 0) {
        ft_model_zoom(g_app->model, sess);
    } else if (strcmp(id, "focusLeft") == 0) {
        ft_model_focus(g_app->model, sess, "left");
    } else if (strcmp(id, "focusRight") == 0) {
        ft_model_focus(g_app->model, sess, "right");
    } else if (strcmp(id, "focusUp") == 0) {
        ft_model_focus(g_app->model, sess, "up");
    } else if (strcmp(id, "focusDown") == 0) {
        ft_model_focus(g_app->model, sess, "down");
    } else if (strcmp(id, "nextPane") == 0) {
        ft_model_focus(g_app->model, sess, "next");
    } else if (strcmp(id, "previousPane") == 0) {
        ft_model_focus(g_app->model, sess, "previous");
    } else if (strcmp(id, "resizeLeft") == 0) {
        ft_model_resize(g_app->model, sess, FT_DIR_LEFT, 0.05);
    } else if (strcmp(id, "resizeRight") == 0) {
        ft_model_resize(g_app->model, sess, FT_DIR_RIGHT, 0.05);
    } else if (strcmp(id, "resizeUp") == 0) {
        ft_model_resize(g_app->model, sess, FT_DIR_UP, 0.05);
    } else if (strcmp(id, "resizeDown") == 0) {
        ft_model_resize(g_app->model, sess, FT_DIR_DOWN, 0.05);
    } else if (strcmp(id, "copySessionID") == 0 && pane) {
        gdk_clipboard_set_text(gtk_widget_get_clipboard(g_app->window), pane->session);
    } else if (strcmp(id, "copy") == 0 || strcmp(id, "cut") == 0) {
        FtTerm *t = pane ? term_by_session(pane->session) : NULL;
        if (!t && g_app->quick_term) {
            t = g_app->quick_term;
        }
        if (t) {
            char buf[65536];
            if (ft_term_copy_selection(t, buf, sizeof(buf)) > 0) {
                gdk_clipboard_set_text(gtk_widget_get_clipboard(g_app->window), buf);
            }
        }
        return;
    } else if (strcmp(id, "paste") == 0) {
        FtTerm *t = pane ? term_by_session(pane->session) : NULL;
        if (!t && g_app->quick_term) {
            t = g_app->quick_term;
        }
        if (t) {
            ft_term_request_paste(t);
        }
        return;
    } else if (strcmp(id, "selectAll") == 0) {
        FtTerm *t = pane ? term_by_session(pane->session) : NULL;
        if (!t && g_app->quick_term) {
            t = g_app->quick_term;
        }
        if (t) {
            ft_term_select_all(t);
        }
        return;
    } else if (strcmp(id, "openProject") == 0) {
        open_project_dialog();
        return;
    } else if (strcmp(id, "newRemoteProject") == 0) {
        prompt_text2("Remote project ([user@]host:dir)", "", finish_remote);
        return;
    } else if (strcmp(id, "viewDesktop") == 0) {
        view_desktop();
        return;
    } else if (strcmp(id, "renameProject") == 0) {
        FtProjectRec *p = ft_model_active(g_app->model);
        prompt_text2("Rename Project", p ? p->name : "", finish_rename_project);
        return;
    } else if (strcmp(id, "unloadProject") == 0) {
        ft_model_project_unload(g_app->model, NULL);
    } else if (strcmp(id, "removeProject") == 0) {
        ft_model_project_remove(g_app->model, NULL);
    } else if (strcmp(id, "applyLayout") == 0) {
        ft_model_apply_layout(g_app->model, NULL, 1);
    } else if (strcmp(id, "saveLayout") == 0) {
        char written[512];
        ft_model_save_layout(g_app->model, NULL, written, sizeof(written));
    } else if (strcmp(id, "nextProject") == 0) {
        if (g_app->model->nprojects) {
            int i = g_app->model->active + 1;
            if (i >= g_app->model->nprojects) {
                i = 0;
            }
            g_app->model->active = i;
        }
    } else if (strcmp(id, "previousProject") == 0) {
        if (g_app->model->nprojects) {
            int i = g_app->model->active - 1;
            if (i < 0) {
                i = g_app->model->nprojects - 1;
            }
            g_app->model->active = i;
        }
    } else if (strcmp(id, "toggleSidebar") == 0) {
        g_app->prefs.sidebar_visible = !g_app->prefs.sidebar_visible;
    } else if (strcmp(id, "closeWindow") == 0) {
        gtk_widget_set_visible(g_app->window, FALSE);
        return;
    } else if (strcmp(id, "toggleCommandPalette") == 0) {
        show_palette();
        return;
    } else if (strcmp(id, "manageSessions") == 0) {
        show_sessions();
        return;
    } else if (strcmp(id, "reloadGhosttyConfig") == 0) {
        ft_ghostty_load_default_files(&g_app->prefs);
        GHashTableIter it;
        gpointer k, v;
        g_hash_table_iter_init(&it, g_app->terms);
        while (g_hash_table_iter_next(&it, &k, &v)) {
            ft_term_apply_prefs(v, &g_app->prefs);
        }
    } else if (strcmp(id, "toggleQuickTerminal") == 0) {
        toggle_quick();
        return;
    }
    sync_ui();
}

static void (*g_confirm_go)(void);

static void confirm_ok(GtkButton *b, gpointer user) {
    (void)b;
    GtkWidget *w = user;
    if (g_confirm_go) {
        g_confirm_go();
    }
    gtk_window_destroy(GTK_WINDOW(w));
}

static void confirm_busy_then(const char *what, void (*go)(void)) {
    int any = 0;
    FtTabRec *t = ft_model_active_tab(g_app->model);
    if (t) {
        FtNode *panes[64];
        int n = ft_node_collect(t->root, panes, 64);
        for (int i = 0; i < n; i++) {
            if (pane_busy(NULL, panes[i]->session)) {
                any = 1;
            }
        }
    }
    if (!any) {
        go();
        return;
    }
    g_confirm_go = go;
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "Running program");
    gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(g_app->window));
    gtk_window_set_modal(GTK_WINDOW(win), TRUE);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    gtk_box_append(GTK_BOX(box), gtk_label_new(what));
    GtkWidget *ok = gtk_button_new_with_label("Close Anyway");
    gtk_box_append(GTK_BOX(box), ok);
    gtk_window_set_child(GTK_WINDOW(win), box);
    g_signal_connect(ok, "clicked", G_CALLBACK(confirm_ok), win);
    gtk_window_present(GTK_WINDOW(win));
}

static void palette_refresh(void) {
    const char *q = gtk_editable_get_text(GTK_EDITABLE(g_app->palette_entry));
    g_app->npalette = ft_command_filter(q, g_app->palette_hits, 64);
    GtkWidget *child = gtk_widget_get_first_child(g_app->palette_list);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_list_box_remove(GTK_LIST_BOX(g_app->palette_list), child);
        child = next;
    }
    int n = 0;
    const FtCommand *cmds = ft_commands(&n);
    for (int i = 0; i < g_app->npalette; i++) {
        const FtCommand *c = &cmds[g_app->palette_hits[i]];
        char lab[160];
        snprintf(lab, sizeof(lab), "%s — %s", c->title, c->help);
        GtkWidget *row = gtk_label_new(lab);
        gtk_widget_set_halign(row, GTK_ALIGN_START);
        gtk_list_box_append(GTK_LIST_BOX(g_app->palette_list), row);
    }
}

static void palette_activate(GtkListBox *box, GtkListBoxRow *row, gpointer user) {
    (void)box;
    (void)user;
    if (!row) {
        return;
    }
    int i = gtk_list_box_row_get_index(row);
    if (i < 0 || i >= g_app->npalette) {
        return;
    }
    int n = 0;
    const FtCommand *cmds = ft_commands(&n);
    const char *id = cmds[g_app->palette_hits[i]].id;
    gtk_widget_set_visible(g_app->palette_win, FALSE);
    run_action(id);
}

static void show_palette(void) {
    if (!g_app->palette_win) {
        g_app->palette_win = gtk_window_new();
        gtk_window_set_title(GTK_WINDOW(g_app->palette_win), "Command Palette");
        gtk_window_set_transient_for(GTK_WINDOW(g_app->palette_win), GTK_WINDOW(g_app->window));
        gtk_window_set_default_size(GTK_WINDOW(g_app->palette_win), 520, 360);
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        g_app->palette_entry = gtk_entry_new();
        gtk_entry_set_placeholder_text(GTK_ENTRY(g_app->palette_entry), "Filter commands");
        g_signal_connect_swapped(g_app->palette_entry, "changed", G_CALLBACK(palette_refresh), NULL);
        gtk_box_append(GTK_BOX(box), g_app->palette_entry);
        GtkWidget *sc = gtk_scrolled_window_new();
        gtk_widget_set_vexpand(sc, TRUE);
        g_app->palette_list = gtk_list_box_new();
        g_signal_connect(g_app->palette_list, "row-activated", G_CALLBACK(palette_activate), NULL);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), g_app->palette_list);
        gtk_box_append(GTK_BOX(box), sc);
        gtk_window_set_child(GTK_WINDOW(g_app->palette_win), box);
    }
    gtk_editable_set_text(GTK_EDITABLE(g_app->palette_entry), "");
    palette_refresh();
    gtk_window_present(GTK_WINDOW(g_app->palette_win));
    gtk_widget_grab_focus(g_app->palette_entry);
}

static void prefs_save_and_apply(void) {
    char path[768];
    snprintf(path, sizeof(path), "%s/linux-prefs", g_app->config_dir);
    ft_mkdir_p(g_app->config_dir);
    ft_prefs_save(path, &g_app->prefs);
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, g_app->terms);
    while (g_hash_table_iter_next(&it, &k, &v)) {
        ft_term_apply_prefs(v, &g_app->prefs);
    }
    sync_ui();
}

static GtkWidget *caption(const char *s) {
    GtkWidget *l = gtk_label_new(s);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_widget_set_halign(l, GTK_ALIGN_START);
    gtk_widget_add_css_class(l, "dim-label");
    return l;
}

static void toggle_sidebar_pref(GtkCheckButton *b, gpointer user) {
    (void)user;
    g_app->prefs.sidebar_visible = gtk_check_button_get_active(b);
    prefs_save_and_apply();
}

static void toggle_autoname(GtkCheckButton *b, gpointer user) {
    (void)user;
    g_app->prefs.auto_name_tabs = gtk_check_button_get_active(b);
    prefs_save_and_apply();
}

static void opacity_changed(GtkRange *r, gpointer user) {
    (void)user;
    g_app->prefs.window_opacity = gtk_range_get_value(r);
    prefs_save_and_apply();
}

static void show_prefs(void) {
    if (g_app->prefs_win) {
        gtk_window_present(GTK_WINDOW(g_app->prefs_win));
        return;
    }
    g_app->prefs_win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(g_app->prefs_win), "Settings");
    gtk_window_set_default_size(GTK_WINDOW(g_app->prefs_win), 720, 480);
    gtk_window_set_transient_for(GTK_WINDOW(g_app->prefs_win), GTK_WINDOW(g_app->window));
    GtkWidget *split = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *side = gtk_stack_sidebar_new();
    GtkWidget *stack = gtk_stack_new();
    gtk_stack_sidebar_set_stack(GTK_STACK_SIDEBAR(side), GTK_STACK(stack));
    gtk_widget_set_size_request(side, 160, -1);
    gtk_box_append(GTK_BOX(split), side);
    gtk_widget_set_hexpand(stack, TRUE);
    gtk_box_append(GTK_BOX(split), stack);

    /* General */
    GtkWidget *general = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(general, 16);
    gtk_widget_set_margin_end(general, 16);
    gtk_widget_set_margin_top(general, 16);
    GtkWidget *auto_name = gtk_check_button_new_with_label("Name tabs after the foreground process");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(auto_name), g_app->prefs.auto_name_tabs);
    g_signal_connect(auto_name, "toggled", G_CALLBACK(toggle_autoname), NULL);
    gtk_box_append(GTK_BOX(general), auto_name);
    gtk_box_append(GTK_BOX(general), caption("When off, tabs keep a static title until you rename them."));
    gtk_stack_add_titled(GTK_STACK(stack), general, "general", "General");

    /* Projects */
    GtkWidget *projects = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(projects, 16);
    gtk_widget_set_margin_end(projects, 16);
    gtk_widget_set_margin_top(projects, 16);
    gtk_box_append(GTK_BOX(projects), gtk_label_new("Open, rename, unload, and remove projects from the sidebar or palette."));
    GtkWidget *add = gtk_button_new_with_label("Open Project");
    g_signal_connect_swapped(add, "clicked", G_CALLBACK(open_project_dialog), NULL);
    gtk_box_append(GTK_BOX(projects), add);
    GtkWidget *remote = gtk_button_new_with_label("New Remote Project");
    g_signal_connect(remote, "clicked", G_CALLBACK(clicked_action), "newRemoteProject");
    gtk_box_append(GTK_BOX(projects), remote);
    gtk_stack_add_titled(GTK_STACK(stack), projects, "projects", "Projects");

    /* Appearance */
    GtkWidget *appn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(appn, 16);
    gtk_widget_set_margin_end(appn, 16);
    gtk_widget_set_margin_top(appn, 16);
    GtkWidget *side_tog = gtk_check_button_new_with_label("Show sidebar");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(side_tog), g_app->prefs.sidebar_visible);
    g_signal_connect(side_tog, "toggled", G_CALLBACK(toggle_sidebar_pref), NULL);
    gtk_box_append(GTK_BOX(appn), side_tog);
    char fontlab[160];
    snprintf(fontlab, sizeof(fontlab), "Font from Ghostty config: %s %d", g_app->prefs.font, g_app->prefs.font_size);
    gtk_box_append(GTK_BOX(appn), gtk_label_new(fontlab));
    gtk_box_append(GTK_BOX(appn), caption("XDG ghostty/config and config.ghostty set font, palette, and background."));
    GtkWidget *op = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.4, 1.0, 0.05);
    gtk_range_set_value(GTK_RANGE(op), g_app->prefs.window_opacity);
    g_signal_connect(op, "value-changed", G_CALLBACK(opacity_changed), NULL);
    gtk_box_append(GTK_BOX(appn), gtk_label_new("Window opacity"));
    gtk_box_append(GTK_BOX(appn), op);
    gtk_stack_add_titled(GTK_STACK(stack), appn, "appearance", "Appearance");

    /* Quick Terminal */
    GtkWidget *qt = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(qt, 16);
    gtk_widget_set_margin_end(qt, 16);
    gtk_widget_set_margin_top(qt, 16);
    char qh[160];
    snprintf(qh, sizeof(qh), "Hotkey: %s (in-app). Bind the same chord in Hyprland for a global grab.", g_app->prefs.quick_hotkey);
    gtk_box_append(GTK_BOX(qt), gtk_label_new(qh));
    gtk_box_append(GTK_BOX(qt), caption("The overlay is a scratch session. It does not replace workspace panes."));
    GtkWidget *qbtn = gtk_button_new_with_label("Toggle Quick Terminal");
    g_signal_connect_swapped(qbtn, "clicked", G_CALLBACK(toggle_quick), NULL);
    gtk_box_append(GTK_BOX(qt), qbtn);
    gtk_stack_add_titled(GTK_STACK(stack), qt, "quick", "Quick Terminal");

    /* Keymaps */
    GtkWidget *keys_sc = gtk_scrolled_window_new();
    GtkWidget *keys = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_start(keys, 16);
    gtk_widget_set_margin_end(keys, 16);
    gtk_widget_set_margin_top(keys, 16);
    int n = 0;
    const FtCommand *cmds = ft_commands(&n);
    for (int i = 0; i < n; i++) {
        char row[192];
        snprintf(row, sizeof(row), "%s  —  %s", cmds[i].title, ft_prefs_shortcut(&g_app->prefs, cmds[i].id));
        gtk_box_append(GTK_BOX(keys), gtk_label_new(row));
    }
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(keys_sc), keys);
    gtk_stack_add_titled(GTK_STACK(stack), keys_sc, "keymaps", "Keymaps");

    gtk_window_set_child(GTK_WINDOW(g_app->prefs_win), split);
    gtk_window_present(GTK_WINDOW(g_app->prefs_win));
}

static void toggle_quick(void) {
    if (g_app->quick_win && gtk_widget_get_visible(g_app->quick_win)) {
        gtk_widget_set_visible(g_app->quick_win, FALSE);
        return;
    }
    if (!g_app->quick_win) {
        g_app->quick_win = gtk_window_new();
        gtk_window_set_title(GTK_WINDOW(g_app->quick_win), "Quick Terminal");
        gtk_window_set_default_size(GTK_WINDOW(g_app->quick_win), 720, 280);
        gtk_window_set_transient_for(GTK_WINDOW(g_app->quick_win), GTK_WINDOW(g_app->window));
        g_app->quick_term = ft_term_new("futuraterm-quick", getenv("HOME"), NULL);
        if (g_app->quick_term) {
            ft_term_apply_prefs(g_app->quick_term, &g_app->prefs);
            gtk_window_set_child(GTK_WINDOW(g_app->quick_win), g_app->quick_term->area);
        }
    }
    gtk_window_present(GTK_WINDOW(g_app->quick_win));
}

static gboolean parse_shortcut(const char *s, guint *key, GdkModifierType *mods) {
    *key = 0;
    *mods = 0;
    if (!s || strcmp(s, "none") == 0 || !s[0]) {
        return FALSE;
    }
    char buf[64];
    snprintf(buf, sizeof(buf), "%s", s);
    char *save = NULL;
    for (char *tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
        if (ft_str_ieq(tok, "super") || ft_str_ieq(tok, "cmd") || ft_str_ieq(tok, "meta")) {
            *mods |= GDK_SUPER_MASK;
        } else if (ft_str_ieq(tok, "ctrl") || ft_str_ieq(tok, "control")) {
            *mods |= GDK_CONTROL_MASK;
        } else if (ft_str_ieq(tok, "shift")) {
            *mods |= GDK_SHIFT_MASK;
        } else if (ft_str_ieq(tok, "alt") || ft_str_ieq(tok, "opt")) {
            *mods |= GDK_ALT_MASK;
        } else if (ft_str_ieq(tok, "t")) {
            *key = GDK_KEY_t;
        } else if (ft_str_ieq(tok, "w")) {
            *key = GDK_KEY_w;
        } else if (ft_str_ieq(tok, "d")) {
            *key = GDK_KEY_d;
        } else if (ft_str_ieq(tok, "o")) {
            *key = GDK_KEY_o;
        } else if (ft_str_ieq(tok, "p")) {
            *key = GDK_KEY_p;
        } else if (ft_str_ieq(tok, "r")) {
            *key = GDK_KEY_r;
        } else if (ft_str_ieq(tok, "h")) {
            *key = GDK_KEY_h;
        } else if (ft_str_ieq(tok, "j")) {
            *key = GDK_KEY_j;
        } else if (ft_str_ieq(tok, "k")) {
            *key = GDK_KEY_k;
        } else if (ft_str_ieq(tok, "l")) {
            *key = GDK_KEY_l;
        } else if (ft_str_ieq(tok, "tab")) {
            *key = GDK_KEY_Tab;
        } else if (ft_str_ieq(tok, "return") || ft_str_ieq(tok, "enter")) {
            *key = GDK_KEY_Return;
        } else if (ft_str_ieq(tok, "grave") || strcmp(tok, "`") == 0) {
            *key = GDK_KEY_grave;
        } else if (ft_str_ieq(tok, "backslash") || strcmp(tok, "\\") == 0) {
            *key = GDK_KEY_backslash;
        } else if (strcmp(tok, "]") == 0) {
            *key = GDK_KEY_bracketright;
        } else if (strcmp(tok, "[") == 0) {
            *key = GDK_KEY_bracketleft;
        } else if (ft_str_ieq(tok, "comma")) {
            *key = GDK_KEY_comma;
        } else if (strlen(tok) == 1) {
            *key = gdk_unicode_to_keyval((gunichar)tok[0]);
        }
    }
    return *key != 0;
}

typedef struct {
    char id[40];
} ShortcutData;

static gboolean shortcut_fire(GtkWidget *w, GVariant *args, gpointer user) {
    (void)w;
    (void)args;
    ShortcutData *d = user;
    run_action(d->id);
    return TRUE;
}

static void add_shortcuts(GtkWidget *widget) {
    int n = 0;
    const FtCommand *cmds = ft_commands(&n);
    for (int i = 0; i < n; i++) {
        guint key = 0;
        GdkModifierType mods = 0;
        const char *sc = ft_prefs_shortcut(&g_app->prefs, cmds[i].id);
        if (!parse_shortcut(sc, &key, &mods)) {
            continue;
        }
        GtkEventController *ctl = gtk_shortcut_controller_new();
        gtk_shortcut_controller_set_scope(GTK_SHORTCUT_CONTROLLER(ctl), GTK_SHORTCUT_SCOPE_GLOBAL);
        ShortcutData *d = g_new0(ShortcutData, 1);
        ft_str_set(d->id, sizeof(d->id), cmds[i].id);
        GtkShortcut *s = gtk_shortcut_new(gtk_keyval_trigger_new(key, mods), gtk_callback_action_new(shortcut_fire, d, g_free));
        gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(ctl), s);
        gtk_widget_add_controller(widget, ctl);
    }
}

static gboolean poll_titles(gpointer user) {
    (void)user;
    if (!g_app->prefs.auto_name_tabs) {
        return G_SOURCE_CONTINUE;
    }
    FtProjectRec *p = ft_model_active(g_app->model);
    if (!p) {
        return G_SOURCE_CONTINUE;
    }
    int changed = 0;
    for (int t = 0; t < p->ntabs; t++) {
        FtTabRec *tab = &p->tabs[t];
        if (tab->custom_title || !tab->focus[0]) {
            continue;
        }
        FtTerm *term = term_by_session(tab->focus);
        char comm[64];
        if (term && ft_term_foreground(term, comm, sizeof(comm)) == 0 && comm[0] && strcmp(tab->title, comm) != 0) {
            ft_str_set(tab->title, sizeof(tab->title), comm);
            changed = 1;
        }
    }
    if (changed) {
        rebuild_sidebar();
    }
    return G_SOURCE_CONTINUE;
}

static gboolean on_close(GtkWindow *w, gpointer user) {
    (void)user;
    /* Detach: destroy widgets (SIGHUP attach clients) but do not zmx kill. */
    gtk_window_destroy(w);
    return FALSE;
}

static void clicked_action(GtkButton *b, gpointer user) {
    (void)b;
    run_action(user);
}

static void clicked_settings(GtkButton *b, gpointer user) {
    (void)b;
    (void)user;
    show_prefs();
}

static void on_activate(GtkApplication *gtkapp, gpointer user) {
    (void)user;
    if (g_app->window) {
        gtk_window_present(GTK_WINDOW(g_app->window));
        return;
    }
    g_app->window = gtk_application_window_new(gtkapp);
    gtk_window_set_title(GTK_WINDOW(g_app->window), "FuturaTerm");
    gtk_window_set_default_size(GTK_WINDOW(g_app->window), 1100, 700);
    gtk_window_set_icon_name(GTK_WINDOW(g_app->window), "com.davidsolheim.futuraterm");
    g_signal_connect(g_app->window, "close-request", G_CALLBACK(on_close), NULL);

    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_window_set_child(GTK_WINDOW(g_app->window), outer);

    GtkWidget *bar = gtk_header_bar_new();
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(bar), gtk_label_new("FuturaTerm"));
    GtkWidget *new_tab = gtk_button_new_with_label("New Tab");
    GtkWidget *split = gtk_button_new_with_label("Split");
    GtkWidget *palette = gtk_button_new_with_label("Palette");
    GtkWidget *settings = gtk_button_new_with_label("Settings");
    g_signal_connect(new_tab, "clicked", G_CALLBACK(clicked_action), "newTab");
    g_signal_connect(split, "clicked", G_CALLBACK(clicked_action), "splitRight");
    g_signal_connect(palette, "clicked", G_CALLBACK(clicked_action), "toggleCommandPalette");
    g_signal_connect(settings, "clicked", G_CALLBACK(clicked_settings), NULL);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), new_tab);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), split);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(bar), settings);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(bar), palette);
    gtk_window_set_titlebar(GTK_WINDOW(g_app->window), bar);

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(body, TRUE);
    gtk_box_append(GTK_BOX(outer), body);

    GtkWidget *side_col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(side_col, 220, -1);
    GtkWidget *chrome = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_margin_start(chrome, 6);
    gtk_widget_set_margin_end(chrome, 6);
    gtk_widget_set_margin_top(chrome, 6);
    gtk_widget_set_margin_bottom(chrome, 4);
    gtk_box_append(GTK_BOX(chrome), new_project_control());
    GtkWidget *sessions_btn = gtk_button_new_with_label("Sessions");
    g_signal_connect(sessions_btn, "clicked", G_CALLBACK(clicked_action), "manageSessions");
    gtk_box_append(GTK_BOX(chrome), sessions_btn);
    gtk_box_append(GTK_BOX(side_col), chrome);

    g_app->sidebar_scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(g_app->sidebar_scroll, TRUE);
    g_app->sidebar = gtk_list_box_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(g_app->sidebar_scroll), g_app->sidebar);
    g_signal_connect(g_app->sidebar, "row-activated", G_CALLBACK(on_sidebar_row), NULL);
    g_signal_connect(g_app->sidebar, "row-selected", G_CALLBACK(on_sidebar_row), NULL);
    gtk_box_append(GTK_BOX(side_col), g_app->sidebar_scroll);
    gtk_box_append(GTK_BOX(body), side_col);

    g_app->stack = gtk_stack_new();
    gtk_widget_set_hexpand(g_app->stack, TRUE);
    gtk_widget_set_vexpand(g_app->stack, TRUE);
    gtk_box_append(GTK_BOX(body), g_app->stack);

    add_shortcuts(g_app->window);
    g_signal_connect(g_app->window, "notify::is-active", G_CALLBACK(on_is_active), NULL);
    start_control();
    g_app->title_src = g_timeout_add(1000, poll_titles, NULL);
    sync_ui();
    gtk_window_present(GTK_WINDOW(g_app->window));
}

static int run_gui(void) {
    static FtApp app;
    memset(&app, 0, sizeof(app));
    g_app = &app;
    ft_xdg_data(app.data_dir, sizeof(app.data_dir));
    ft_xdg_config(app.config_dir, sizeof(app.config_dir));
    ft_mkdir_p(app.data_dir);
    ft_mkdir_p(app.config_dir);
    app.model = ft_model_new(app.data_dir, app.config_dir);
    ft_model_load(app.model);
    ft_prefs_defaults(&app.prefs);
    char prefpath[768];
    snprintf(prefpath, sizeof(prefpath), "%s/linux-prefs", app.config_dir);
    ft_prefs_load(prefpath, &app.prefs);
    ft_ghostty_load_default_files(&app.prefs);
    app.terms = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    app.notebooks = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    app.sent_run = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
    if (getenv("FUTURATERM_SOCKET") && getenv("FUTURATERM_SOCKET")[0]) {
        flags |= G_APPLICATION_NON_UNIQUE;
    }
    GtkApplication *gtkapp = gtk_application_new("com.davidsolheim.futuraterm", flags);
    g_signal_connect(gtkapp, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(gtkapp), 0, NULL);
    g_object_unref(gtkapp);
    return status;
}

/* ---- CLI ---- */

static int control_request(const char *path, const char *req, char *resp, size_t resp_n) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    if (write(fd, req, strlen(req)) < 0) {
        close(fd);
        return -1;
    }
    shutdown(fd, SHUT_WR);
    ssize_t n = read(fd, resp, resp_n - 1);
    close(fd);
    if (n < 0) {
        return -1;
    }
    resp[n] = 0;
    return 0;
}

static void discover_socket(char *out, size_t n, const char *override) {
    if (override && override[0]) {
        ft_str_set(out, n, override);
        return;
    }
    const char *env = getenv("FUTURATERM_SOCKET");
    if (env && env[0]) {
        ft_str_set(out, n, env);
        return;
    }
    char runtime[256];
    ft_xdg_runtime(runtime, sizeof(runtime));
    snprintf(out, n, "%s/futuraterm/control.sock", runtime);
}

static void json_set(char *obj, size_t n, const char *key, const char *val) {
    if (!val || !val[0]) {
        return;
    }
    char esc[1024];
    ft_json_esc(val, esc, sizeof(esc));
    size_t used = strlen(obj);
    if (used > 0 && obj[used - 1] == '{') {
        snprintf(obj + used, n - used, "\"%s\":\"%s\"", key, esc);
    } else {
        snprintf(obj + used, n - used, ",\"%s\":\"%s\"", key, esc);
    }
}

static void json_set_int(char *obj, size_t n, const char *key, int v, int set) {
    if (!set) {
        return;
    }
    size_t used = strlen(obj);
    if (used > 0 && obj[used - 1] == '{') {
        snprintf(obj + used, n - used, "\"%s\":%d", key, v);
    } else {
        snprintf(obj + used, n - used, ",\"%s\":%d", key, v);
    }
}

static void json_set_bool(char *obj, size_t n, const char *key, int v, int set) {
    if (!set) {
        return;
    }
    size_t used = strlen(obj);
    const char *b = v ? "true" : "false";
    if (used > 0 && obj[used - 1] == '{') {
        snprintf(obj + used, n - used, "\"%s\":%s", key, b);
    } else {
        snprintf(obj + used, n - used, ",\"%s\":%s", key, b);
    }
}

static void usage(void) {
    fprintf(stderr, "Usage: futuraterm\n");
    fprintf(stderr, "       futuraterm status\n");
    fprintf(stderr, "       futuraterm project list|create|open|select ...\n");
    fprintf(stderr, "       futuraterm tab list|new|select|move|close ...\n");
    fprintf(stderr, "       futuraterm pane list|dump|run|split|focus|close|key|zoom ...\n");
    fprintf(stderr, "       futuraterm grid RxC\n");
    fprintf(stderr, "       futuraterm session list|info|kill ...\n");
    fprintf(stderr, "       futuraterm layout apply|save\n");
}

static int is_flag(const char *s) {
    return s && s[0] == '-' && s[1] == '-';
}

static int cli_main(int argc, char **argv) {
    const char *socket_override = NULL;
    int json = 0, no_launch = 0;
    char *words[32];
    int nw = 0;
    const char *run_parts[64];
    int nrun = 0;
    int passthrough = 0;
    for (int i = 1; i < argc; i++) {
        if (passthrough) {
            if (nrun < 64) {
                run_parts[nrun++] = argv[i];
            }
            continue;
        }
        if (strcmp(argv[i], "--") == 0) {
            passthrough = 1;
            continue;
        }
        if (strcmp(argv[i], "--json") == 0) {
            json = 1;
        } else if (strcmp(argv[i], "--no-launch") == 0) {
            no_launch = 1;
        } else if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            socket_override = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage();
            return 0;
        } else if (nw < 32) {
            words[nw++] = argv[i];
        }
    }
    if (nw == 0) {
        usage();
        return 2;
    }

    char command[64] = "";
    char args[2048] = "{";
    int force = 0, select = 0, reuse = 1, has_reuse = 0;
    int rows = 0, cols = 0, slot = 0;
    const char *project = NULL, *tab = NULL, *session = NULL, *path = NULL, *name = NULL;
    const char *direction = NULL, *key = NULL, *run = NULL;

    const char *a0 = words[0];
    const char *a1 = nw > 1 ? words[1] : "";
    if (strcmp(a0, "status") == 0 || strcmp(a0, "dump") == 0 || strcmp(a0, "run") == 0) {
        if (strcmp(a0, "status") == 0) {
            snprintf(command, sizeof(command), "status");
        } else if (strcmp(a0, "dump") == 0) {
            snprintf(command, sizeof(command), "pane.dump");
        } else {
            snprintf(command, sizeof(command), "pane.run");
        }
    } else if (strcmp(a0, "project") == 0) {
        if (strcmp(a1, "list") == 0 || !a1[0]) {
            snprintf(command, sizeof(command), "project.list");
        } else if (strcmp(a1, "create") == 0) {
            snprintf(command, sizeof(command), "project.create");
        } else if (strcmp(a1, "open") == 0) {
            snprintf(command, sizeof(command), "project.open");
        } else if (strcmp(a1, "select") == 0) {
            snprintf(command, sizeof(command), "project.select");
        }
    } else if (strcmp(a0, "tab") == 0) {
        if (strcmp(a1, "list") == 0 || !a1[0]) {
            snprintf(command, sizeof(command), "tab.list");
        } else if (strcmp(a1, "new") == 0) {
            snprintf(command, sizeof(command), "tab.new");
        } else if (strcmp(a1, "select") == 0) {
            snprintf(command, sizeof(command), "tab.select");
        } else if (strcmp(a1, "move") == 0) {
            snprintf(command, sizeof(command), "tab.move");
        } else if (strcmp(a1, "close") == 0) {
            snprintf(command, sizeof(command), "tab.close");
        }
    } else if (strcmp(a0, "pane") == 0) {
        if (strcmp(a1, "list") == 0 || !a1[0]) {
            snprintf(command, sizeof(command), "pane.list");
        } else if (strcmp(a1, "dump") == 0) {
            snprintf(command, sizeof(command), "pane.dump");
        } else if (strcmp(a1, "run") == 0) {
            snprintf(command, sizeof(command), "pane.run");
        } else if (strcmp(a1, "split") == 0) {
            snprintf(command, sizeof(command), "pane.split");
        } else if (strcmp(a1, "focus") == 0) {
            snprintf(command, sizeof(command), "pane.focus");
        } else if (strcmp(a1, "close") == 0) {
            snprintf(command, sizeof(command), "pane.close");
        } else if (strcmp(a1, "key") == 0) {
            snprintf(command, sizeof(command), "pane.key");
        } else if (strcmp(a1, "zoom") == 0) {
            snprintf(command, sizeof(command), "pane.zoom");
        }
    } else if (strcmp(a0, "grid") == 0) {
        snprintf(command, sizeof(command), "grid");
        if (a1[0]) {
            sscanf(a1, "%dx%d", &rows, &cols);
        }
    } else if (strcmp(a0, "session") == 0) {
        if (strcmp(a1, "list") == 0 || !a1[0]) {
            snprintf(command, sizeof(command), "session.list");
        } else if (strcmp(a1, "info") == 0) {
            snprintf(command, sizeof(command), "session.info");
        } else if (strcmp(a1, "kill") == 0) {
            snprintf(command, sizeof(command), "session.kill");
        }
    } else if (strcmp(a0, "layout") == 0) {
        if (strcmp(a1, "apply") == 0) {
            snprintf(command, sizeof(command), "layout.apply");
        } else if (strcmp(a1, "save") == 0) {
            snprintf(command, sizeof(command), "layout.save");
        }
    }
    if (!command[0]) {
        usage();
        return 2;
    }

    /* positional + flags from remaining words */
    int start = (strchr(command, '.') || strcmp(command, "grid") == 0 || strcmp(command, "status") == 0) ? (strcmp(a0, "status") == 0 ? 1 : 2) : 1;
    if (strcmp(command, "grid") == 0) {
        start = 2;
    }
    if (strcmp(command, "status") == 0) {
        start = 1;
    }
    char runbuf[1024] = "";
    for (int i = start; i < nw; i++) {
        char *w = words[i];
        if (strcmp(w, "--project") == 0 && i + 1 < nw) {
            project = words[++i];
        } else if (strcmp(w, "--tab") == 0 && i + 1 < nw) {
            tab = words[++i];
        } else if (strcmp(w, "--session") == 0 && i + 1 < nw) {
            session = words[++i];
        } else if (strcmp(w, "--name") == 0 && i + 1 < nw) {
            name = words[++i];
        } else if (strcmp(w, "--run") == 0 && i + 1 < nw) {
            run = words[++i];
        } else if (strcmp(w, "--direction") == 0 && i + 1 < nw) {
            direction = words[++i];
        } else if (strcmp(w, "--force") == 0) {
            force = 1;
        } else if (strcmp(w, "--select") == 0) {
            select = 1;
        } else if (strcmp(w, "--no-reuse") == 0) {
            reuse = 0;
            has_reuse = 1;
        } else if (!is_flag(w)) {
            if ((strcmp(command, "project.create") == 0 || strcmp(command, "project.open") == 0) && !path) {
                path = w;
            } else if (strcmp(command, "project.select") == 0 && !project) {
                project = w;
            } else if ((strcmp(command, "tab.select") == 0 || strcmp(command, "tab.close") == 0 || strcmp(command, "tab.move") == 0) && !tab) {
                tab = w;
            } else if (strcmp(command, "tab.move") == 0 && tab && !slot) {
                slot = atoi(w);
            } else if ((strcmp(command, "session.info") == 0 || strcmp(command, "session.kill") == 0) && !session) {
                session = w;
            } else if (strcmp(command, "pane.key") == 0 && !key) {
                key = w;
            } else if (strcmp(command, "pane.run") == 0) {
                if (runbuf[0]) {
                    strncat(runbuf, " ", sizeof(runbuf) - strlen(runbuf) - 1);
                }
                strncat(runbuf, w, sizeof(runbuf) - strlen(runbuf) - 1);
            }
        }
    }
    for (int i = 0; i < nrun; i++) {
        if (runbuf[0]) {
            strncat(runbuf, " ", sizeof(runbuf) - strlen(runbuf) - 1);
        }
        strncat(runbuf, run_parts[i], sizeof(runbuf) - strlen(runbuf) - 1);
    }
    if (runbuf[0]) {
        run = runbuf;
    }

    json_set(args, sizeof(args), "project", project);
    json_set(args, sizeof(args), "tab", tab);
    json_set(args, sizeof(args), "session", session);
    json_set(args, sizeof(args), "path", path);
    json_set(args, sizeof(args), "name", name);
    json_set(args, sizeof(args), "run", run);
    json_set(args, sizeof(args), "direction", direction);
    json_set(args, sizeof(args), "key", key);
    json_set_int(args, sizeof(args), "rows", rows, rows > 0);
    json_set_int(args, sizeof(args), "cols", cols, cols > 0);
    json_set_int(args, sizeof(args), "slot", slot, slot > 0);
    json_set_bool(args, sizeof(args), "force", force, force);
    json_set_bool(args, sizeof(args), "select", select, select);
    json_set_bool(args, sizeof(args), "reuse", reuse, has_reuse);
    strcat(args, "}");

    char req[4096];
    snprintf(req, sizeof(req), "{\"v\":1,\"id\":\"cli\",\"command\":\"%s\",\"args\":%s}\n", command, args);

    char sock[256];
    discover_socket(sock, sizeof(sock), socket_override);
    char resp[131072];
    if (control_request(sock, req, resp, sizeof(resp)) != 0) {
        if (no_launch || socket_override) {
            fprintf(stderr, "futuraterm: no running instance\n");
            return 2;
        }
        pid_t pid = fork();
        if (pid == 0) {
            char self[512];
            ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
            if (n > 0) {
                self[n] = 0;
                execl(self, self, (char *)NULL);
            }
            execlp("futuraterm", "futuraterm", (char *)NULL);
            _exit(127);
        }
        for (int i = 0; i < 80; i++) {
            usleep(250000);
            if (control_request(sock, req, resp, sizeof(resp)) == 0) {
                goto got;
            }
        }
        fprintf(stderr, "futuraterm: no running instance\n");
        return 2;
    }
got:
    if (strstr(resp, "\"ok\":false")) {
        char msg[256] = "";
        ft_json_str(resp, "message", msg, sizeof(msg));
        fprintf(stderr, "%s\n", msg[0] ? msg : resp);
        return 1;
    }
    if (!json && strcmp(command, "pane.dump") == 0) {
        char text[65536];
        if (ft_json_str(resp, "text", text, sizeof(text)) == 0) {
            fputs(text, stdout);
            if (!text[0] || text[strlen(text) - 1] != '\n') {
                fputc('\n', stdout);
            }
            return 0;
        }
    }
    fputs(resp, stdout);
    if (resp[0] && resp[strlen(resp) - 1] != '\n') {
        fputc('\n', stdout);
    }
    return 0;
}

int main(int argc, char **argv) {
    g_set_prgname("futuraterm");
    g_set_application_name("FuturaTerm");
    if (argc <= 1) {
        return run_gui();
    }
    if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        usage();
        fprintf(stderr, "       (no args starts the GUI)\n");
        return 0;
    }
    return cli_main(argc, argv);
}
