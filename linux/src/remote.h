#ifndef FUTURATERM_LINUX_REMOTE_H
#define FUTURATERM_LINUX_REMOTE_H

#include "path.h"

#include <stddef.h>

#define FT_REMOTE_ENV_PREAMBLE \
    "PATH=\"$PATH:$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin\"; export PATH; "

#define FT_REMOTE_TERM_PREAMBLE \
    "if ! infocmp \"$TERM\" >/dev/null 2>&1; then " \
    "if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty; " \
    "else TERM=xterm-256color; fi; export TERM; fi; "

#define FT_REMOTE_COLOR_PREAMBLE "COLORTERM=truecolor; export COLORTERM; "

/* Build the remote pane script (single-quote-free, sh -c, no profile source). */
int ft_remote_script(
    const FtProjectPath *remote,
    const char *session,
    const char *zmx_path,
    char *out,
    size_t n
);

/* ssh -t <dest> 'sh -c <script>' as a single command string (tests / debug). */
int ft_remote_pane_command(
    const FtProjectPath *remote,
    const char *session,
    const char *zmx_path,
    char *out,
    size_t n
);

/* argv: ssh, -t, dest, "sh -c <script>", NULL. Buffers owned by caller. */
int ft_remote_pane_argv(
    const FtProjectPath *remote,
    const char *session,
    const char *zmx_path,
    char *dest_buf,
    size_t dest_n,
    char *wrap_buf,
    size_t wrap_n,
    const char **argv_out
);

int ft_key_chord_bytes(const char *chord, char *out, size_t n);

/// Remote panes keep their zmx session when the local ssh client dies.
int ft_remote_should_reattach(int is_remote, int process_exited);

#endif
