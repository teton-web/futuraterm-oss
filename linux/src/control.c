#define _GNU_SOURCE
#include "control.h"

#include "path.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *k_public[] = {
    "status",
    "project.list",
    "project.create",
    "project.open",
    "project.select",
    "tab.list",
    "tab.new",
    "tab.select",
    "tab.move",
    "tab.close",
    "pane.list",
    "pane.dump",
    "pane.run",
    "pane.split",
    "pane.focus",
    "pane.close",
    "pane.key",
    "pane.zoom",
    "grid",
    "session.list",
    "session.info",
    "session.kill",
    "layout.apply",
    "layout.save",
};

const char *const *ft_control_public_commands(int *count) {
    if (count) {
        *count = (int)(sizeof(k_public) / sizeof(k_public[0]));
    }
    return k_public;
}

int ft_control_known(const char *command) {
    int n = 0;
    const char *const *all = ft_control_public_commands(&n);
    for (int i = 0; i < n; i++) {
        if (strcmp(all[i], command) == 0) {
            return 1;
        }
    }
    return 0;
}

int ft_control_parse(const char *json, FtControlReq *req) {
    memset(req, 0, sizeof(*req));
    ft_str_set(req->id, sizeof(req->id), "0");
    if (!json) {
        return -1;
    }
    ft_json_str(json, "id", req->id, sizeof(req->id));
    ft_json_str(json, "command", req->command, sizeof(req->command));
    ft_json_str(json, "project", req->project, sizeof(req->project));
    ft_json_str(json, "tab", req->tab, sizeof(req->tab));
    ft_json_str(json, "pane", req->pane, sizeof(req->pane));
    ft_json_str(json, "session", req->session, sizeof(req->session));
    ft_json_str(json, "path", req->path, sizeof(req->path));
    ft_json_str(json, "name", req->name, sizeof(req->name));
    ft_json_str(json, "run", req->run, sizeof(req->run));
    ft_json_str(json, "direction", req->direction, sizeof(req->direction));
    ft_json_str(json, "key", req->key, sizeof(req->key));
    ft_json_str(json, "axis", req->axis, sizeof(req->axis));
    ft_json_int(json, "rows", &req->rows);
    ft_json_int(json, "cols", &req->cols);
    ft_json_int(json, "slot", &req->slot);
    ft_json_bool(json, "select", &req->select);
    ft_json_bool(json, "force", &req->force);
    if (ft_json_bool(json, "reuse", &req->reuse) == 0) {
        req->has_reuse = 1;
    } else {
        req->reuse = 1;
    }
    ft_json_double(json, "ratio", &req->ratio);
    return req->command[0] ? 0 : -1;
}

static void ok_begin(FtBuf *b, const char *id) {
    ft_buf_printf(b, "{\"v\":1,\"id\":\"%s\",\"ok\":true,\"data\":", id);
}

static void err_resp(char *out, size_t n, const char *id, const char *code, const char *msg) {
    snprintf(
        out,
        n,
        "{\"v\":1,\"id\":\"%s\",\"ok\":false,\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
        id,
        code,
        msg
    );
}

static const char *focus_session(FtModel *m, const FtControlReq *req) {
    if (req->session[0]) {
        return req->session;
    }
    FtNode *n = ft_model_focused_pane(m);
    return n ? n->session : "";
}

