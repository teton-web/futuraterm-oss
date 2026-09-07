#define _GNU_SOURCE
#include "command.h"

#include "util.h"

#include <ctype.h>
#include <string.h>

static const FtCommand k_commands[] = {
    {"newTab", "New Tab", "Open a new tab in the current project.", "tabs", "super+t"},
    {"closePane", "Close Pane", "Close the focused pane. Closing the last pane of a tab also closes the tab.", "panes", "super+w"},
    {"closeTab", "Close Tab", "Close the current tab and all of its panes.", "tabs", "super+shift+t"},
    {"renameTab", "Rename Current Tab", "Rename the current tab in the sidebar.", "tabs", "super+r"},
    {"nextTab", "Next Tab", "Switch to the next tab across every project, including pinned tabs.", "tabs", "none"},
    {"previousTab", "Previous Tab", "Switch to the previous tab across every project, including pinned tabs.", "tabs", "none"},
    {"nextTabInProject", "Next Tab in Project", "Switch to the next tab in the current project.", "tabs", "ctrl+]"},
    {"previousTabInProject", "Previous Tab in Project", "Switch to the previous tab in the current project.", "tabs", "ctrl+["},
    {"recentTab", "Recent Tab", "Switch back to the most recently used tab in this project.", "tabs", "ctrl+tab"},
    {"separateAllPanes", "Separate All Panes", "Move every pane in this tab into its own tab.", "tabs", "none"},
    {"pinTab", "Pin Tab", "Pin this tab so it stays running above the project list.", "tabs", "none"},
    {"unpinTab", "Unpin Tab", "Unpin this tab and move it back to its project.", "tabs", "none"},
    {"splitRight", "Split Right", "Split the focused pane horizontally, opening a new pane to the right.", "panes", "super+d"},
    {"splitDown", "Split Down", "Split the focused pane vertically, opening a new pane below.", "panes", "super+shift+d"},
    {"splitAuto", "Split Automatically", "Split the focused pane in the direction that best fits its size.", "panes", "none"},
    {"separateCurrentPane", "Separate Current Pane", "Move the focused pane into its own tab.", "panes", "none"},
    {"zoomPane", "Zoom Pane", "Expand the focused pane to fill the tab, or restore the previous split.", "panes", "super+shift+return"},
    {"focusLeft", "Focus Left", "Move focus to the pane on the left.", "panes", "super+ctrl+h"},
    {"focusRight", "Focus Right", "Move focus to the pane on the right.", "panes", "super+ctrl+l"},
    {"focusUp", "Focus Up", "Move focus to the pane above.", "panes", "super+ctrl+k"},
    {"focusDown", "Focus Down", "Move focus to the pane below.", "panes", "super+ctrl+j"},
    {"nextPane", "Next Pane", "Cycle focus to the next pane in this tab.", "panes", "none"},
    {"previousPane", "Previous Pane", "Cycle focus to the previous pane in this tab.", "panes", "none"},
    {"resizeLeft", "Resize Pane Left", "Grow or shrink the focused pane toward the left.", "panes", "super+shift+h"},
    {"resizeRight", "Resize Pane Right", "Grow or shrink the focused pane toward the right.", "panes", "super+shift+l"},
    {"resizeUp", "Resize Pane Up", "Grow or shrink the focused pane toward the top.", "panes", "super+shift+k"},
    {"resizeDown", "Resize Pane Down", "Grow or shrink the focused pane toward the bottom.", "panes", "super+shift+j"},
    {"copy", "Copy", "Copy the selected terminal text to the clipboard.", "panes", "super+c"},
    {"paste", "Paste", "Paste the clipboard into the focused pane.", "panes", "super+v"},
    {"cut", "Cut", "Copy the selected terminal text (terminals do not delete the selection).", "panes", "super+x"},
    {"selectAll", "Select All", "Select all text in the focused pane.", "panes", "super+a"},
    {"copySessionID", "Copy Session ID", "Copy the focused pane's session name to the clipboard.", "panes", "none"},
    {"openProject", "Open Project", "Open a local folder as a project, or select it if it is already in the sidebar.", "projects", "super+o"},
    {"newRemoteProject", "New Remote Project", "Add a project on a Tailscale device or any SSH host.", "projects", "none"},
    {"viewDesktop", "View Desktop", "Open a live view of this remote machine's screen.", "projects", "none"},
    {"renameProject", "Rename Current Project", "Rename the current project in the sidebar.", "projects", "none"},
    {"unloadProject", "Unload Current Project", "Detach this project's sessions and dim it in the sidebar.", "projects", "none"},
    {"removeProject", "Remove Current Project", "Remove this project from the sidebar. Sessions are detached.", "projects", "none"},
    {"applyLayout", "Apply Layout", "Apply this project's saved layout, matching live panes where possible.", "projects", "none"},
    {"saveLayout", "Save Layout", "Save this project's current tabs and panes as a layout file.", "projects", "none"},
    {"nextProject", "Next Project", "Switch to the next project in the sidebar.", "projects", "super+]"},
    {"previousProject", "Previous Project", "Switch to the previous project in the sidebar.", "projects", "super+["},
    {"toggleSidebar", "Toggle Sidebar", "Show or hide the sidebar.", "window", "super+backslash"},
    {"closeWindow", "Close Window", "Hide the window without quitting. Terminal sessions keep running.", "window", "super+shift+w"},
    {"toggleCommandPalette", "Command Palette", "Open or close the command palette.", "window", "super+p"},
    {"manageSessions", "Sessions", "Show every local terminal session and whether it is open in a project.", "window", "none"},
    {"reloadGhosttyConfig", "Reload Ghostty Config", "Reload Ghostty configuration without restarting.", "other", "super+shift+comma"},
    {"toggleQuickTerminal", "Toggle Quick Terminal", "Show or hide the quick terminal overlay.", "other", "ctrl+grave"},
};

