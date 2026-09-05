/* FuturaTerm Linux app chrome: sidebar projects, tabs, split panes, control socket.
 * Terminal core is libvterm (GhosttyKit embed API is macOS/Metal-only). */

#define _GNU_SOURCE
#include "session.h"
#include "term.h"

#include <dirent.h>
#include <gio/gio.h>
#include <gio/gunixsocketaddress.h>
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct FtTab FtTab;
typedef struct FtProject FtProject;
typedef struct FtApp FtApp;

struct FtTab {
    char title[64];
    GtkWidget *page;
    GPtrArray *terms; /* FtTerm* */
    FtTerm *focused;
};

struct FtProject {
    char name[64];
    char path[512];
    GtkWidget *notebook;
    GPtrArray *tabs; /* FtTab* */
};

struct FtApp {
    GtkWidget *window;
    GtkWidget *sidebar;
    GtkWidget *stack; /* one notebook per project */
    GtkWidget *header;
    GPtrArray *projects; /* FtProject* */
    FtProject *active;
    FtTerm *focused;
    char socket_path[256];
    GSocketService *service;
};

static FtApp *g_app;

static const char *json_str(const char *json, const char *key, char *out, size_t n) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) {
        return NULL;
    }
    p = strchr(p + strlen(pat), ':');
    if (!p) {
        return NULL;
    }
    p++;
    while (*p == ' ') {
        p++;
    }
    if (*p != '"') {
        return NULL;
    }
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < n) {
        if (*p == '\\' && p[1]) {
            p++;
        }
        out[i++] = *p++;
    }
    out[i] = 0;
    return out;
}

static void json_escape(const char *s, GString *out) {
    for (; s && *s; s++) {
        if (*s == '"' || *s == '\\') {
            g_string_append_c(out, '\\');
        }
        if (*s == '\n') {
            g_string_append(out, "\\n");
        } else if (*s == '\r') {
            continue;
        } else {
            g_string_append_c(out, *s);
        }
    }
}

static void focus_term(FtTerm *term) {
    g_app->focused = term;
    if (g_app->active) {
        for (guint i = 0; i < g_app->active->tabs->len; i++) {
            FtTab *tab = g_ptr_array_index(g_app->active->tabs, i);
            for (guint j = 0; j < tab->terms->len; j++) {
                if (g_ptr_array_index(tab->terms, j) == term) {
                    tab->focused = term;
                }
            }
        }
    }
    gtk_widget_grab_focus(term->area);
}

static gboolean on_term_click(GtkGestureClick *g, gint n, gdouble x, gdouble y, gpointer user) {
    (void)g;
    (void)n;
    (void)x;
    (void)y;
    focus_term(user);
    return FALSE;
}

static void wire_focus(FtTerm *term) {
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(on_term_click), term);
    gtk_widget_add_controller(term->area, GTK_EVENT_CONTROLLER(click));
}

static FtTerm *spawn_term(FtProject *proj) {
    char session[80];
    if (ft_linux_make_pane_session(proj->name, session, sizeof(session)) != 0) {
        snprintf(session, sizeof(session), "futuraterm-linux");
    }
    FtTerm *term = ft_term_new(session, proj->path);
    if (!term) {
        return NULL;
    }
    wire_focus(term);
    return term;
}

static FtTab *tab_new(FtProject *proj, const char *title) {
    FtTab *tab = g_new0(FtTab, 1);
    snprintf(tab->title, sizeof(tab->title), "%s", title ? title : "Tab");
    tab->terms = g_ptr_array_new();
    FtTerm *term = spawn_term(proj);
    if (!term) {
        g_ptr_array_unref(tab->terms);
        g_free(tab);
        return NULL;
    }
    g_ptr_array_add(tab->terms, term);
    tab->focused = term;
    tab->page = term->area;
    gtk_notebook_append_page(GTK_NOTEBOOK(proj->notebook), tab->page, gtk_label_new(tab->title));
    gtk_notebook_set_tab_reorderable(GTK_NOTEBOOK(proj->notebook), tab->page, TRUE);
    g_ptr_array_add(proj->tabs, tab);
    gtk_notebook_set_current_page(GTK_NOTEBOOK(proj->notebook), (int)proj->tabs->len - 1);
    focus_term(term);
    return tab;
}

static FtTab *active_tab(void) {
    if (!g_app->active || !g_app->active->tabs->len) {
        return NULL;
    }
    int page = gtk_notebook_get_current_page(GTK_NOTEBOOK(g_app->active->notebook));
    if (page < 0 || page >= (int)g_app->active->tabs->len) {
        page = 0;
    }
    return g_ptr_array_index(g_app->active->tabs, (guint)page);
}

