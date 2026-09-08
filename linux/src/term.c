#define _GNU_SOURCE
#include "term.h"

#include "path.h"
#include "remote.h"
#include "session.h"
#include "util.h"

#include <cairo.h>
#include <errno.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <pango/pangocairo.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void color_rgb(FtTerm *term, const VTermColor *c, VTermColor *def, double *r, double *g, double *b) {
    VTermColor tmp = *c;
    vterm_screen_convert_color_to_rgb(term->screen, &tmp);
    if (VTERM_COLOR_IS_DEFAULT_FG(&tmp) && def) {
        tmp = *def;
        vterm_screen_convert_color_to_rgb(term->screen, &tmp);
    }
    if (VTERM_COLOR_IS_INDEXED(&tmp)) {
        int idx = tmp.indexed.idx & 15;
        *r = term->palette[idx][0] / 255.0;
        *g = term->palette[idx][1] / 255.0;
        *b = term->palette[idx][2] / 255.0;
        return;
    }
    *r = tmp.rgb.red / 255.0;
    *g = tmp.rgb.green / 255.0;
    *b = tmp.rgb.blue / 255.0;
}

static int screen_damage(VTermRect rect, void *user) {
    (void)rect;
    FtTerm *term = user;
    if (term->area) {
        gtk_widget_queue_draw(term->area);
    }
    return 1;
}

static int screen_moverect(VTermRect dest, VTermRect src, void *user) {
    (void)dest;
    (void)src;
    return screen_damage((VTermRect){0}, user);
}

static int screen_movecursor(VTermPos pos, VTermPos oldpos, int visible, void *user) {
    (void)pos;
    (void)oldpos;
    (void)visible;
    return screen_damage((VTermRect){0}, user);
}

static int screen_settermprop(VTermProp prop, VTermValue *val, void *user) {
    FtTerm *term = user;
    if (prop == VTERM_PROP_TITLE && val && val->string.str && term->title_cb) {
        term->title_cb(term, val->string.str, term->title_user);
    }
    return 1;
}

static int screen_bell(void *user) {
    (void)user;
    return 1;
}

static int screen_resize(int rows, int cols, void *user) {
    (void)rows;
    (void)cols;
    (void)user;
    return 1;
}

static int screen_sb_pushline(int cols, const VTermScreenCell *cells, void *user) {
    (void)cols;
    (void)cells;
    (void)user;
    return 1;
}

static int screen_sb_popline(int cols, VTermScreenCell *cells, void *user) {
    (void)cols;
    (void)cells;
    (void)user;
    return 0;
}

static const VTermScreenCallbacks screen_cbs = {
    .damage = screen_damage,
    .moverect = screen_moverect,
    .movecursor = screen_movecursor,
    .settermprop = screen_settermprop,
    .bell = screen_bell,
    .resize = screen_resize,
    .sb_pushline = screen_sb_pushline,
    .sb_popline = screen_sb_popline,
};

static void vterm_output(const char *s, size_t len, void *user) {
    FtTerm *term = user;
    if (term->pty_master >= 0 && len > 0) {
        ssize_t w = write(term->pty_master, s, len);
        (void)w;
    }
}

static void mark_exited(FtTerm *term) {
    if (term->exited) {
        return;
    }
    term->exited = 1;
    if (term->exited_cb) {
        term->exited_cb(term, term->exited_user);
    }
}

