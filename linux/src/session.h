#ifndef FUTURATERM_LINUX_SESSION_H
#define FUTURATERM_LINUX_SESSION_H

#include <stddef.h>

#define FT_LINUX_SESSION_PREFIX "futuraterm-"
#define FT_LINUX_DEFAULT_SESSION "futuraterm-linux"

/// Normalize a requested session name to `futuraterm-<slug>`.
/// Returns 0 on success. `out` is always NUL-terminated on success.
int ft_linux_normalize_session(const char *requested, char *out, size_t n);

/// Locate a zmx binary without sourcing shell profiles.
/// Search order: `ZMX` env, then `$HOME/bin`, `$HOME/.local/bin`,
/// `$HOME/.cargo/bin`, `$HOME/.local/share/mise/shims`, `/usr/local/bin`,
/// `/opt/homebrew/bin`, `/usr/bin`. Returns 0 if found.
int ft_linux_find_zmx(char *out, size_t n);

/// argv for `exec`: zmx attach <session>. `argv_out` has 4 slots (last NULL).
/// `zmx_buf` holds the executable path. Returns 0 on success.
int ft_linux_zmx_attach_argv(
    const char *session,
    char *zmx_buf,
    size_t zmx_buf_n,
    const char **argv_out
);

/// `futuraterm-<projectslug>-<12 hex>` matching the macOS pane session shape.
int ft_linux_make_pane_session(const char *project_slug, char *out, size_t n);

#endif
