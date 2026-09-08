#include "../src/path.h"

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
    FtProjectPath p;

    expect(ft_path_parse("/Users/me/dev", &p) == 0, "abs local");
    expect(p.kind == FT_PATH_LOCAL, "abs is local");
    expect(ft_path_is_local("/Users/me/dev"), "is_local");
    expect(!ft_path_is_remote("/Users/me/dev"), "abs not remote");

    expect(ft_path_parse("~/dev/api", &p) == 0, "tilde local");
    expect(p.kind == FT_PATH_LOCAL, "tilde is local");

    expect(ft_path_parse("devbox:~/dev/api", &p) == 0, "host:dir");
    expect(p.kind == FT_PATH_REMOTE, "host:dir remote");
    expect(strcmp(p.host, "devbox") == 0, "host");
    expect(strcmp(p.dir, "~/dev/api") == 0, "remote dir");
    expect(p.user[0] == 0, "no user");
    expect(ft_path_is_remote("devbox:~/dev/api"), "is_remote");

    expect(ft_path_parse("deploy@10.0.0.5:/srv/app", &p) == 0, "user@host:dir");
    expect(p.kind == FT_PATH_REMOTE, "user remote");
    expect(strcmp(p.user, "deploy") == 0, "user");
    expect(strcmp(p.host, "10.0.0.5") == 0, "ip host");

    expect(ft_path_parse("relative/path", &p) != 0, "relative invalid");
    expect(ft_path_parse("~foo:bar", &p) != 0, "tilde host invalid");
    expect(ft_path_parse("host:", &p) != 0, "empty dir invalid");
    expect(ft_path_parse("", &p) != 0, "empty invalid");

    expect(ft_path_parse("<pinned>", &p) == 0, "pinned marker");
    expect(p.kind == FT_PATH_PINNED, "pinned kind");

    expect(ft_path_matches("/tmp/a", "/tmp/a/"), "slash stripped match");
    expect(ft_path_matches("devbox:~/x", "devbox:~/x"), "remote match");
    expect(!ft_path_matches("devbox:~/x", "other:~/x"), "remote host differs");
    expect(!ft_path_matches("/tmp/a", "host:/tmp/a"), "local != remote");

    char dest[128];
    ft_path_parse("me@box:/srv", &p);
    ft_path_destination(&p, dest, sizeof(dest));
    expect(strcmp(dest, "me@box") == 0, "destination user@host");

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_path: ok");
    return 0;
}