static gboolean pty_read(gint fd, GIOCondition cond, gpointer user) {
    FtTerm *term = user;
    int hung = (cond & (G_IO_HUP | G_IO_ERR)) ? 1 : 0;
    char buf[4096];
    ssize_t n = 0;
    int err = 0;
    if (!hung) {
        n = read(fd, buf, sizeof(buf));
        err = errno;
        if (n > 0) {
            vterm_input_write(term->vt, buf, (size_t)n);
            vterm_screen_flush_damage(term->screen);
        }
    }
    if (ft_linux_pty_finished(hung ? 0 : n, err, hung)) {
        mark_exited(term);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static void apply_winsize(FtTerm *term) {
    if (term->pty_master < 0 || term->cols < 1 || term->rows < 1) {
        return;
    }
    struct winsize ws = {
        .ws_row = (unsigned short)term->rows,
        .ws_col = (unsigned short)term->cols,
    };
    ioctl(term->pty_master, TIOCSWINSZ, &ws);
    vterm_set_size(term->vt, term->rows, term->cols);
}

static int spawn_session(FtTerm *term, const char *cwd) {
    char zmx[512];
    const char *argv[8];
    char dest[192];
    char wrap[5000];
    int have_cmd = 0;
    FtProjectPath parsed;
    int remote = ft_path_parse(cwd, &parsed) == 0 && parsed.kind == FT_PATH_REMOTE;
    term->remote = remote;
    if (remote) {
        have_cmd = ft_remote_pane_argv(&parsed, term->session, term->zmx_path[0] ? term->zmx_path : NULL, dest, sizeof(dest), wrap, sizeof(wrap), argv) == 0;
    } else {
        have_cmd = ft_linux_zmx_attach_argv(term->session, zmx, sizeof(zmx), argv) == 0;
    }
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) {
        perror("forkpty");
        return -1;
    }
    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("FUTURATERM_SESSION", term->session, 1);
        if (!remote && cwd && cwd[0] && chdir(cwd) != 0) {
            /* stay in inherited cwd */
        }
        if (have_cmd) {
            if (remote) {
                execvp(argv[0], (char *const *)argv);
            } else {
                execv(argv[0], (char *const *)argv);
            }
        }
        const char *msg = "futuraterm: zmx not found in PATH on this host\n";
        ssize_t w = write(STDERR_FILENO, msg, strlen(msg));
        (void)w;
        execl("/bin/sh", "sh", "-c", "exec ${SHELL:-/bin/sh}", (char *)NULL);
        _exit(127);
    }
    int flags = fcntl(master, F_GETFL, 0);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
    term->pty_master = master;
    term->child = pid;
    term->pty_src = g_unix_fd_add(master, G_IO_IN | G_IO_HUP | G_IO_ERR, pty_read, term);
    return 0;
}

static void measure_cell(cairo_t *cr, FtTerm *term) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    char fontdesc[160];
    snprintf(fontdesc, sizeof(fontdesc), "%s %d", term->font[0] ? term->font : "Monospace", term->font_size > 0 ? term->font_size : 12);
    PangoFontDescription *font = pango_font_description_from_string(fontdesc);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, "M", -1);
    int w = 0, h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    pango_font_description_free(font);
    g_object_unref(layout);
    term->cell_w = w < 4 ? 8 : w;
    term->cell_h = h < 8 ? 16 : h;
}

static void draw_term(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user) {
    (void)area;
    FtTerm *term = user;
    measure_cell(cr, term);
    int cols = width / term->cell_w;
    int rows = height / term->cell_h;
    if (cols < 1) {
        cols = 1;
    }
    if (rows < 1) {
        rows = 1;
    }
    if (cols != term->cols || rows != term->rows) {
        term->cols = cols;
        term->rows = rows;
        apply_winsize(term);
    }
    cairo_set_source_rgb(cr, term->background[0] / 255.0, term->background[1] / 255.0, term->background[2] / 255.0);
    cairo_paint(cr);
    char fontdesc[160];
    snprintf(fontdesc, sizeof(fontdesc), "%s %d", term->font[0] ? term->font : "Monospace", term->font_size > 0 ? term->font_size : 12);
    PangoFontDescription *font = pango_font_description_from_string(fontdesc);
    VTermColor def_fg, def_bg;
    vterm_state_get_default_colors(vterm_obtain_state(term->vt), &def_fg, &def_bg);
    for (int r = 0; r < term->rows; r++) {
        for (int c = 0; c < term->cols; c++) {
            VTermPos pos = {.row = r, .col = c};
            VTermScreenCell cell;
            memset(&cell, 0, sizeof(cell));
            vterm_screen_get_cell(term->screen, pos, &cell);
            double br, bg, bb, fr, fg, fb;
            color_rgb(term, &cell.bg, &def_bg, &br, &bg, &bb);
            color_rgb(term, &cell.fg, &def_fg, &fr, &fg, &fb);
            if (ft_sel_contains(&term->sel, r, c)) {
                double tr = fr, tg = fg, tb = fb;
                fr = br;
                fg = bg;
                fb = bb;
                br = tr;
                bg = tg;
                bb = tb;
            }
            cairo_set_source_rgb(cr, br, bg, bb);
            cairo_rectangle(cr, c * term->cell_w, r * term->cell_h, term->cell_w * (cell.width > 0 ? cell.width : 1), term->cell_h);
            cairo_fill(cr);
            if (cell.chars[0] == 0 || cell.chars[0] == ' ') {
                continue;
            }
            char utf8[8];
            int len = g_unichar_to_utf8((gunichar)cell.chars[0], utf8);
            utf8[len] = 0;
            PangoLayout *layout = pango_cairo_create_layout(cr);
            pango_layout_set_font_description(layout, font);
            pango_layout_set_text(layout, utf8, len);
            cairo_set_source_rgb(cr, fr, fg, fb);
            cairo_move_to(cr, c * term->cell_w, r * term->cell_h);
            pango_cairo_show_layout(cr, layout);
            g_object_unref(layout);
        }
    }
    pango_font_description_free(font);
    VTermPos cursor;
    vterm_state_get_cursorpos(vterm_obtain_state(term->vt), &cursor);
    cairo_set_source_rgba(cr, 0.7, 0.85, 1.0, 0.7);
    cairo_rectangle(cr, cursor.col * term->cell_w, cursor.row * term->cell_h, 2, term->cell_h);
    cairo_fill(cr);
}

