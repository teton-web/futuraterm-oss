#ifndef FUTURATERM_LINUX_SEL_H
#define FUTURATERM_LINUX_SEL_H

#include <stddef.h>

typedef struct {
    int on;
    int a_row;
    int a_col;
    int b_row;
    int b_col;
} FtSel;

void ft_sel_clear(FtSel *s);
void ft_sel_begin(FtSel *s, int row, int col);
void ft_sel_update(FtSel *s, int row, int col);
void ft_sel_all(FtSel *s, int rows, int cols);
int ft_sel_ordered(const FtSel *s, int *r0, int *c0, int *r1, int *c1);
int ft_sel_contains(const FtSel *s, int row, int col);

/// Copy selected cells. `cell` writes UTF-8 for (row,col) and returns byte
/// length (0 = empty cell). Inclusive stream bounds. `cols` is the line
/// width used for first/middle rows of a multi-line selection.
int ft_sel_copy_cells(
    const FtSel *s,
    int cols,
    int (*cell)(void *user, int row, int col, char *utf8, size_t n),
    void *user,
    char *out,
    size_t n
);

/// ASCII-grid wrapper around ft_sel_copy_cells (one byte per column).
int ft_sel_copy_rect(const char *const *rows, int nrows, const FtSel *s, char *out, size_t n);

#endif