static void split_focused(GtkOrientation orient) {
    FtTab *tab = active_tab();
    if (!tab || !tab->focused) {
        return;
    }
    FtProject *proj = g_app->active;
    FtTerm *old = tab->focused;
    FtTerm *fresh = spawn_term(proj);
    if (!fresh) {
        return;
    }
    g_ptr_array_add(tab->terms, fresh);
    GtkWidget *paned = gtk_paned_new(orient);
    gtk_widget_set_hexpand(paned, TRUE);
    gtk_widget_set_vexpand(paned, TRUE);
    GtkWidget *parent = gtk_widget_get_parent(old->area);
    g_object_ref(old->area);
    if (parent == proj->notebook) {
        int idx = gtk_notebook_page_num(GTK_NOTEBOOK(proj->notebook), old->area);
        gtk_notebook_remove_page(GTK_NOTEBOOK(proj->notebook), idx);
        gtk_paned_set_start_child(GTK_PANED(paned), old->area);
        gtk_paned_set_end_child(GTK_PANED(paned), fresh->area);
        gtk_notebook_insert_page(GTK_NOTEBOOK(proj->notebook), paned, gtk_label_new(tab->title), idx);
        gtk_notebook_set_current_page(GTK_NOTEBOOK(proj->notebook), idx);
        tab->page = paned;
    } else if (GTK_IS_PANED(parent)) {
        GtkWidget *start = gtk_paned_get_start_child(GTK_PANED(parent));
        int was_start = (start == old->area);
        if (was_start) {
            gtk_paned_set_start_child(GTK_PANED(parent), NULL);
        } else {
            gtk_paned_set_end_child(GTK_PANED(parent), NULL);
        }
        gtk_paned_set_start_child(GTK_PANED(paned), old->area);
        gtk_paned_set_end_child(GTK_PANED(paned), fresh->area);
        if (was_start) {
            gtk_paned_set_start_child(GTK_PANED(parent), paned);
        } else {
            gtk_paned_set_end_child(GTK_PANED(parent), paned);
        }
    }
    g_object_unref(old->area);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), TRUE);
    gtk_paned_set_resize_end_child(GTK_PANED(paned), TRUE);
    gtk_widget_set_visible(paned, TRUE);
    focus_term(fresh);
}

static void on_new_tab(void) {
    if (g_app->active) {
        char title[32];
        snprintf(title, sizeof(title), "Tab %u", g_app->active->tabs->len + 1);
        tab_new(g_app->active, title);
    }
}

static void on_split_right(void) {
    split_focused(GTK_ORIENTATION_HORIZONTAL);
}

static void clicked_new_tab(GtkButton *b, gpointer user) {
    (void)b;
    (void)user;
    on_new_tab();
}

static void clicked_split(GtkButton *b, gpointer user) {
    (void)b;
    (void)user;
    on_split_right();
}

static FtTerm *find_term(const char *session) {
    if (!g_app->projects) {
        return NULL;
    }
    for (guint p = 0; p < g_app->projects->len; p++) {
        FtProject *proj = g_ptr_array_index(g_app->projects, p);
        for (guint t = 0; t < proj->tabs->len; t++) {
            FtTab *tab = g_ptr_array_index(proj->tabs, t);
            for (guint i = 0; i < tab->terms->len; i++) {
                FtTerm *term = g_ptr_array_index(tab->terms, i);
                if (!session || session[0] == 0 || strcmp(term->session, session) == 0) {
                    return term;
                }
            }
        }
    }
    return g_app->focused;
}

static void select_project(FtProject *proj) {
    g_app->active = proj;
    if (proj->tabs->len == 0) {
        tab_new(proj, "Tab 1");
    }
    gtk_stack_set_visible_child(GTK_STACK(g_app->stack), proj->notebook);
    gtk_window_set_title(GTK_WINDOW(g_app->window), proj->name);
    FtTab *tab = active_tab();
    if (tab && tab->focused) {
        focus_term(tab->focused);
    }
}

static void on_project_row(GtkListBox *box, GtkListBoxRow *row, gpointer user) {
    (void)box;
    (void)user;
    if (!row) {
        return;
    }
    int idx = gtk_list_box_row_get_index(row);
    if (idx >= 0 && idx < (int)g_app->projects->len) {
        select_project(g_ptr_array_index(g_app->projects, idx));
    }
}

