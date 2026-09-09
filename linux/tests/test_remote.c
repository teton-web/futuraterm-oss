#include "../src/path.h"
#include "../src/remote.h"

#include <stdio.h>
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
    expect(ft_path_parse("me@box:~/src", &p) == 0, "parse remote");

    char script[4096];
    expect(ft_remote_script(&p, "futuraterm-box-aaaaaaaaaaaa", NULL, script, sizeof(script)) == 0, "script");
    expect(strstr(script, "source") == NULL, "no source");
    expect(strstr(script, "/etc/profile") == NULL, "no /etc/profile");
    expect(strstr(script, ".profile") == NULL, "no .profile");
    expect(strstr(script, "sh -lc") == NULL, "no sh -lc");
    expect(strstr(script, "COLORTERM=truecolor") != NULL, "COLORTERM");
    expect(strstr(script, "$HOME/bin") != NULL, "PATH fallback");
    expect(strstr(script, "zmx attach") != NULL, "attach");
    expect(strchr(script, '\'') == NULL, "single-quote-free");

    char cmd[8192];
    expect(ft_remote_pane_command(&p, "futuraterm-box-aaaaaaaaaaaa", NULL, cmd, sizeof(cmd)) == 0, "pane command");
    expect(strstr(cmd, "ssh -t") != NULL, "ssh -t");
    expect(strstr(cmd, "sh -c") != NULL, "sh -c");
    expect(strstr(cmd, "nested zmx") == NULL, "no nested zmx mention");

    char dest[128], wrap[5000];
    const char *argv[8];
    expect(ft_remote_pane_argv(&p, "futuraterm-box-aaaaaaaaaaaa", NULL, dest, sizeof(dest), wrap, sizeof(wrap), argv) == 0, "argv");
    expect(strcmp(argv[0], "ssh") == 0, "argv0 ssh");
    expect(strcmp(argv[1], "-t") == 0, "tty");
    expect(strcmp(argv[2], "me@box") == 0, "dest");
    expect(strstr(argv[3], "sh -c") != NULL, "remote sh -c");
    expect(argv[4] == NULL, "terminated");
    expect(strstr(wrap, "zmx attach") != NULL, "wrap has attach not local zmx");

    char zmxscript[4096];
    expect(ft_remote_script(&p, "futuraterm-box-aaaaaaaaaaaa", "/opt/zmx", zmxscript, sizeof(zmxscript)) == 0, "zmxPath");
    expect(strstr(zmxscript, "/opt/zmx") != NULL, "verbatim zmx path");
    expect(strstr(zmxscript, "command -v zmx") == NULL, "no PATH guard when zmxPath set");

    char bytes[16];
    expect(ft_remote_should_reattach(1, 1) == 1, "remote drop reattaches");
    expect(ft_remote_should_reattach(1, 0) == 0, "live remote does not");
    expect(ft_remote_should_reattach(0, 1) == 0, "local exit does not reattach");

    expect(ft_key_chord_bytes("ctrl+c", bytes, sizeof(bytes)) == 0, "ctrl+c");
    expect(bytes[0] == 3 && bytes[1] == 0, "ETX");
    expect(ft_key_chord_bytes("enter", bytes, sizeof(bytes)) == 0, "enter");
    expect(bytes[0] == '\r', "CR");
    expect(ft_key_chord_bytes("escape", bytes, sizeof(bytes)) == 0, "esc");
    expect(bytes[0] == 0x1b, "ESC");

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_remote: ok");
    return 0;
}