int ft_control_dispatch(FtModel *m, const FtControlReq *req, const FtControlHooks *hooks, char *out, size_t n) {
    if (!req || !out || n < 8) {
        return -1;
    }
    if (!ft_control_known(req->command)) {
        err_resp(out, n, req->id, "unknown_command", req->command);
        return 0;
    }
    FtBuf b;
    ft_buf_init(&b, out, n);
    const char *cmd = req->command;

    if (strcmp(cmd, "status") == 0) {
        FtProjectRec *p = ft_model_active(m);
        ok_begin(&b, req->id);
        ft_buf_printf(
            &b,
            "{\"activeProject\":\"%s\",\"pid\":%d}}",
            p ? p->name : "",
            (int)getpid()
        );
        return 0;
    }
    if (strcmp(cmd, "project.list") == 0) {
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"projects\":[");
        for (int i = 0; i < m->nprojects; i++) {
            FtProjectRec *p = &m->projects[i];
            if (i) {
                ft_buf_printf(&b, ",");
            }
            char esc[1024];
            ft_json_esc(p->path, esc, sizeof(esc));
            ft_buf_printf(
                &b,
                "{\"id\":\"%s\",\"name\":\"%s\",\"path\":\"%s\",\"active\":%s,\"loaded\":%s,\"tabCount\":%d}",
                p->id,
                p->name,
                esc,
                (m->active == i) ? "true" : "false",
                p->unloaded ? "false" : "true",
                p->ntabs
            );
        }
        ft_buf_printf(&b, "]}}");
        return 0;
    }
    if (strcmp(cmd, "project.create") == 0) {
        if (ft_model_project_create(m, req->path, req->name, req->select) != 0) {
            err_resp(out, n, req->id, "bad_request", m->error[0] ? m->error : "create failed");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        FtProjectRec *p = &m->projects[m->nprojects - 1];
        ft_buf_printf(&b, "{\"id\":\"%s\",\"name\":\"%s\",\"path\":\"%s\"}}", p->id, p->name, p->path);
        return 0;
    }
    if (strcmp(cmd, "project.open") == 0) {
        if (ft_model_project_open(m, req->path, req->name) != 0) {
            err_resp(out, n, req->id, "bad_request", m->error[0] ? m->error : "open failed");
            return 0;
        }
        if (req->run[0]) {
            ft_model_tab_new(m, NULL, req->run, NULL, 0);
        }
        ft_model_save(m);
        FtProjectRec *p = ft_model_active(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"id\":\"%s\",\"name\":\"%s\",\"path\":\"%s\"", p->id, p->name, p->path);
        if (req->run[0] && p->ntabs) {
            FtNode *pane = p->tabs[p->active_tab].root;
            FtNode *leaves[8];
            int c = ft_node_collect(pane, leaves, 8);
            ft_buf_printf(&b, ",\"panes\":[");
            for (int i = 0; i < c; i++) {
                if (i) {
                    ft_buf_printf(&b, ",");
                }
                ft_buf_printf(&b, "{\"session\":\"%s\"}", leaves[i]->session);
            }
            ft_buf_printf(&b, "]");
        }
        ft_buf_printf(&b, "}}");
        return 0;
    }
    if (strcmp(cmd, "project.select") == 0) {
        if (ft_model_project_select(m, req->project) != 0) {
            err_resp(out, n, req->id, "not_found", "project not found");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "tab.list") == 0) {
        if (req->project[0]) {
            ft_model_project_select(m, req->project);
        }
        FtProjectRec *p = ft_model_active(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"tabs\":[");
        if (p) {
            for (int i = 0; i < p->ntabs; i++) {
                if (i) {
                    ft_buf_printf(&b, ",");
                }
                ft_buf_printf(
                    &b,
                    "{\"id\":\"%s\",\"title\":\"%s\",\"index\":%d,\"active\":%s}",
                    p->tabs[i].id,
                    p->tabs[i].title,
                    i + 1,
                    i == p->active_tab ? "true" : "false"
                );
            }
        }
        ft_buf_printf(&b, "]}}");
        return 0;
    }
    if (strcmp(cmd, "tab.new") == 0) {
        char sess[80];
        if (ft_model_tab_new(m, req->project, req->run, sess, sizeof(sess)) != 0) {
            err_resp(out, n, req->id, "bad_request", m->error[0] ? m->error : "tab.new failed");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"session\":\"%s\"}}", sess);
        return 0;
    }
    if (strcmp(cmd, "tab.select") == 0) {
        if (req->project[0]) {
            ft_model_project_select(m, req->project);
        }
        if (ft_model_tab_select(m, req->tab) != 0) {
            err_resp(out, n, req->id, "not_found", "tab not found");
            return 0;
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "tab.move") == 0) {
        if (ft_model_tab_move(m, req->tab, req->slot) != 0) {
            err_resp(out, n, req->id, "not_found", "tab not found");
            return 0;
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "tab.close") == 0) {
        int rc = ft_model_tab_close(m, req->tab, req->force, hooks ? hooks->busy : NULL, hooks ? hooks->user : NULL);
        if (rc == -2) {
            err_resp(out, n, req->id, "busy", "pane has a running program");
            return 0;
        }
        if (rc != 0) {
            err_resp(out, n, req->id, "not_found", "tab not found");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "pane.list") == 0) {
        if (req->project[0]) {
            ft_model_project_select(m, req->project);
        }
        FtProjectRec *p = ft_model_active(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"panes\":[");
        int idx = 0;
        if (p) {
            int t0 = 0, t1 = p->ntabs;
            if (req->tab[0]) {
                /* restrict later if needed */
            }
            (void)t0;
            (void)t1;
            for (int t = 0; t < p->ntabs; t++) {
                FtNode *panes[64];
                int c = ft_node_collect(p->tabs[t].root, panes, 64);
                for (int i = 0; i < c; i++) {
                    if (idx) {
                        ft_buf_printf(&b, ",");
                    }
                    idx++;
                    ft_buf_printf(
                        &b,
                        "{\"index\":%d,\"id\":\"%s\",\"session\":\"%s\",\"cwd\":\"%s\",\"focused\":%s}",
                        idx,
                        panes[i]->pane_id,
                        panes[i]->session,
                        panes[i]->cwd,
                        strcmp(p->tabs[t].focus, panes[i]->session) == 0 && t == p->active_tab ? "true" : "false"
                    );
                }
            }
        }
        ft_buf_printf(&b, "]}}");
        return 0;
    }
    if (strcmp(cmd, "pane.dump") == 0) {
        const char *sess = focus_session(m, req);
        char text[65536];
        text[0] = 0;
        if (hooks && hooks->dump) {
            hooks->dump(hooks->user, sess, text, sizeof(text));
        }
        char esc[65536];
        ft_json_esc(text, esc, sizeof(esc));
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"dump\":{\"text\":\"%s\"}}}", esc);
        return 0;
    }
    if (strcmp(cmd, "pane.run") == 0) {
        const char *sess = focus_session(m, req);
        if (hooks && hooks->run && req->run[0]) {
            hooks->run(hooks->user, sess, req->run);
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "pane.split") == 0) {
        char sess[80];
        if (ft_model_split(m, req->session, req->direction[0] ? req->direction : "right", req->run, sess, sizeof(sess)) != 0) {
            err_resp(out, n, req->id, "bad_request", m->error[0] ? m->error : "split failed");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"session\":\"%s\"}}", sess);
        return 0;
    }
    if (strcmp(cmd, "pane.focus") == 0) {
        if (ft_model_focus(m, req->session, req->direction) != 0) {
            err_resp(out, n, req->id, "not_found", "pane not found");
            return 0;
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "pane.close") == 0) {
        if (!req->session[0] && !req->pane[0]) {
            err_resp(out, n, req->id, "bad_request", "pane close requires --pane or --session");
            return 0;
        }
        int rc = ft_model_close_pane(m, req->session, req->force, hooks ? hooks->busy : NULL, hooks ? hooks->user : NULL);
        if (rc == -2) {
            err_resp(out, n, req->id, "busy", "pane has a running program");
            return 0;
        }
        if (rc != 0) {
            err_resp(out, n, req->id, "not_found", "pane not found");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "pane.key") == 0) {
        const char *sess = focus_session(m, req);
        if (hooks && hooks->key && req->key[0]) {
            hooks->key(hooks->user, sess, req->key);
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "pane.zoom") == 0) {
        ft_model_zoom(m, req->session);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "grid") == 0) {
        int rows = req->rows > 0 ? req->rows : 2;
        int cols = req->cols > 0 ? req->cols : 2;
        if (ft_model_grid(m, req->session, rows, cols, req->run) != 0) {
            err_resp(out, n, req->id, "bad_request", "grid failed");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "session.list") == 0) {
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"sessions\":[");
        if (hooks && hooks->session_list) {
            char extra[8192];
            extra[0] = 0;
            hooks->session_list(hooks->user, extra, sizeof(extra));
            /* hook may write a JSON array body; if empty, fall through */
            if (extra[0] == '[') {
                /* replace */
                ft_buf_init(&b, out, n);
                ok_begin(&b, req->id);
                ft_buf_printf(&b, "{\"sessions\":%s}}", extra);
                return 0;
            }
        }
        char sessions[128][80];
        int ns = ft_model_all_sessions(m, sessions, 128);
        for (int i = 0; i < ns; i++) {
            if (i) {
                ft_buf_printf(&b, ",");
            }
            ft_buf_printf(&b, "{\"name\":\"%s\"}", sessions[i]);
        }
        ft_buf_printf(&b, "]}}");
        return 0;
    }
    if (strcmp(cmd, "session.info") == 0) {
        if (!req->session[0]) {
            err_resp(out, n, req->id, "bad_request", "session.info requires a session name");
            return 0;
        }
        if (hooks && hooks->session_info) {
            char extra[4096];
            extra[0] = 0;
            hooks->session_info(hooks->user, req->session, extra, sizeof(extra));
            if (extra[0]) {
                ft_buf_init(&b, out, n);
                ok_begin(&b, req->id);
                ft_buf_printf(&b, "%s}", extra);
                return 0;
            }
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"name\":\"%s\"}}", req->session);
        return 0;
    }
    if (strcmp(cmd, "session.kill") == 0) {
        if (hooks && hooks->session_kill) {
            hooks->session_kill(hooks->user, req->session);
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    if (strcmp(cmd, "layout.save") == 0) {
        char written[768];
        written[0] = 0;
        if (ft_model_save_layout(m, req->project, written, sizeof(written)) != 0) {
            err_resp(out, n, req->id, "bad_request", m->error[0] ? m->error : "save failed");
            return 0;
        }
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{\"path\":\"%s\"}}", written);
        return 0;
    }
    if (strcmp(cmd, "layout.apply") == 0) {
        if (ft_model_apply_layout(m, req->project, req->force) != 0) {
            err_resp(out, n, req->id, "bad_request", m->error[0] ? m->error : "apply failed");
            return 0;
        }
        ft_model_save(m);
        ok_begin(&b, req->id);
        ft_buf_printf(&b, "{}}");
        return 0;
    }
    err_resp(out, n, req->id, "unknown_command", req->command);
    return 0;
}
