#ifndef FUTURATERM_LINUX_LAYOUT_H
#define FUTURATERM_LINUX_LAYOUT_H

#include "split.h"

#include <stddef.h>

#define FT_LAYOUT_MAX_TABS 32

typedef struct FtLayoutFile {
    char name[64];
    char path[512];
    char zmx_path[256];
    FtNode *tabs[FT_LAYOUT_MAX_TABS];
    char tab_names[FT_LAYOUT_MAX_TABS][64];
    int ntabs;
} FtLayoutFile;

void ft_layout_free(FtLayoutFile *f);
int ft_layout_parse(const char *yaml, FtLayoutFile *out);
int ft_layout_emit(const FtLayoutFile *f, char *out, size_t n);
int ft_layout_from_tree(const char *name, const char *path, FtNode **tab_roots, const char **tab_names, int ntabs, FtLayoutFile *out);
int ft_layout_slug(const char *name, char *out, size_t n);
int ft_layout_write_dir(const FtLayoutFile *f, const char *dir, char *written_path, size_t n);
int ft_layout_load_path(const char *path, FtLayoutFile *out);
int ft_layout_find_for_project(const char *dir, const char *project_path, const char *name, char *found, size_t n);

#endif
