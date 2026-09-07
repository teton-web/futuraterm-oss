#ifndef FUTURATERM_LINUX_CONTROL_H
#define FUTURATERM_LINUX_CONTROL_H

#include "model.h"

#include <stddef.h>

typedef struct {
    char id[80];
    char command[64];
    char project[128];
    char tab[128];
    char pane[80];
    char session[80];
    char path[512];
    char name[128];
    char run[1024];
    char direction[24];
    char key[64];
    char axis[24];
    int rows;
    int cols;
    int slot;
    int select;
    int reuse;
    int force;
    int has_reuse;
    double ratio;
} FtControlReq;

typedef struct {
    int (*dump)(void *user, const char *session, char *out, size_t n);
    int (*run)(void *user, const char *session, const char *cmd);
    int (*key)(void *user, const char *session, const char *chord);
    int (*session_list)(void *user, char *out, size_t n);
    int (*session_info)(void *user, const char *name, char *out, size_t n);
    int (*session_kill)(void *user, const char *name);
    int (*busy)(void *user, const char *session);
    void *user;
} FtControlHooks;

const char *const *ft_control_public_commands(int *count);
int ft_control_known(const char *command);
int ft_control_parse(const char *json, FtControlReq *req);
int ft_control_dispatch(FtModel *m, const FtControlReq *req, const FtControlHooks *hooks, char *out, size_t n);

#endif