gboolean ft_term_key(FtTerm *term, guint keyval, GdkModifierType mods) {
    if (mods & GDK_SUPER_MASK) {
        guint k = gdk_keyval_to_lower(keyval);
        if (k == GDK_KEY_c || k == GDK_KEY_x) {
            char buf[65536];
            if (ft_term_copy_selection(term, buf, sizeof(buf)) > 0 && term->area) {
                gdk_clipboard_set_text(gtk_widget_get_clipboard(term->area), buf);
                GdkClipboard *prim = gdk_display_get_primary_clipboard(gdk_display_get_default());
                if (prim) {
                    gdk_clipboard_set_text(prim, buf);
                }
            }
            return TRUE;
        }
        if (k == GDK_KEY_v) {
            ft_term_request_paste(term);
            return TRUE;
        }
        if (k == GDK_KEY_a) {
            ft_term_select_all(term);
            return TRUE;
        }
        return FALSE;
    }
    if (term->sel.on && !(mods & GDK_CONTROL_MASK && (keyval == GDK_KEY_c || keyval == GDK_KEY_C))) {
        ft_sel_clear(&term->sel);
        if (term->area) {
            gtk_widget_queue_draw(term->area);
        }
    }
    VTermModifier vm = VTERM_MOD_NONE;
    if (mods & GDK_SHIFT_MASK) {
        vm |= VTERM_MOD_SHIFT;
    }
    if (mods & GDK_CONTROL_MASK) {
        vm |= VTERM_MOD_CTRL;
    }
    if (mods & GDK_ALT_MASK) {
        vm |= VTERM_MOD_ALT;
    }
    VTermKey vk = VTERM_KEY_NONE;
    switch (keyval) {
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
        vk = VTERM_KEY_ENTER;
        break;
    case GDK_KEY_BackSpace:
        vk = VTERM_KEY_BACKSPACE;
        break;
    case GDK_KEY_Tab:
        vk = VTERM_KEY_TAB;
        break;
    case GDK_KEY_Escape:
        vk = VTERM_KEY_ESCAPE;
        break;
    case GDK_KEY_Up:
        vk = VTERM_KEY_UP;
        break;
    case GDK_KEY_Down:
        vk = VTERM_KEY_DOWN;
        break;
    case GDK_KEY_Left:
        vk = VTERM_KEY_LEFT;
        break;
    case GDK_KEY_Right:
        vk = VTERM_KEY_RIGHT;
        break;
    case GDK_KEY_Delete:
        vk = VTERM_KEY_DEL;
        break;
    case GDK_KEY_Home:
        vk = VTERM_KEY_HOME;
        break;
    case GDK_KEY_End:
        vk = VTERM_KEY_END;
        break;
    case GDK_KEY_Page_Up:
        vk = VTERM_KEY_PAGEUP;
        break;
    case GDK_KEY_Page_Down:
        vk = VTERM_KEY_PAGEDOWN;
        break;
    default:
        break;
    }
    if (vk != VTERM_KEY_NONE) {
        vterm_keyboard_key(term->vt, vk, vm);
        return TRUE;
    }
    gunichar ch = gdk_keyval_to_unicode(keyval);
    if (ch != 0 && ch != 127) {
        vterm_keyboard_unichar(term->vt, ch, vm);
        return TRUE;
    }
    return FALSE;
}

