#include "../src/command.h"
#include "../src/sel.h"

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
    FtSel s;
    ft_sel_clear(&s);
    expect(!ft_sel_contains(&s, 0, 0), "empty contains nothing");

    char buf[128];
    const char *rows[] = {
        "hello world",
        "foo bar baz",
        "end of text",
    };
    expect(ft_sel_copy_rect(rows, 3, &s, buf, sizeof(buf)) == 0, "empty sel copies nothing");
    expect(buf[0] == 0, "empty sel is empty string");

    ft_sel_begin(&s, 0, 0);
    ft_sel_update(&s, 0, 4);
    expect(ft_sel_contains(&s, 0, 2), "inside hello");
    expect(!ft_sel_contains(&s, 0, 6), "outside hello");
    expect(ft_sel_copy_rect(rows, 3, &s, buf, sizeof(buf)) > 0, "copy hello");
    expect(strcmp(buf, "hello") == 0, "copied hello");

    /* reverse drag */
    ft_sel_begin(&s, 0, 4);
    ft_sel_update(&s, 0, 0);
    expect(ft_sel_copy_rect(rows, 3, &s, buf, sizeof(buf)) > 0, "reverse copy");
    expect(strcmp(buf, "hello") == 0, "reverse still hello");

    ft_sel_begin(&s, 0, 6);
    ft_sel_update(&s, 1, 2);
    expect(ft_sel_copy_rect(rows, 3, &s, buf, sizeof(buf)) > 0, "multi-line");
    expect(strcmp(buf, "world\nfoo") == 0, "stream selection world/foo");

    ft_sel_all(&s, 3, 11);
    expect(ft_sel_contains(&s, 2, 0), "select all covers last row");
    expect(ft_sel_copy_rect(rows, 3, &s, buf, sizeof(buf)) > 0, "copy all");
    expect(strstr(buf, "hello world") == buf, "all starts with first line");
    expect(strstr(buf, "end of text") != NULL, "all includes last line");

    const FtCommand *copy = ft_command_by_id("copy");
    const FtCommand *paste = ft_command_by_id("paste");
    const FtCommand *cut = ft_command_by_id("cut");
    const FtCommand *all = ft_command_by_id("selectAll");
    expect(copy && strcmp(copy->default_shortcut, "super+c") == 0, "super+c copy");
    expect(paste && strcmp(paste->default_shortcut, "super+v") == 0, "super+v paste");
    expect(cut && strcmp(cut->default_shortcut, "super+x") == 0, "super+x cut");
    expect(all && strcmp(all->default_shortcut, "super+a") == 0, "super+a select all");

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_sel: ok");
    return 0;
}
