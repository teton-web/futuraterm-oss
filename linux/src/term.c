#define _GNU_SOURCE
#include "term.h"
#include "session.h"

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

static const uint8_t palette[16][3] = {
    {0, 0, 0},       {170, 0, 0},     {0, 170, 0},     {170, 85, 0},
    {0, 0, 170},     {170, 0, 170},   {0, 170, 170},   {170, 170, 170},
    {85, 85, 85},    {255, 85, 85},   {85, 255, 85},   {255, 255, 85},
    {85, 85, 255},   {255, 85, 255},   {85, 255, 255},  {255, 255, 255},
};

static void color_rgb(FtTerm *term, const VTermColor *c, VTermColor *def, double *r, double *g, double *b) {
    VTermColor tmp = *c;
    vterm_screen_convert_color_to_rgb(term->screen, &tmp);
    if (VTERM_COLOR_IS_DEFAULT_FG(&tmp) && def) {
        tmp = *def;
        vterm_screen_convert_color_to_rgb(term->screen, &tmp);
    }
    if (VTERM_COLOR_IS_INDEXED(&tmp)) {
        int idx = tmp.indexed.idx & 15;
        *r = palette[idx][0] / 255.0;
        *g = palette[idx][1] / 255.0;
        *b = palette[idx][2] / 255.0;
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

static gboolean pty_read(gint fd, GIOCondition cond, gpointer user) {
    FtTerm *term = user;
    if (cond & (G_IO_HUP | G_IO_ERR)) {
        return G_SOURCE_REMOVE;
    }
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n > 0) {
        vterm_input_write(term->vt, buf, (size_t)n);
        vterm_screen_flush_damage(term->screen);
    } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
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
    const char *argv[4];
    int have_zmx = ft_linux_zmx_attach_argv(term->session, zmx, sizeof(zmx), argv) == 0;
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
        if (cwd && cwd[0] && chdir(cwd) != 0) {
            /* stay in inherited cwd */
        }
        if (have_zmx) {
            execv(argv[0], (char *const *)argv);
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
    PangoFontDescription *font = pango_font_description_from_string("Monospace 12");
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
    cairo_set_source_rgb(cr, 0.07, 0.08, 0.10);
    cairo_paint(cr);
    PangoFontDescription *font = pango_font_description_from_string("Monospace 12");
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

void ft_term_write(FtTerm *term, const char *s) {
    if (!term || term->pty_master < 0 || !s) {
        return;
    }
    size_t n = strlen(s);
    if (n > 0) {
        ssize_t w = write(term->pty_master, s, n);
        (void)w;
    }
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

static gboolean on_term_key(GtkEventControllerKey *ctl, guint keyval, guint keycode, GdkModifierType mods, gpointer user) {
    (void)ctl;
    (void)keycode;
    return ft_term_key(user, keyval, mods);
}

FtTerm *ft_term_new(const char *session, const char *cwd) {
    FtTerm *term = g_new0(FtTerm, 1);
    term->pty_master = -1;
    term->cols = 80;
    term->rows = 24;
    term->cell_w = 8;
    term->cell_h = 16;
    snprintf(term->session, sizeof(term->session), "%s", session ? session : "futuraterm-linux");
    snprintf(term->project_path, sizeof(term->project_path), "%s", cwd ? cwd : "");
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
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_term_key), term);
    gtk_widget_add_controller(term->area, keys);
    return term;
}

void ft_term_free(FtTerm *term) {
    if (!term) {
        return;
    }
    if (term->pty_src) {
        g_source_remove(term->pty_src);
    }
    if (term->child > 0) {
        kill(term->child, SIGHUP);
    }
    if (term->pty_master >= 0) {
        close(term->pty_master);
    }
    if (term->vt) {
        vterm_free(term->vt);
    }
    g_free(term);
}