void ft_term_write_len(FtTerm *term, const char *s, size_t n) {
    if (!term || term->pty_master < 0 || !s || n == 0) {
        return;
    }
    ssize_t w = write(term->pty_master, s, n);
    (void)w;
}

void ft_term_write(FtTerm *term, const char *s) {
    if (!s) {
        return;
    }
    ft_term_write_len(term, s, strlen(s));
}

int ft_term_send_chord(FtTerm *term, const char *chord) {
    char bytes[16];
    if (ft_key_chord_bytes(chord, bytes, sizeof(bytes)) != 0) {
        return -1;
    }
    ft_term_write(term, bytes);
    return 0;
}

void ft_term_apply_prefs(FtTerm *term, const FtPrefs *prefs) {
    if (!term || !prefs) {
        return;
    }
    ft_str_set(term->font, sizeof(term->font), prefs->font);
    term->font_size = prefs->font_size;
    memcpy(term->palette, prefs->palette, sizeof(term->palette));
    memcpy(term->background, prefs->background, 3);
    memcpy(term->foreground, prefs->foreground, 3);
    if (term->area) {
        gtk_widget_queue_draw(term->area);
    }
}

int ft_term_foreground(FtTerm *term, char *out, size_t n) {
    if (!term || term->pty_master < 0 || !out || n == 0) {
        return -1;
    }
    pid_t pgid = 0;
    if (ioctl(term->pty_master, TIOCGPGRP, &pgid) < 0 || pgid <= 0) {
        return -1;
    }
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/comm", (int)pgid);
    FILE *f = fopen(path, "r");
    if (!f) {
        return -1;
    }
    if (!fgets(out, (int)n, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    size_t len = strlen(out);
    while (len && (out[len - 1] == '\n' || out[len - 1] == '\r')) {
        out[--len] = 0;
    }
    return 0;
}

void ft_term_dump(FtTerm *term, GString *out) {
    if (!term || !out) {
        return;
    }
    for (int r = 0; r < term->rows; r++) {
        char line[1024];
        size_t n = 0;
        int last = -1;
        for (int c = 0; c < term->cols && n + 8 < sizeof(line); c++) {
            VTermPos pos = {.row = r, .col = c};
            VTermScreenCell cell;
            memset(&cell, 0, sizeof(cell));
            vterm_screen_get_cell(term->screen, pos, &cell);
            if (cell.chars[0] == 0) {
                line[n++] = ' ';
                continue;
            }
            int len = g_unichar_to_utf8((gunichar)cell.chars[0], line + n);
            n += (size_t)len;
            last = (int)n;
        }
        if (last > 0) {
            g_string_append_len(out, line, last);
        }
        g_string_append_c(out, '\n');
    }
}

static int term_cell_utf8(void *user, int row, int col, char *utf8, size_t n) {
    FtTerm *term = user;
    if (!term || !term->screen || n < 2) {
        return 0;
    }
    VTermPos pos = {.row = row, .col = col};
    VTermScreenCell cell;
    memset(&cell, 0, sizeof(cell));
    vterm_screen_get_cell(term->screen, pos, &cell);
    if (cell.chars[0] == 0) {
        return 0;
    }
    int len = g_unichar_to_utf8((gunichar)cell.chars[0], utf8);
    if (len < 0 || (size_t)len >= n) {
        return 0;
    }
    utf8[len] = 0;
    return len;
}

int ft_term_has_selection(const FtTerm *term) {
    return term && term->sel.on;
}

int ft_term_copy_selection(FtTerm *term, char *out, size_t n) {
    if (!term || !out || n == 0) {
        return -1;
    }
    return ft_sel_copy_cells(&term->sel, term->cols > 0 ? term->cols : 80, term_cell_utf8, term, out, n);
}

void ft_term_select_all(FtTerm *term) {
    if (!term) {
        return;
    }
    ft_sel_all(&term->sel, term->rows > 0 ? term->rows : 24, term->cols > 0 ? term->cols : 80);
    if (term->area) {
        gtk_widget_queue_draw(term->area);
    }
}

static void paste_done(GObject *src, GAsyncResult *res, gpointer user) {
    GtkWidget *area = user;
    FtTerm *term = g_object_get_data(G_OBJECT(area), "ft-term");
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, NULL);
    if (term && text && text[0]) {
        ft_term_write(term, text);
    }
    g_free(text);
}

void ft_term_request_paste(FtTerm *term) {
    if (!term || !term->area) {
        return;
    }
    GdkClipboard *cb = gtk_widget_get_clipboard(term->area);
    gdk_clipboard_read_text_async(cb, NULL, paste_done, term->area);
}

static void cell_at(FtTerm *term, double x, double y, int *row, int *col) {
    int cw = term->cell_w > 0 ? term->cell_w : 8;
    int ch = term->cell_h > 0 ? term->cell_h : 16;
    int c = (int)(x / cw);
    int r = (int)(y / ch);
    if (c < 0) {
        c = 0;
    }
    if (r < 0) {
        r = 0;
    }
    if (term->cols > 0 && c >= term->cols) {
        c = term->cols - 1;
    }
    if (term->rows > 0 && r >= term->rows) {
        r = term->rows - 1;
    }
    *row = r;
    *col = c;
}

static uint32_t cell_char(FtTerm *term, int row, int col) {
    VTermPos pos = {.row = row, .col = col};
    VTermScreenCell cell;
    memset(&cell, 0, sizeof(cell));
    vterm_screen_get_cell(term->screen, pos, &cell);
    return cell.chars[0];
}

static int word_char(uint32_t ch) {
    if (ch == 0 || ch == ' ') {
        return 0;
    }
    return g_unichar_isalnum(ch) || ch == '_' || ch == '-' || ch == '.' || ch == '/' || ch == '~';
}

static void select_word(FtTerm *term, int row, int col) {
    int a = col, b = col;
    while (a > 0 && word_char(cell_char(term, row, a - 1))) {
        a--;
    }
    int maxc = term->cols > 0 ? term->cols - 1 : col;
    while (b < maxc && word_char(cell_char(term, row, b + 1))) {
        b++;
    }
    ft_sel_begin(&term->sel, row, a);
    ft_sel_update(&term->sel, row, b);
}

static void on_click_pressed(GtkGestureClick *g, gint n_press, gdouble x, gdouble y, gpointer user) {
    FtTerm *term = user;
    guint btn = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g));
    if (btn == GDK_BUTTON_MIDDLE) {
        GdkClipboard *prim = gdk_display_get_primary_clipboard(gdk_display_get_default());
        if (prim && term->area) {
            gdk_clipboard_read_text_async(prim, NULL, paste_done, term->area);
        }
        return;
    }
    if (btn != GDK_BUTTON_PRIMARY) {
        return;
    }
    gtk_widget_grab_focus(term->area);
    int row, col;
    cell_at(term, x, y, &row, &col);
    if (n_press >= 3) {
        ft_sel_begin(&term->sel, row, 0);
        ft_sel_update(&term->sel, row, term->cols > 0 ? term->cols - 1 : col);
        term->selecting = 0;
    } else if (n_press == 2) {
        select_word(term, row, col);
        term->selecting = 0;
    } else {
        ft_sel_begin(&term->sel, row, col);
        term->selecting = 1;
    }
    gtk_widget_queue_draw(term->area);
}

