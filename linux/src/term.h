#ifndef FUTURATERM_LINUX_TERM_H
#define FUTURATERM_LINUX_TERM_H

#include "prefs.h"
#include "sel.h"

#include <gtk/gtk.h>
#include <vterm.h>

typedef struct FtTerm FtTerm;

struct FtTerm {
    char session[80];
    char project_path[512];
    char zmx_path[256];
    int remote;
    GtkWidget *area;
    VTerm *vt;
    VTermScreen *screen;
    int pty_master;
    pid_t child;
    guint pty_src;
    int cell_w;
    int cell_h;
    int cols;
    int rows;
    int exited;
    char font[128];
    int font_size;
    uint8_t palette[16][3];
    uint8_t background[3];
    uint8_t foreground[3];
    void (*title_cb)(FtTerm *term, const char *title, void *user);
    void *title_user;
    void (*exited_cb)(FtTerm *term, void *user);
    void *exited_user;
    FtSel sel;
    int selecting;
};

FtTerm *ft_term_new(const char *session, const char *cwd, const char *zmx_path);
void ft_term_free(FtTerm *term);
void ft_term_write(FtTerm *term, const char *s);
void ft_term_write_len(FtTerm *term, const char *s, size_t n);
void ft_term_dump(FtTerm *term, GString *out);
gboolean ft_term_key(FtTerm *term, guint keyval, GdkModifierType mods);
void ft_term_apply_prefs(FtTerm *term, const FtPrefs *prefs);
int ft_term_foreground(FtTerm *term, char *out, size_t n);
int ft_term_send_chord(FtTerm *term, const char *chord);
int ft_term_copy_selection(FtTerm *term, char *out, size_t n);
void ft_term_select_all(FtTerm *term);
void ft_term_request_paste(FtTerm *term);
int ft_term_has_selection(const FtTerm *term);

#endif
