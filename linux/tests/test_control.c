#include "../src/control.h"
#include "../src/model.h"

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

static int dump_stub(void *user, const char *session, char *out, size_t n) {
    (void)user;
    (void)session;
    snprintf(out, n, "stub-dump");
    return 0;
}

int main(void) {
    char dir[] = "/tmp/ft-control-test-XXXXXX";
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    char cfg[256];
    snprintf(cfg, sizeof(cfg), "%s/cfg", dir);
    FtModel *m = ft_model_new(dir, cfg);
    expect(m != NULL, "model");
    expect(ft_model_project_open(m, "/tmp/ft-control-proj", "Ctrl") == 0, "seed project");

    int ncmds = 0;
    const char *const *cmds = ft_control_public_commands(&ncmds);
    expect(ncmds >= 20, "public verb count");

    FtControlHooks hooks = {0};
    hooks.dump = dump_stub;

    for (int i = 0; i < ncmds; i++) {
        FtControlReq req;
        memset(&req, 0, sizeof(req));
        snprintf(req.id, sizeof(req.id), "t%d", i);
        snprintf(req.command, sizeof(req.command), "%s", cmds[i]);
        snprintf(req.path, sizeof(req.path), "/tmp/ft-control-extra");
        snprintf(req.session, sizeof(req.session), "futuraterm-ctrl-0123456789ab");
        snprintf(req.tab, sizeof(req.tab), "1");
        snprintf(req.project, sizeof(req.project), "Ctrl");
        snprintf(req.run, sizeof(req.run), "true");
        snprintf(req.direction, sizeof(req.direction), "right");
        snprintf(req.key, sizeof(req.key), "enter");
        req.rows = 2;
        req.cols = 2;
        req.slot = 1;
        req.force = 1;
        char resp[8192];
        ft_control_dispatch(m, &req, &hooks, resp, sizeof(resp));
        int unknown = strstr(resp, "unknown_command") != NULL;
        if (unknown) {
            fprintf(stderr, "FAIL: %s returned unknown_command: %s\n", cmds[i], resp);
            fails++;
        }
        expect(strstr(resp, "\"ok\"") != NULL, cmds[i]);
    }

    FtControlReq bad;
    memset(&bad, 0, sizeof(bad));
    snprintf(bad.id, sizeof(bad.id), "bad");
    snprintf(bad.command, sizeof(bad.command), "pane.resize");
    char resp[1024];
    ft_control_dispatch(m, &bad, &hooks, resp, sizeof(resp));
    expect(strstr(resp, "unknown_command") != NULL, "debug-only pane.resize unknown");

    snprintf(bad.command, sizeof(bad.command), "not.a.verb");
    ft_control_dispatch(m, &bad, &hooks, resp, sizeof(resp));
    expect(strstr(resp, "unknown_command") != NULL, "garbage unknown");

    expect(ft_control_known("layout.save"), "layout.save known");
    expect(ft_control_known("session.list"), "session.list known");
    expect(!ft_control_known("pane.resize"), "pane.resize not public");

    char json[] = "{\"v\":1,\"id\":\"cli\",\"command\":\"pane.dump\",\"args\":{\"session\":\"abc\"}}";
    FtControlReq parsed;
    expect(ft_control_parse(json, &parsed) == 0, "parse nested args");
    expect(strcmp(parsed.command, "pane.dump") == 0, "command");
    expect(strcmp(parsed.session, "abc") == 0, "session from args");

    ft_model_free(m);
    char pjson[300];
    snprintf(pjson, sizeof(pjson), "%s/projects.json", dir);
    unlink(pjson);
    rmdir(dir);

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_control: ok");
    return 0;
}
