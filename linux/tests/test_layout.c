#include "../src/layout.h"
#include "../src/split.h"

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

static const char *k_yaml =
    "name: Demo\n"
    "path: /tmp/ft-layout-demo\n"
    "tabs:\n"
    "- split:\n"
    "    direction: horizontal\n"
    "    ratio: 0.5\n"
    "    first:\n"
    "      run: echo hi\n"
    "    second: {}\n";

int main(void) {
    FtLayoutFile f;
    expect(ft_layout_parse(k_yaml, &f) == 0, "parse yaml");
    expect(strcmp(f.path, "/tmp/ft-layout-demo") == 0, "path field");
    expect(strcmp(f.name, "Demo") == 0, "name field");
    expect(f.ntabs == 1, "one tab");
    expect(f.tabs[0] && f.tabs[0]->is_split, "tab is split");
    expect(f.tabs[0]->dir == FT_SPLIT_H, "horizontal split");
    expect(f.tabs[0]->first && strcmp(f.tabs[0]->first->run, "echo hi") == 0, "run leaf");
    expect(f.tabs[0]->second && !f.tabs[0]->second->is_split, "empty second pane");

    char emitted[4096];
    expect(ft_layout_emit(&f, emitted, sizeof(emitted)) == 0, "emit");
    expect(strstr(emitted, "path: /tmp/ft-layout-demo") != NULL, "emit path");
    expect(strstr(emitted, "run:") != NULL, "emit run");
    expect(strstr(emitted, "split:") != NULL, "emit split");

    FtLayoutFile f2;
    expect(ft_layout_parse(emitted, &f2) == 0, "reparse emitted");
    expect(f2.ntabs == 1, "round-trip tab count");
    expect(f2.tabs[0] && f2.tabs[0]->is_split, "round-trip split");
    expect(f2.tabs[0]->first && strcmp(f2.tabs[0]->first->run, "echo hi") == 0, "round-trip run");

    char dir[] = "/tmp/ft-layout-test-XXXXXX";
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    char written[512];
    expect(ft_layout_write_dir(&f, dir, written, sizeof(written)) == 0, "write dir");
    expect(strstr(written, ".yaml") != NULL, "yaml suffix");

    FtLayoutFile loaded;
    expect(ft_layout_load_path(written, &loaded) == 0, "load path uses parser");
    expect(loaded.tabs[0] && loaded.tabs[0]->first && strcmp(loaded.tabs[0]->first->run, "echo hi") == 0, "loaded run");

    char found[512];
    expect(ft_layout_find_for_project(dir, "/tmp/ft-layout-demo", "Demo", found, sizeof(found)) == 0, "find by path");
    expect(strcmp(found, written) == 0, "found written file");

    ft_layout_free(&f);
    ft_layout_free(&f2);
    ft_layout_free(&loaded);
    unlink(written);
    rmdir(dir);

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_layout: ok");
    return 0;
}
