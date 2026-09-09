#include "../src/model.h"
#include "../src/path.h"
#include "../src/session.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;

static void expect(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        fails++;
    }
}

int main(void) {
    char data[] = "/tmp/ft-model-data-XXXXXX";
    char cfg[] = "/tmp/ft-model-cfg-XXXXXX";
    if (!mkdtemp(data) || !mkdtemp(cfg)) {
        perror("mkdtemp");
        return 1;
    }

    FtModel *m = ft_model_new(data, cfg);
    expect(ft_model_load(m) == 0, "first load seeds Home");
    expect(m->nprojects >= 1, "has a project");
    expect(!ft_path_is_remote(m->projects[0].path), "seeded project is local");

    expect(ft_model_project_open(m, "/tmp/ft-model-proj", "Demo") == 0, "open");
    char sess[80];
    expect(ft_model_tab_new(m, NULL, "echo hi", sess, sizeof(sess)) == 0, "tab new");
    expect(strncmp(sess, "futuraterm-demo-", 16) == 0 || strncmp(sess, "futuraterm-Demo-", 16) == 0 || strstr(sess, "futuraterm-") == sess, "session prefix");
    expect(strlen(sess) >= 16 + 12, "session has hex");

    char split_sess[80];
    expect(ft_model_split(m, sess, "right", NULL, split_sess, sizeof(split_sess)) == 0, "split");
    expect(strcmp(sess, split_sess) != 0, "new pane session");

    expect(ft_model_save(m) == 0, "save");
    char keep_a[80], keep_b[80];
    snprintf(keep_a, sizeof(keep_a), "%s", sess);
    snprintf(keep_b, sizeof(keep_b), "%s", split_sess);
    ft_model_free(m);

    m = ft_model_new(data, cfg);
    expect(ft_model_load(m) == 0, "reload");
    char sessions[32][80];
    int ns = ft_model_all_sessions(m, sessions, 32);
    int saw_a = 0, saw_b = 0;
    for (int i = 0; i < ns; i++) {
        if (strcmp(sessions[i], keep_a) == 0) {
            saw_a = 1;
        }
        if (strcmp(sessions[i], keep_b) == 0) {
            saw_b = 1;
        }
    }
    expect(saw_a && saw_b, "reattach keeps session names");

    char yaml_path[768];
    expect(ft_model_save_layout(m, NULL, yaml_path, sizeof(yaml_path)) == 0, "save layout");
    expect(strstr(yaml_path, ".yaml") != NULL, "layout yaml");

    char before_apply[32][80];
    int n_before = ft_model_all_sessions(m, before_apply, 32);
    expect(n_before >= 2, "live panes before apply");
    expect(ft_model_apply_layout(m, NULL, 1) == 0, "apply layout");
    char after_apply[32][80];
    int n_after = ft_model_all_sessions(m, after_apply, 32);
    int matched = 0;
    for (int i = 0; i < n_before; i++) {
        for (int j = 0; j < n_after; j++) {
            if (strcmp(before_apply[i], after_apply[j]) == 0) {
                matched++;
                break;
            }
        }
    }
    expect(matched == n_before, "apply reuses live (run,cwd) session names");
    expect(n_after == n_before, "apply does not mint extra hex names for matched leaves");

    char unload_sess[80];
    snprintf(unload_sess, sizeof(unload_sess), "%s", keep_a);
    expect(ft_model_project_unload(m, "Demo") == 0, "unload");
    FtProjectRec *demo = ft_model_find_project(m, "Demo");
    expect(demo && demo->unloaded, "project marked unloaded");
    expect(demo->ntabs >= 1 && demo->tabs[0].root != NULL, "unload keeps the split tree");
    char after_unload[32][80];
    int n_un = ft_model_all_sessions(m, after_unload, 32);
    int still = 0;
    for (int i = 0; i < n_un; i++) {
        if (strcmp(after_unload[i], unload_sess) == 0) {
            still = 1;
        }
    }
    expect(still, "unload does not drop session names (no kill)");
    expect(ft_model_project_select(m, "Demo") == 0, "select reloads");
    expect(demo->unloaded == 0, "select clears unloaded");

    expect(ft_model_pin(m) == 0, "pin is a move");
    expect(m->active == -2, "pinned workspace active");
    expect(m->pinned.ntabs >= 1, "pinned has tab");
    int demo_tabs = 0;
    for (int i = 0; i < m->nprojects; i++) {
        if (strcmp(m->projects[i].name, "Demo") == 0) {
            demo_tabs = m->projects[i].ntabs;
        }
    }
    expect(demo_tabs >= 1, "origin project still has a tab after pin (not a kill)");

    FtTabRec *pinned = &m->pinned.tabs[m->pinned.active_tab];
    expect(pinned->root != NULL, "pinned tab has a tree");
    FtNode *pin_panes[8];
    int n_pin = ft_node_collect(pinned->root, pin_panes, 8);
    expect(n_pin >= 1, "pinned has panes");
    char pin_sess[80];
    snprintf(pin_sess, sizeof(pin_sess), "%s", pin_panes[0]->session);
    expect(pinned->declaration != NULL, "pin captures a declaration");
    char pin_id[40];
    snprintf(pin_id, sizeof(pin_id), "%s", pinned->id);

    expect(ft_model_tab_close(m, pin_id, 1, NULL, NULL) == 0, "pinned close unloads");
    expect(m->pinned.ntabs >= 1, "close keeps the pinned row");
    FtTabRec *dimmed = NULL;
    for (int i = 0; i < m->pinned.ntabs; i++) {
        if (strcmp(m->pinned.tabs[i].id, pin_id) == 0) {
            dimmed = &m->pinned.tabs[i];
        }
    }
    expect(dimmed != NULL && dimmed->unloaded, "dimmed unloaded row");
    expect(dimmed->root != NULL || dimmed->declaration != NULL, "declaration/tree kept");
    FtNode *kept = dimmed->root ? dimmed->root : dimmed->declaration;
    FtNode *kept_panes[8];
    int n_kept = ft_node_collect(kept, kept_panes, 8);
    int same_tree = 0;
    for (int i = 0; i < n_kept; i++) {
        if (strcmp(kept_panes[i]->session, pin_sess) == 0) {
            same_tree = 1;
        }
    }
    expect(same_tree, "unload keeps the same session on the tree");

    expect(ft_model_tab_select(m, pin_id) == 0, "select dimmed row restores");
    expect(dimmed->unloaded == 0, "restored");
    expect(dimmed->root != NULL, "restore has a live tree");
    FtNode *restored[8];
    int n_rest = ft_node_collect(dimmed->root, restored, 8);
    int same_sess = 0;
    for (int i = 0; i < n_rest; i++) {
        if (strcmp(restored[i]->session, pin_sess) == 0) {
            same_sess = 1;
        }
    }
    expect(same_sess, "restore reattaches the same session, not a blank mint");
    expect(n_rest == n_pin, "restore keeps split arity");

    expect(ft_model_unpin(m) == 0, "unpin");
    expect(m->active >= 0, "back in a project");

    ft_model_free(m);

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_model: ok");
    return 0;
}
