#include "../src/split.h"

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
    FtNode *root = ft_node_pane("futuraterm-home-aaaaaaaaaaaa", "/tmp");
    FtNode *b = ft_node_pane("futuraterm-home-bbbbbbbbbbbb", "/tmp");
    expect(ft_node_split_at(&root, "futuraterm-home-aaaaaaaaaaaa", FT_SPLIT_H, b) == 0, "split right");
    expect(root->is_split, "root is split");
    expect(root->dir == FT_SPLIT_H, "horizontal");
    expect(ft_node_count(root) == 2, "two panes");

    const char *nb = ft_node_neighbor(root, "futuraterm-home-aaaaaaaaaaaa", FT_DIR_RIGHT);
    expect(nb && strcmp(nb, "futuraterm-home-bbbbbbbbbbbb") == 0, "neighbor right");
    nb = ft_node_neighbor(root, "futuraterm-home-bbbbbbbbbbbb", FT_DIR_LEFT);
    expect(nb && strcmp(nb, "futuraterm-home-aaaaaaaaaaaa") == 0, "neighbor left");

    const char *nx = ft_node_cycle(root, "futuraterm-home-aaaaaaaaaaaa", 1);
    expect(nx && strcmp(nx, "futuraterm-home-bbbbbbbbbbbb") == 0, "cycle next");

    FtNode *c = ft_node_pane("futuraterm-home-cccccccccccc", "/tmp");
    expect(ft_node_split_at(&root, "futuraterm-home-bbbbbbbbbbbb", FT_SPLIT_V, c) == 0, "split down");
    expect(ft_node_count(root) == 3, "three panes");

    expect(ft_node_close(&root, "futuraterm-home-cccccccccccc") == 0, "close");
    expect(ft_node_count(root) == 2, "two after close");

    FtNode *taken = ft_node_detach(&root, "futuraterm-home-bbbbbbbbbbbb");
    expect(taken && strcmp(taken->session, "futuraterm-home-bbbbbbbbbbbb") == 0, "detach");
    expect(ft_node_count(root) == 1, "one remains");
    ft_node_free(taken);

    FtNode *leaves[8];
    int n = ft_node_detach_all(&root, leaves, 8);
    expect(n == 1, "detach all");
    ft_node_free(leaves[0]);

    root = ft_node_pane("origin", "/tmp");
    FtNode *created[16];
    int made = ft_node_grid(&root, "origin", 2, 2, created, 16);
    expect(made >= 2, "grid created panes");
    expect(ft_node_count(root) >= 3, "grid has several leaves");
    ft_node_free(root);

    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_split: ok");
    return 0;
}