const FtCommand *ft_commands(int *count) {
    if (count) {
        *count = (int)(sizeof(k_commands) / sizeof(k_commands[0]));
    }
    return k_commands;
}

const FtCommand *ft_command_by_id(const char *id) {
    int n = 0;
    const FtCommand *all = ft_commands(&n);
    for (int i = 0; i < n; i++) {
        if (ft_str_eq(all[i].id, id)) {
            return &all[i];
        }
    }
    return NULL;
}

static void lower_copy(const char *s, char *out, size_t n) {
    size_t i = 0;
    for (; s && *s && i + 1 < n; s++) {
        out[i++] = (char)tolower((unsigned char)*s);
    }
    out[i] = 0;
}

int ft_command_filter(const char *query, int *indices, int max) {
    int n = 0;
    const FtCommand *all = ft_commands(&n);
    if (!indices || max <= 0) {
        return 0;
    }
    char q[128];
    lower_copy(query ? query : "", q, sizeof(q));
    int hits = 0;
    if (!q[0]) {
        for (int i = 0; i < n && hits < max; i++) {
            indices[hits++] = i;
        }
        return hits;
    }
    /* Prefix matches first, then substring. */
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < n && hits < max; i++) {
            char title[128], id[64];
            lower_copy(all[i].title, title, sizeof(title));
            lower_copy(all[i].id, id, sizeof(id));
            int prefix = strncmp(title, q, strlen(q)) == 0 || strncmp(id, q, strlen(q)) == 0;
            int sub = strstr(title, q) != NULL || strstr(id, q) != NULL;
            if (pass == 0 && prefix) {
                int dup = 0;
                for (int k = 0; k < hits; k++) {
                    if (indices[k] == i) {
                        dup = 1;
                    }
                }
                if (!dup) {
                    indices[hits++] = i;
                }
            } else if (pass == 1 && sub && !prefix) {
                indices[hits++] = i;
            }
        }
    }
    return hits;
}
