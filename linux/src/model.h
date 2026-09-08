#ifndef FUTURATERM_LINUX_MODEL_H
#define FUTURATERM_LINUX_MODEL_H

#include "layout.h"
#include "split.h"

#include <stddef.h>

#define FT_MAX_PROJECTS 64
#define FT_MAX_TABS 32
#define FT_MAX_FOLDERS 32
#define FT_PINNED_ID "00000000-0000-4000-8000-000000000001"

typedef struct {
    char id[40];
    char title[64];
    int custom_title;
    char origin[40];
    int unloaded;
    int pinned;
    FtNode *root;
    FtNode *declaration;
    char focus[80];
    char zoom[80];
} FtTabRec;

typedef struct {
    char id[40];
    char name[64];
    char path[512];
    char zmx_path[256];
    char folder_id[40];
    int unloaded;
    FtTabRec tabs[FT_MAX_TABS];
    int ntabs;
    int active_tab;
    int recent_tab;
} FtProjectRec;

typedef struct {
    char id[40];
    char name[64];
    char parent[40];
    int expanded;
} FtFolderRec;

typedef struct FtModel {
    char data_dir[512];
    char config_dir[512];
    FtProjectRec projects[FT_MAX_PROJECTS];
    int nprojects;
    int active;
    FtProjectRec pinned;
    FtFolderRec folders[FT_MAX_FOLDERS];
    int nfolders;
    char add_folder[40];
    char error[256];
} FtModel;

FtModel *ft_model_new(const char *data_dir, const char *config_dir);
void ft_model_free(FtModel *m);
int ft_model_load(FtModel *m);
int ft_model_save(FtModel *m);

FtProjectRec *ft_model_active(FtModel *m);
FtProjectRec *ft_model_find_project(FtModel *m, const char *sel);
FtTabRec *ft_model_active_tab(FtModel *m);
FtNode *ft_model_focused_pane(FtModel *m);

int ft_model_project_create(FtModel *m, const char *path, const char *name, int select);
int ft_model_project_open(FtModel *m, const char *path, const char *name);
int ft_model_add_local(FtModel *m, const char *path);
int ft_model_add_remote(FtModel *m, const char *spec);
int ft_model_folder_create(FtModel *m, const char *name, const char *parent_id, char *id_out, size_t n);
FtFolderRec *ft_model_folder_find(FtModel *m, const char *id);
int ft_model_set_add_folder(FtModel *m, const char *folder_id);
int ft_model_project_select(FtModel *m, const char *sel);
int ft_model_project_rename(FtModel *m, const char *name);
int ft_model_project_unload(FtModel *m, const char *sel);
int ft_model_project_remove(FtModel *m, const char *sel);

int ft_model_tab_new(FtModel *m, const char *project_sel, const char *run, char *session_out, size_t n);
int ft_model_tab_select(FtModel *m, const char *tab_sel);
int ft_model_tab_close(FtModel *m, const char *tab_sel, int force, int (*busy)(void *, const char *), void *busy_user);
int ft_model_tab_move(FtModel *m, const char *tab_sel, int slot);
int ft_model_tab_rename(FtModel *m, const char *title);
int ft_model_tab_cycle(FtModel *m, int delta, int in_project);
int ft_model_tab_recent(FtModel *m);

int ft_model_split(FtModel *m, const char *session, const char *direction, const char *run, char *session_out, size_t n);
int ft_model_focus(FtModel *m, const char *session, const char *direction);
int ft_model_close_pane(FtModel *m, const char *session, int force, int (*busy)(void *, const char *), void *busy_user);
int ft_model_zoom(FtModel *m, const char *session);
int ft_model_resize(FtModel *m, const char *session, int dir, double delta);
int ft_model_grid(FtModel *m, const char *session, int rows, int cols, const char *run);
int ft_model_separate_pane(FtModel *m, const char *session);
int ft_model_separate_all(FtModel *m);
int ft_model_pin(FtModel *m);
int ft_model_unpin(FtModel *m);
int ft_model_restore_pinned(FtModel *m, const char *tab_sel);

int ft_model_save_layout(FtModel *m, const char *project_sel, char *written, size_t n);
int ft_model_apply_layout(FtModel *m, const char *project_sel, int force);

void ft_model_fill_sessions(FtModel *m, FtNode *n, const char *project_name, const char *cwd);
int ft_model_all_sessions(FtModel *m, char sessions[][80], int max);

#endif