static void on_click_released(GtkGestureClick *g, gint n_press, gdouble x, gdouble y, gpointer user) {
    (void)g;
    (void)n_press;
    (void)x;
    (void)y;
    FtTerm *term = user;
    term->selecting = 0;
    if (term->sel.on && term->sel.a_row == term->sel.b_row && term->sel.a_col == term->sel.b_col) {
        ft_sel_clear(&term->sel);
        gtk_widget_queue_draw(term->area);
    } else if (term->sel.on && term->area) {
        char buf[65536];
        if (ft_term_copy_selection(term, buf, sizeof(buf)) > 0) {
            GdkClipboard *prim = gdk_display_get_primary_clipboard(gdk_display_get_default());
            if (prim) {
                gdk_clipboard_set_text(prim, buf);
            }
        }
    }
}

static void on_motion(GtkEventControllerMotion *ctl, gdouble x, gdouble y, gpointer user) {
    (void)ctl;
    FtTerm *term = user;
    if (!term->selecting) {
        return;
    }
    int row, col;
    cell_at(term, x, y, &row, &col);
    ft_sel_update(&term->sel, row, col);
    gtk_widget_queue_draw(term->area);
}

static gboolean on_term_key(GtkEventControllerKey *ctl, guint keyval, guint keycode, GdkModifierType mods, gpointer user) {
    (void)ctl;
    (void)keycode;
    return ft_term_key(user, keyval, mods);
}