static FtProject *project_add(const char *name, const char *path) {
    FtProject *proj = g_new0(FtProject, 1);
    snprintf(proj->name, sizeof(proj->name), "%s", name);
    snprintf(proj->path, sizeof(proj->path), "%s", path);
    proj->tabs = g_ptr_array_new();
    proj->notebook = gtk_notebook_new();
    gtk_notebook_set_scrollable(GTK_NOTEBOOK(proj->notebook), TRUE);
    gtk_widget_set_hexpand(proj->notebook, TRUE);
    gtk_widget_set_vexpand(proj->notebook, TRUE);
    gtk_stack_add_named(GTK_STACK(g_app->stack), proj->notebook, proj->name);
    GtkWidget *row = gtk_label_new(proj->name);
    gtk_widget_set_halign(row, GTK_ALIGN_START);
    gtk_widget_set_margin_start(row, 10);
    gtk_widget_set_margin_end(row, 10);
    gtk_widget_set_margin_top(row, 6);
    gtk_widget_set_margin_bottom(row, 6);
    gtk_list_box_append(GTK_LIST_BOX(g_app->sidebar), row);
    g_ptr_array_add(g_app->projects, proj);
    return proj;
}

static void load_projects(void) {
    const char *home = getenv("HOME");
    if (!home) {
        home = ".";
    }
    project_add("Home", home);
    char gh[512];
    snprintf(gh, sizeof(gh), "%s/GitHub", home);
    DIR *d = opendir(gh);
    if (d) {
        struct dirent *ent;
        int n = 0;
        while ((ent = readdir(d)) != NULL && n < 12) {
            if (ent->d_name[0] == '.') {
                continue;
            }
            char full[768];
            snprintf(full, sizeof(full), "%s/%s", gh, ent->d_name);
            struct stat st;
            if (stat(full, &st) == 0 && S_ISDIR(st.st_mode)) {
                project_add(ent->d_name, full);
                n++;
            }
        }
        closedir(d);
    }
}

static void handle_json(const char *req, GString *resp) {
    char id[80] = "0";
    char command[64] = "";
    char session[80] = "";
    char run[1024] = "";
    char direction[16] = "";
    json_str(req, "id", id, sizeof(id));
    json_str(req, "command", command, sizeof(command));
    json_str(req, "session", session, sizeof(session));
    json_str(req, "run", run, sizeof(run));
    json_str(req, "direction", direction, sizeof(direction));

    g_string_append_printf(resp, "{\"v\":1,\"id\":\"%s\",\"ok\":true,\"data\":", id);
    if (strcmp(command, "status") == 0) {
        const char *name = g_app->active ? g_app->active->name : "";
        g_string_append_printf(resp, "{\"activeProject\":\"%s\",\"pid\":%d}", name, getpid());
    } else if (strcmp(command, "project.list") == 0) {
        g_string_append(resp, "{\"projects\":[");
        for (guint i = 0; i < g_app->projects->len; i++) {
            FtProject *p = g_ptr_array_index(g_app->projects, i);
            if (i) {
                g_string_append_c(resp, ',');
            }
            g_string_append_printf(
                resp,
                "{\"name\":\"%s\",\"path\":\"%s\",\"active\":%s,\"tabCount\":%u}",
                p->name,
                p->path,
                p == g_app->active ? "true" : "false",
                p->tabs->len
            );
        }
        g_string_append(resp, "]}");
    } else if (strcmp(command, "pane.list") == 0) {
        g_string_append(resp, "{\"panes\":[");
        int idx = 0;
        if (g_app->active) {
            for (guint t = 0; t < g_app->active->tabs->len; t++) {
                FtTab *tab = g_ptr_array_index(g_app->active->tabs, t);
                for (guint i = 0; i < tab->terms->len; i++) {
                    FtTerm *term = g_ptr_array_index(tab->terms, i);
                    if (idx++) {
                        g_string_append_c(resp, ',');
                    }
                    g_string_append_printf(
                        resp,
                        "{\"index\":%d,\"session\":\"%s\",\"cwd\":\"%s\",\"focused\":%s}",
                        idx,
                        term->session,
                        term->project_path,
                        term == g_app->focused ? "true" : "false"
                    );
                }
            }
        }
        g_string_append(resp, "]}");
    } else if (strcmp(command, "pane.dump") == 0) {
        FtTerm *term = find_term(session);
        GString *text = g_string_new("");
        if (term) {
            ft_term_dump(term, text);
        }
        g_string_append(resp, "{\"dump\":{\"text\":\"");
        json_escape(text->str, resp);
        g_string_append(resp, "\"}}");
        g_string_free(text, TRUE);
    } else if (strcmp(command, "pane.run") == 0) {
        FtTerm *term = find_term(session);
        if (term && run[0]) {
            ft_term_write(term, run);
            ft_term_write(term, "\n");
        }
        g_string_append(resp, "{\"ok\":true}");
    } else if (strcmp(command, "pane.split") == 0) {
        GtkOrientation o = GTK_ORIENTATION_HORIZONTAL;
        if (strcmp(direction, "down") == 0 || strcmp(direction, "vertical") == 0) {
            o = GTK_ORIENTATION_VERTICAL;
        }
        split_focused(o);
        g_string_append(resp, "{}");
    } else if (strcmp(command, "tab.new") == 0) {
        on_new_tab();
        g_string_append(resp, "{}");
    } else {
        g_string_assign(resp, "");
        g_string_append_printf(
            resp,
            "{\"v\":1,\"id\":\"%s\",\"ok\":false,\"error\":{\"code\":\"unknown_command\",\"message\":\"%s\"}}",
            id,
            command
        );
        return;
    }
    g_string_append(resp, "}");
}

