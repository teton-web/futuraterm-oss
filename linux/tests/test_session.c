#include "../src/session.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;

static void expect(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        fails++;
    }
}

int main(void) {
    char name[64];

    expect(ft_linux_normalize_session(NULL, name, sizeof(name)) == 0, "null requested");
    expect(strcmp(name, "futuraterm-linux") == 0, "default name");

    expect(ft_linux_normalize_session("linux", name, sizeof(name)) == 0, "linux slug");
    expect(strcmp(name, "futuraterm-linux") == 0, "linux -> prefixed");

    expect(ft_linux_normalize_session("futuraterm-dts3", name, sizeof(name)) == 0, "already prefixed");
    expect(strcmp(name, "futuraterm-dts3") == 0, "prefix not doubled");

    expect(ft_linux_normalize_session("Foo Bar/baz", name, sizeof(name)) == 0, "sanitize");
    expect(strcmp(name, "futuraterm-foo-bar-baz") == 0, "spaces and slash");

    expect(ft_linux_normalize_session("ok", name, 4) != 0, "tiny buffer rejected");

    char zmx[512];
    const char *argv[4];
    int rc = ft_linux_zmx_attach_argv("futuraterm-linux", zmx, sizeof(zmx), argv);
    if (rc == 0) {
        expect(argv[0] == zmx, "argv0 is zmx buf");
        expect(strcmp(argv[1], "attach") == 0, "attach verb");
        expect(strcmp(argv[2], "futuraterm-linux") == 0, "session");
        expect(argv[3] == NULL, "argv terminated");
        expect(strstr(zmx, "zmx") != NULL, "path contains zmx");
        expect(strstr(argv[1], "source") == NULL, "no profile source");
        printf("zmx path: %s\n", zmx);
    } else {
        printf("zmx not on this machine; argv construction skipped\n");
        /* Still prove find_zmx fails closed instead of inventing a path. */
        expect(ft_linux_find_zmx(zmx, sizeof(zmx)) != 0, "find_zmx fails when absent");
    }

    char pane[80];
    expect(ft_linux_make_pane_session("home", pane, sizeof(pane)) == 0, "pane session");
    expect(strncmp(pane, "futuraterm-home-", 16) == 0, "pane session prefix");
    expect(strlen(pane) == 16 + 12, "pane session hex length");

    expect(ft_linux_pty_finished(0, 0, 0) == 1, "eof is child gone");
    expect(ft_linux_pty_finished(4, 0, 1) == 1, "hup is child gone");
    expect(ft_linux_pty_finished(-1, EAGAIN, 0) == 0, "eagain is not gone");
    expect(ft_linux_pty_finished(-1, EINTR, 0) == 0, "eintr is not gone");
    expect(ft_linux_pty_finished(-1, EIO, 0) == 1, "fatal read is gone");
    expect(ft_linux_pty_finished(8, 0, 0) == 0, "data is not gone");

    if (fails != 0) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_session: ok");
    return 0;
}