FtTerm *ft_term_new(const char *session, const char *cwd, const char *zmx_path) {
    FtTerm *term = g_new0(FtTerm, 1);
    term->pty_master = -1;
    term->cols = 80;
    term->rows = 24;
    term->cell_w = 8;
    term->cell_h = 16;
    ft_str_set(term->font, sizeof(term->font), "Monospace");
    term->font_size = 12;
    static const uint8_t defpal[16][3] = {
        {0, 0, 0},       {170, 0, 0},     {0, 170, 0},     {170, 85, 0},
        {0, 0, 170},     {170, 0, 170},   {0, 170, 170},   {170, 170, 170},
        {85, 85, 85},    {255, 85, 85},   {85, 255, 85},   {255, 255, 85},
        {85, 85, 255},   {255, 85, 255},   {85, 255, 255},  {255, 255, 255},
    };
    memcpy(term->palette, defpal, sizeof(defpal));
    term->background[0] = 18;
    term->background[1] = 20;
    term->background[2] = 26;
    term->foreground[0] = 220;
    term->foreground[1] = 220;
    term->foreground[2] = 220;
    snprintf(term->session, sizeof(term->session), "%s", session ? session : "futuraterm-linux");
    snprintf(term->project_path, sizeof(term->project_path), "%s", cwd ? cwd : "");
    if (zmx_path) {
        snprintf(term->zmx_path, sizeof(term->zmx_path), "%s", zmx_path);
    }
    term->vt = vterm_new(term->rows, term->cols);
    vterm_set_utf8(term->vt, 1);
    term->screen = vterm_obtain_screen(term->vt);
    vterm_screen_set_callbacks(term->screen, &screen_cbs, term);
    vterm_screen_reset(term->screen, 1);
    vterm_output_set_callback(term->vt, vterm_output, term);
    if (spawn_session(term, cwd) != 0) {
        vterm_free(term->vt);
        g_free(term);
        return NULL;
    }
    term->area = gtk_drawing_area_new();
    gtk_widget_set_hexpand(term->area, TRUE);
    gtk_widget_set_vexpand(term->area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(term->area), draw_term, term, NULL);
    gtk_widget_set_focusable(term->area, TRUE);
    g_object_set_data(G_OBJECT(term->area), "ft-term", term);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_term_key), term);
    gtk_widget_add_controller(term->area, keys);
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(on_click_pressed), term);
    g_signal_connect(click, "released", G_CALLBACK(on_click_released), term);
    gtk_widget_add_controller(term->area, GTK_EVENT_CONTROLLER(click));
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), term);
    gtk_widget_add_controller(term->area, motion);
    return term;
}

void ft_term_free(FtTerm *term) {
    if (!term) {
        return;
    }
    if (term->pty_src) {
        g_source_remove(term->pty_src);
        term->pty_src = 0;
    }
    if (term->child > 0) {
        kill(term->child, SIGHUP);
        term->child = 0;
    }
    if (term->pty_master >= 0) {
        close(term->pty_master);
        term->pty_master = -1;
    }
    if (term->vt) {
        vterm_free(term->vt);
        term->vt = NULL;
    }
    if (term->area) {
        g_object_set_data(G_OBJECT(term->area), "ft-term", NULL);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(term->area), NULL, NULL, NULL);
        if (gtk_widget_get_parent(term->area)) {
            g_object_ref(term->area);
            gtk_widget_unparent(term->area);
            g_object_unref(term->area);
        }
        term->area = NULL;
    }
    g_free(term);
}
