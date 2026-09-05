#ifndef FUTURATERM_LINUX_TERM_H
#define FUTURATERM_LINUX_TERM_H

#include <gtk/gtk.h>
#include <vterm.h>

typedef struct FtTerm FtTerm;

struct FtTerm {
    char session[80];
    char project_path[512];
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
    void (*title_cb)(FtTerm *term, const char *title, void *user);
    void *title_user;
};

FtTerm *ft_term_new(const char *session, const char *cwd);
void ft_term_free(FtTerm *term);
void ft_term_write(FtTerm *term, const char *s);
void ft_term_dump(FtTerm *term, GString *out);
gboolean ft_term_key(FtTerm *term, guint keyval, GdkModifierType mods);

#endif