static gboolean on_control(GSocketService *service, GSocketConnection *conn, GObject *src, gpointer user) {
    (void)service;
    (void)src;
    (void)user;
    GInputStream *in = g_io_stream_get_input_stream(G_IO_STREAM(conn));
    GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(conn));
    gchar buf[8192];
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
        handle_json(buf, resp);
        g_string_append_c(resp, '\n');
    } else if (strcmp(buf, "dump") == 0) {
        FtTerm *term = find_term(NULL);
        if (term) {
            ft_term_dump(term, resp);
        }
    } else if (strncmp(buf, "run ", 4) == 0) {
        FtTerm *term = find_term(NULL);
        if (term) {
            ft_term_write(term, buf + 4);
            ft_term_write(term, "\n");
        }
        g_string_append(resp, "ok\n");
    } else if (strcmp(buf, "pid") == 0) {
        g_string_append_printf(resp, "%d\n", getpid());
    } else {
        g_string_append(resp, "error unknown\n");
    }
    g_output_stream_write_all(out, resp->str, resp->len, NULL, NULL, NULL);
    g_string_free(resp, TRUE);
    return FALSE;
}

static void start_control(void) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || !runtime[0]) {
        runtime = "/tmp";
    }
    snprintf(g_app->socket_path, sizeof(g_app->socket_path), "%s/futuraterm-linux.sock", runtime);
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
    }
    g_object_unref(addr);
}

static int control_request(const char *req, char *resp, size_t resp_n) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || !runtime[0]) {
        runtime = "/tmp";
    }
    char path[256];
    snprintf(path, sizeof(path), "%s/futuraterm-linux.sock", runtime);
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
    ssize_t n = read(fd, resp, resp_n - 1);
    close(fd);
    if (n < 0) {
        return -1;
    }
    resp[n] = 0;
    return 0;
}

static void add_shortcut(GtkWidget *widget, guint key, GdkModifierType mods, GCallback cb) {
    GtkEventController *ctl = gtk_shortcut_controller_new();
    gtk_shortcut_controller_set_scope(GTK_SHORTCUT_CONTROLLER(ctl), GTK_SHORTCUT_SCOPE_GLOBAL);
    GtkShortcut *sc = gtk_shortcut_new(gtk_keyval_trigger_new(key, mods), gtk_callback_action_new((GtkShortcutFunc)cb, NULL, NULL));
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(ctl), sc);
    gtk_widget_add_controller(widget, ctl);
}

static gboolean shortcut_new_tab(GtkWidget *w, GVariant *args, gpointer user) {
    (void)w;
    (void)args;
    (void)user;
    on_new_tab();
    return TRUE;
}

static gboolean shortcut_split_h(GtkWidget *w, GVariant *args, gpointer user) {
    (void)w;
    (void)args;
    (void)user;
    split_focused(GTK_ORIENTATION_HORIZONTAL);
    return TRUE;
}

static gboolean shortcut_split_v(GtkWidget *w, GVariant *args, gpointer user) {
    (void)w;
    (void)args;
    (void)user;
    split_focused(GTK_ORIENTATION_VERTICAL);
    return TRUE;
}

