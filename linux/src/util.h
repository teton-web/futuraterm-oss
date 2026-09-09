#ifndef FUTURATERM_LINUX_UTIL_H
#define FUTURATERM_LINUX_UTIL_H

#include <stddef.h>

void ft_str_set(char *dst, size_t n, const char *src);
int ft_str_eq(const char *a, const char *b);
int ft_str_ieq(const char *a, const char *b);
void ft_uuid(char *out);
int ft_mkdir_p(const char *path);
int ft_read_file(const char *path, char *out, size_t n);
int ft_write_file(const char *path, const char *s);

/* Locate `"key":` and copy a JSON string / number / bool. Returns 0 on hit. */
int ft_json_str(const char *json, const char *key, char *out, size_t n);
int ft_json_int(const char *json, const char *key, int *out);
int ft_json_bool(const char *json, const char *key, int *out);
int ft_json_double(const char *json, const char *key, double *out);
void ft_json_esc(const char *s, char *out, size_t n);

/* Raw JSON value span after `"key":` (string includes quotes). */
const char *ft_json_raw(const char *json, const char *key, int *len);

/* Walk a JSON array `[...]`; cb gets each element's span. */
int ft_json_array(const char *json, int (*cb)(const char *elem, int len, void *user), void *user);

void ft_xdg_data(char *out, size_t n);
void ft_xdg_config(char *out, size_t n);
void ft_xdg_runtime(char *out, size_t n);

int ft_is_shell_name(const char *comm);

typedef struct {
    char *s;
    size_t n;
    size_t i;
} FtBuf;

void ft_buf_init(FtBuf *b, char *s, size_t n);
int ft_buf_printf(FtBuf *b, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 2, 3)))
#endif
    ;

#endif
