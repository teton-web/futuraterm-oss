#define _GNU_SOURCE
#include "sel.h"

#include <string.h>

void ft_sel_clear(FtSel *s) {
    if (s) {
        memset(s, 0, sizeof(*s));
    }
}

void ft_sel_begin(FtSel *s, int row, int col) {
    if (!s) {
        return;
    }
    s->on = 1;
    s->a_row = s->b_row = row < 0 ? 0 : row;
    s->a_col = s->b_col = col < 0 ? 0 : col;
}

void ft_sel_update(FtSel *s, int row, int col) {
    if (!s || !s->on) {
        return;
    }
    s->b_row = row < 0 ? 0 : row;
    s->b_col = col < 0 ? 0 : col;
}

void ft_sel_all(FtSel *s, int rows, int cols) {
    if (!s) {
        return;
    }
    if (rows < 1) {
        rows = 1;
    }
    if (cols < 1) {
        cols = 1;
    }
    s->on = 1;
    s->a_row = 0;
    s->a_col = 0;
    s->b_row = rows - 1;
    s->b_col = cols - 1;
}

int ft_sel_ordered(const FtSel *s, int *r0, int *c0, int *r1, int *c1) {
    if (!s || !s->on) {
        return 0;
    }
    int ar = s->a_row, ac = s->a_col, br = s->b_row, bc = s->b_col;
    if (ar > br || (ar == br && ac > bc)) {
        int tr = ar, tc = ac;
        ar = br;
        ac = bc;
        br = tr;
        bc = tc;
    }
    if (r0) {
        *r0 = ar;
    }
    if (c0) {
        *c0 = ac;
    }
    if (r1) {
        *r1 = br;
    }
    if (c1) {
        *c1 = bc;
    }
    return 1;
}

int ft_sel_contains(const FtSel *s, int row, int col) {
    int r0, c0, r1, c1;
    if (!ft_sel_ordered(s, &r0, &c0, &r1, &c1)) {
        return 0;
    }
    if (row < r0 || row > r1) {
        return 0;
    }
    if (r0 == r1) {
        return col >= c0 && col <= c1;
    }
    if (row == r0) {
        return col >= c0;
    }
    if (row == r1) {
        return col <= c1;
    }
    return 1;
}

int ft_sel_copy_cells(
    const FtSel *s,
    int cols,
    int (*cell)(void *user, int row, int col, char *utf8, size_t n),
    void *user,
    char *out,
    size_t n
) {
    if (!s || !cell || !out || n == 0) {
        return -1;
    }
    out[0] = 0;
    int r0, c0, r1, c1;
    if (!ft_sel_ordered(s, &r0, &c0, &r1, &c1)) {
        return 0;
    }
    if (cols < 1) {
        cols = 1;
    }
    size_t i = 0;
    for (int r = r0; r <= r1; r++) {
        int from;
        int to;
        if (r0 == r1) {
            from = c0;
            to = c1;
        } else if (r == r0) {
            from = c0;
            to = cols - 1;
        } else if (r == r1) {
            from = 0;
            to = c1;
        } else {
            from = 0;
            to = cols - 1;
        }
        char line[4096];
        size_t ln = 0;
        int last = -1;
        for (int c = from; c <= to && ln + 8 < sizeof(line); c++) {
            char utf8[8];
            int k = cell(user, r, c, utf8, sizeof(utf8));
            if (k <= 0) {
                line[ln++] = ' ';
                continue;
            }
            memcpy(line + ln, utf8, (size_t)k);
            ln += (size_t)k;
            if (!(k == 1 && utf8[0] == ' ')) {
                last = (int)ln;
            }
        }
        if (r > r0) {
            if (i + 1 >= n) {
                out[n - 1] = 0;
                return -1;
            }
            out[i++] = '\n';
        }
        size_t take = last > 0 ? (size_t)last : 0;
        if (i + take + 1 >= n) {
            out[n - 1] = 0;
            return -1;
        }
        if (take) {
            memcpy(out + i, line, take);
            i += take;
        }
    }
    out[i] = 0;
    return (int)i;
}

typedef struct {
    const char *const *rows;
    int nrows;
} FtSelGrid;

static int grid_cell(void *user, int row, int col, char *utf8, size_t n) {
    FtSelGrid *g = user;
    if (!g || row < 0 || row >= g->nrows || !g->rows[row] || n < 2) {
        return 0;
    }
    const char *s = g->rows[row];
    int len = (int)strlen(s);
    if (col < 0 || col >= len) {
        return 0;
    }
    utf8[0] = s[col];
    utf8[1] = 0;
    return 1;
}

int ft_sel_copy_rect(const char *const *rows, int nrows, const FtSel *s, char *out, size_t n) {
    FtSelGrid g = {.rows = rows, .nrows = nrows};
    int cols = 1;
    for (int r = 0; r < nrows; r++) {
        int L = rows[r] ? (int)strlen(rows[r]) : 0;
        if (L > cols) {
            cols = L;
        }
    }
    return ft_sel_copy_cells(s, cols, grid_cell, &g, out, n);
}
