#ifndef FUTURATERM_LINUX_SPLIT_H
#define FUTURATERM_LINUX_SPLIT_H

#include <stddef.h>

enum { FT_SPLIT_H = 0, FT_SPLIT_V = 1 };
enum { FT_DIR_LEFT = 0, FT_DIR_RIGHT = 1, FT_DIR_UP = 2, FT_DIR_DOWN = 3 };

typedef struct FtNode FtNode;
struct FtNode {
    int is_split;
    char pane_id[40];
    char session[80];
    char cwd[512];
    char run[512];
    char shell[256];
    int dir;
    double ratio;
    FtNode *first;
    FtNode *second;
};

FtNode *ft_node_pane(const char *session, const char *cwd);
FtNode *ft_node_split(int dir, FtNode *first, FtNode *second, double ratio);
void ft_node_free(FtNode *n);
FtNode *ft_node_clone(const FtNode *n);
FtNode *ft_node_find(FtNode *n, const char *session);
int ft_node_collect(FtNode *n, FtNode **out, int max);
int ft_node_count(FtNode *n);
int ft_node_split_at(FtNode **root, const char *session, int dir, FtNode *fresh);
int ft_node_close(FtNode **root, const char *session);
const char *ft_node_neighbor(FtNode *root, const char *session, int want_dir);
const char *ft_node_cycle(FtNode *root, const char *session, int delta);
int ft_node_resize(FtNode *root, const char *session, int want_dir, double delta);
int ft_node_set_ratio(FtNode *root, const char *session, int axis, double ratio);
FtNode *ft_node_detach(FtNode **root, const char *session);
int ft_node_detach_all(FtNode **root, FtNode **out, int max);
int ft_node_grid(FtNode **root, const char *session, int rows, int cols, FtNode **created, int max_created);

#endif
