#include "../src/model.h"
#include "../src/path.h"

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
    char data[] = "/tmp/ft-folder-data-XXXXXX";
    char cfg[] = "/tmp/ft-folder-cfg-XXXXXX";
    if (!mkdtemp(data) || !mkdtemp(cfg)) {
        perror("mkdtemp");
        return 1;
    }

    FtModel *m = ft_model_new(data, cfg);
    expect(m != NULL, "model");

    char fid[40];
    expect(ft_model_folder_create(m, "Work", NULL, fid, sizeof(fid)) == 0, "create-folder");
    expect(m->nfolders == 1, "one folder");
    FtFolderRec *f = ft_model_folder_find(m, fid);
    expect(f != NULL && strcmp(f->name, "Work") == 0, "folder listed by name");
    expect(ft_model_set_add_folder(m, fid) == 0, "add-to-folder");

    expect(ft_model_add_local(m, "/tmp/ft-folder-local") == 0, "open-local");
    int saw_local = 0;
    int in_work = 0;
    for (int i = 0; i < m->nprojects; i++) {
        if (ft_path_matches(m->projects[i].path, "/tmp/ft-folder-local")) {
            saw_local = 1;
            if (strcmp(m->projects[i].folder_id, fid) == 0) {
                in_work = 1;
            }
        }
    }
    expect(saw_local, "local project in list");
    expect(in_work, "local project grouped in New Folder");

    expect(ft_model_add_remote(m, "me@box:~/src") == 0, "open-remote");
    int saw_remote = 0;
    for (int i = 0; i < m->nprojects; i++) {
        if (strcmp(m->projects[i].path, "me@box:~/src") == 0) {
            saw_remote = 1;
            expect(ft_path_is_remote(m->projects[i].path), "remote spec is [user@]host:dir");
        }
    }
    expect(saw_remote, "remote project in list");

    expect(ft_model_add_local(m, "me@box:~/src") != 0, "add-local rejects remote spec");
    expect(ft_model_add_remote(m, "/tmp/not-remote") != 0, "add-remote rejects local path");
    expect(ft_model_folder_create(m, "", NULL, NULL, 0) != 0, "empty folder name rejected");

    expect(ft_model_save(m) == 0, "save folders");
    ft_model_free(m);
    m = ft_model_new(data, cfg);
    expect(ft_model_load(m) == 0, "reload");
    expect(m->nfolders == 1, "folder persisted");
    expect(strcmp(m->folders[0].name, "Work") == 0, "folder name persisted");

    ft_model_free(m);
    if (fails) {
        fprintf(stderr, "%d failure(s)\n", fails);
        return 1;
    }
    puts("test_folder: ok");
    return 0;
}
