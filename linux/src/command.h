#ifndef FUTURATERM_LINUX_COMMAND_H
#define FUTURATERM_LINUX_COMMAND_H

#include <stddef.h>

typedef struct {
    const char *id;
    const char *title;
    const char *help;
    const char *category;
    const char *default_shortcut;
} FtCommand;

const FtCommand *ft_commands(int *count);
const FtCommand *ft_command_by_id(const char *id);
int ft_command_filter(const char *query, int *indices, int max);

#endif