static gboolean on_close(GtkWindow *w, gpointer user) {
    (void)user;
    gtk_window_destroy(w);
    return FALSE;
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
    g_signal_connect(new_tab, "clicked", G_CALLBACK(clicked_new_tab), NULL);
    g_signal_connect(split, "clicked", G_CALLBACK(clicked_split), NULL);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), new_tab);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), split);
    gtk_window_set_titlebar(GTK_WINDOW(g_app->window), bar);

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(body, TRUE);
    gtk_box_append(GTK_BOX(outer), body);

    GtkWidget *side_scroll = gtk_scrolled_window_new();
    gtk_widget_set_size_request(side_scroll, 200, -1);
    g_app->sidebar = gtk_list_box_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(side_scroll), g_app->sidebar);
    g_signal_connect(g_app->sidebar, "row-activated", G_CALLBACK(on_project_row), NULL);
    g_signal_connect(g_app->sidebar, "row-selected", G_CALLBACK(on_project_row), NULL);
    gtk_box_append(GTK_BOX(body), side_scroll);

    g_app->stack = gtk_stack_new();
    gtk_widget_set_hexpand(g_app->stack, TRUE);
    gtk_widget_set_vexpand(g_app->stack, TRUE);
    gtk_box_append(GTK_BOX(body), g_app->stack);

    load_projects();
    if (g_app->projects->len) {
        select_project(g_ptr_array_index(g_app->projects, 0));
        gtk_list_box_select_row(GTK_LIST_BOX(g_app->sidebar), gtk_list_box_get_row_at_index(GTK_LIST_BOX(g_app->sidebar), 0));
    }

    add_shortcut(g_app->window, GDK_KEY_t, GDK_CONTROL_MASK, G_CALLBACK(shortcut_new_tab));
    add_shortcut(g_app->window, GDK_KEY_d, GDK_CONTROL_MASK, G_CALLBACK(shortcut_split_h));
    add_shortcut(g_app->window, GDK_KEY_d, GDK_CONTROL_MASK | GDK_SHIFT_MASK, G_CALLBACK(shortcut_split_v));

    start_control();
    gtk_window_present(GTK_WINDOW(g_app->window));
}

static int run_gui(void) {
    static FtApp app;
    memset(&app, 0, sizeof(app));
    g_app = &app;
    app.projects = g_ptr_array_new();
    GtkApplication *gtkapp = gtk_application_new("com.davidsolheim.futuraterm", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(gtkapp, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(gtkapp), 0, NULL);
    g_object_unref(gtkapp);
    return status;
}

static void usage(void) {
    fprintf(stderr, "Usage: futuraterm-linux\n");
    fprintf(stderr, "       futuraterm-linux dump [--session NAME]\n");
    fprintf(stderr, "       futuraterm-linux run [--session NAME] COMMAND\n");
    fprintf(stderr, "       futuraterm-linux status\n");
}

int main(int argc, char **argv) {
    g_set_prgname("futuraterm");
    g_set_application_name("FuturaTerm");

    const char *mode = "gui";
    const char *session = "";
    const char *run_cmd = NULL;
    int i = 1;
    if (i < argc && (strcmp(argv[i], "dump") == 0 || strcmp(argv[i], "run") == 0 || strcmp(argv[i], "status") == 0)) {
        mode = argv[i++];
    }
    while (i < argc) {
        if ((strcmp(argv[i], "--session") == 0 || strcmp(argv[i], "-s") == 0) && i + 1 < argc) {
            session = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage();
            return 0;
        } else if (strcmp(mode, "run") == 0 && run_cmd == NULL) {
            run_cmd = argv[i];
        } else {
            usage();
            return 2;
        }
        i++;
    }

    if (strcmp(mode, "gui") == 0) {
        return run_gui();
    }

    char req[4096];
    char resp[65536];
    if (strcmp(mode, "status") == 0) {
        snprintf(req, sizeof(req), "{\"v\":1,\"id\":\"cli\",\"command\":\"status\"}\n");
    } else if (strcmp(mode, "dump") == 0) {
        if (session[0]) {
            snprintf(req, sizeof(req), "{\"v\":1,\"id\":\"cli\",\"command\":\"pane.dump\",\"args\":{\"session\":\"%s\"}}\n", session);
        } else {
            snprintf(req, sizeof(req), "dump\n");
        }
    } else {
        if (!run_cmd) {
            usage();
            return 2;
        }
        if (session[0]) {
            snprintf(req, sizeof(req), "{\"v\":1,\"id\":\"cli\",\"command\":\"pane.run\",\"args\":{\"session\":\"%s\",\"run\":\"%s\"}}\n", session, run_cmd);
        } else {
            snprintf(req, sizeof(req), "run %s\n", run_cmd);
        }
    }
    if (control_request(req, resp, sizeof(resp)) != 0) {
        fprintf(stderr, "futuraterm-linux: no running instance\n");
        return 1;
    }
    fputs(resp, stdout);
    if (resp[0] && resp[strlen(resp) - 1] != '\n') {
        fputc('\n', stdout);
    }
    return 0;
}
