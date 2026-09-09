#ifndef FUTURATERM_LINUX_PATH_H
#define FUTURATERM_LINUX_PATH_H

#include <stddef.h>

typedef enum {
    FT_PATH_INVALID = 0,
    FT_PATH_LOCAL = 1,
    FT_PATH_REMOTE = 2,
    FT_PATH_PINNED = 3
} FtPathKind;

typedef struct {
    FtPathKind kind;
    char user[64];
    char host[128];
    char dir[512];
    char raw[512];
} FtProjectPath;

#define FT_PINNED_PATH_MARKER "<pinned>"

int ft_path_parse(const char *raw, FtProjectPath *out);
int ft_path_is_remote(const char *raw);
int ft_path_is_local(const char *raw);
int ft_path_matches(const char *a, const char *b);
void ft_path_canonical_local(const char *path, char *out, size_t n);
void ft_path_home_contract(const char *path, char *out, size_t n);
void ft_path_destination(const FtProjectPath *p, char *out, size_t n);
void ft_path_display_name(const char *raw, char *out, size_t n);

#endif
