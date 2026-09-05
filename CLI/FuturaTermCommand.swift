import ArgumentParser
import Foundation

/// `futuraterm` — control a running FuturaTerm app from the shell.
///
/// Talks to the app over its Unix control socket (see `ControlProtocol`).
/// If no socket answers, launches the companion `.app` and waits (unless
/// `--no-launch` or `--socket`). Exit codes: 0 success, 1 the app returned
/// an error, 2 the app couldn't be reached. stdout carries only successful
/// output.
@main
struct FuturaTermCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ControlProtocol.cliCommandName,
        abstract: "Control a running FuturaTerm: projects, tabs, panes, zmx sessions.",
        subcommands: [
            Status.self,
            ProjectCommand.self,
            TabCommand.self,
            PaneCommand.self,
            Grid.self,
            SessionCommand.self,
            LayoutCommand.self,
            SSHCommand.self,
        ]
    )
}

/// Options every subcommand shares.
struct ConnectionOptions: ParsableArguments {
    @Option(help: "Control socket path (overrides discovery).")
    var socket: String?

    @Flag(name: .customLong("no-launch"), help: "Don't launch FuturaTerm when the control socket is unreachable.")
    var noLaunch = false

    @Flag(help: "Print the raw JSON payload instead of a table.")
    var json = false
}

/// Send a request, apply the safe-fail contract, render the result.
///
/// Connection failure auto-launches the companion app once unless `--socket`
/// / `--no-launch`. `starting` is retried without launching. Both poll until
/// success, a terminal app error, or the readiness timeout.
func runControlCommand(command: String, args: ControlArgs? = nil, options: ConnectionOptions) throws {
    let client = ControlClient(socketOverride: options.socket)
    let autoLaunch = ControlReadiness.shouldAutoLaunch(
        socketOverride: options.socket,
        noLaunch: options.noLaunch
    )
    var didLaunch = false
    var deadline: Date?

    while true {
        do {
            let response = try client.send(command: command, args: args)
            if response.ok {
                try Output.render(response.data, asJSON: options.json)
                return
            }
            if !ControlReadiness.isRetryable(connectionFailure: false, response: response) {
                let error = response.error ?? ControlError(code: .internalError, message: "unknown error")
                Output.printError(error.message, action: error.action)
                throw ExitCode(1)
            }
            if readinessWaitTimedOut(deadline: &deadline) {
                let error = response.error ?? ControlError(
                    code: .starting,
                    message: "FuturaTerm is still starting up"
                )
                Output.printError(error.message, action: error.action)
                throw ExitCode(1)
            }
        } catch let error as ControlClient.ClientError {
            if error.isConnectionFailure {
                if !autoLaunch {
                    Output.printError(error.description)
                    throw ExitCode(2)
                }
                if !didLaunch {
                    try? ControlLaunch.launchCompanion()
                    didLaunch = true
                }
                if readinessWaitTimedOut(deadline: &deadline) {
                    Output.printError(error.description)
                    throw ExitCode(2)
                }
            } else {
                Output.printError(error.description)
                throw ExitCode(1)
            }
        }
    }
}

/// Sleep until the next poll. Returns `true` when the wait budget is gone
/// (caller should surface the last error).
private func readinessWaitTimedOut(deadline: inout Date?) -> Bool {
    let now = Date()
    if deadline == nil {
        deadline = now.addingTimeInterval(ControlReadiness.timeout)
    }
    guard let end = deadline, now < end else { return true }
    Thread.sleep(forTimeInterval: min(ControlReadiness.pollInterval, end.timeIntervalSince(now)))
    return false
}

/// The pane self-address the app injects into every pane's shell. Used as the
/// implicit target when a pane verb names no explicit one (Zentty-style
/// "current pane" context) — explicit selectors always win.
func sessionFromEnvironment() -> String? {
    ControlProtocol.sessionHint(from: ProcessInfo.processInfo.environment)
}

/// Shared pane-target options: `--session`/`--pane` are explicit; inside a
/// FuturaTerm pane, `FUTURATERM_SESSION` fills in
/// when neither is given (nor a tab scope — an explicit tab means "that tab's
/// focused pane", not self).
struct PaneTarget: ParsableArguments {
    @Option(help: "Project scope (name, UUID, or index). Defaults to the active project.")
    var project: String?

    @Option(help: "Tab scope (title, UUID, or index).")
    var tab: String?

    @Option(help: "Target pane by UUID, or index within the tab (pane:2).")
    var pane: String?

    @Option(help: "Target pane by zmx session name (restart-stable).")
    var session: String?

    func controlArgs() -> ControlArgs {
        ControlArgs(
            project: project,
            tab: tab,
            pane: pane,
            session: session ?? (pane == nil && tab == nil ? sessionFromEnvironment() : nil)
        )
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether FuturaTerm is running and which project is active."
    )

    @OptionGroup var options: ConnectionOptions

    func run() throws {
        try runControlCommand(command: "status", options: options)
    }
}

// MARK: - Project

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "List, create, open, and select projects.",
        subcommands: [List.self, Create.self, Open.self, Select.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all projects.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "project.list", options: options)
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a project for a directory (not idempotent). No security-scoped bookmark; use Open Project in the app for MAS."
        )

        @Argument(help: "Project directory (absolute or ~-prefixed).")
        var path: String

        @Option(help: "Display name. Defaults to the directory name.")
        var name: String?

        @Flag(help: "Also select it (applies a matching project file's layout on first open).")
        var select = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "project.create",
                args: ControlArgs(path: path, name: name, select: select),
                options: options
            )
        }
    }

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find or create a project for a directory and select it."
        )

        @Argument(help: "Project directory (absolute or ~-prefixed) or a remote [user@]host:dir spec.")
        var path: String

        @Option(help: "Display name when creating. Defaults to the directory name. Ignored if the path already has a project.")
        var name: String?

        @Option(name: .customLong("run"), help: "Reuse or create a pane running this command and return its session.")
        var runCommand: String?

        @Flag(name: .customLong("no-reuse"), help: "Always create a new tab for --run even if a matching pane already exists.")
        var noReuse = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "project.open",
                args: ControlArgs(path: path, name: name, run: runCommand, reuse: noReuse ? false : nil),
                options: options
            )
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make a project active.")

        @Argument(help: "Project name, UUID, or index.")
        var project: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "project.select", args: ControlArgs(project: project), options: options)
        }
    }
}

// MARK: - Tab

struct TabCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "List, create, select, reorder, and close tabs.",
        subcommands: tabSubcommands,
        defaultSubcommand: List.self
    )

    /// Mirrors PaneCommand.paneSubcommands: the debug-only `merge` verb is
    /// present in debug builds of the CLI and absent in release.
    private static var tabSubcommands: [ParsableCommand.Type] {
        var subs: [ParsableCommand.Type] = [List.self, New.self, Select.self, Move.self, Close.self]
        #if DEBUG
        subs.append(Merge.self)
        #endif
        return subs
    }

    #if DEBUG
    /// DEBUG-only (#227): the sidebar tab-into-workspace drop as a verb, so
    /// merges can be reproduced and regression-tested without a mouse.
    struct Merge: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "[debug] Merge a tab into the active tab: beside a pane (--dest) or at the workspace edge."
        )

        @Option(help: "Source tab (title, UUID, or index).")
        var tab: String

        @Option(help: "Side to land on: left, right, top, or bottom.")
        var zone: String

        @Option(help: "Destination pane in the active tab (UUID or index). Omit for the workspace edge.")
        var dest: String?

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs(project: project, tab: tab)
            args.zone = zone
            args.dest = dest
            try runControlCommand(command: "tab.merge", args: args, options: options)
        }
    }
    #endif

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tabs (active project by default).")

        @Option(help: "Project to list (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "tab.list", args: ControlArgs(project: project), options: options)
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a new tab (becomes active).")

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @Option(name: .customLong("run"), help: "Command to run in the new tab's shell.")
        var runCommand: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.new",
                args: ControlArgs(project: project, run: runCommand),
                options: options
            )
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Activate a tab.")

        @Argument(help: "Tab title, UUID, or index (tab:3).")
        var tab: String

        @Option(help: "Project scope. Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.select",
                args: ControlArgs(project: project, tab: tab),
                options: options
            )
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a tab to a slot — its final 1-based position in `tab list` order."
        )

        @Argument(help: "Tab title, UUID, or index (tab:3).")
        var tab: String

        @Argument(help: "Destination slot: the 1-based position the tab ends up in.")
        var slot: Int

        @Option(help: "Project scope. Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.move",
                args: ControlArgs(project: project, tab: tab, slot: slot),
                options: options
            )
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a tab (kills its panes' zmx sessions)."
        )

        @Argument(help: "Tab title, UUID, or index (tab:3).")
        var tab: String

        @Option(help: "Project scope. Defaults to the active project.")
        var project: String?

        @Flag(help: "Close even if a pane has a running program.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.close",
                args: ControlArgs(project: project, tab: tab, force: force),
                options: options
            )
        }
    }
}

// MARK: - Pane

struct PaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "List, inspect, dump, choices, select, split, focus, close, click, and run commands in panes.",
        subcommands: paneSubcommands,
        defaultSubcommand: List.self
    )

    /// Assembled once so the debug-only `resize` verb is present in debug
    /// builds of the CLI and absent in release. (The app also gates the
    /// server-side handler behind `#if DEBUG`, which is the authoritative
    /// boundary; this just hides the verb from `--help` in release.)
    private static var paneSubcommands: [ParsableCommand.Type] {
        var subs: [ParsableCommand.Type] = [
            List.self, Inspect.self, Dump.self, Choices.self, Choose.self,
            Selection.self, Select.self,
            Split.self, Focus.self, Close.self, Run.self, Key.self, Click.self,
            Zoom.self, ResizeSplit.self,
        ]
        #if DEBUG
        subs.append(Resize.self)
        subs.append(Move.self)
        #endif
        return subs
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List panes (active project by default).")

        @Option(help: "Project to list (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @Option(help: "Restrict to one tab (title, UUID, or index).")
        var tab: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "pane.list",
                args: ControlArgs(project: project, tab: tab),
                options: options
            )
        }
    }

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split a pane. Defaults to the focused pane (or the pane you're in)."
        )

        @Option(help: "right, down, or auto (longer on-screen axis).")
        var direction: String = "auto"

        @Option(name: .customLong("run"), help: "Command to run in the new pane's shell.")
        var runCommand: String?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.direction = direction
            args.run = runCommand
            try runControlCommand(command: "pane.split", args: args, options: options)
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Focus a pane, or its neighbour in a direction (selects its tab and fronts the window)."
        )

        @Option(help: "Move to the nearest pane this way from the target instead: left, down, up, or right.")
        var direction: String?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.direction = direction
            try runControlCommand(command: "pane.focus", args: args, options: options)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a pane (kills its zmx session)."
        )

        @OptionGroup var target: PaneTarget

        @Flag(help: "Close even if a program is running.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs(
                project: target.project,
                tab: target.tab,
                pane: target.pane,
                // Deliberately NOT defaulted from FUTURATERM_SESSION: closing
                // "whatever pane I'm in" because no target was given is a
                // destructive surprise. Explicit targets only.
                session: target.session
            )
            args.force = force
            guard args.pane != nil || args.session != nil else {
                Output.printError(
                    "pane close requires --pane or --session",
                    action: "run `futuraterm pane list` for targets"
                )
                throw ExitCode(1)
            }
            try runControlCommand(command: "pane.close", args: args, options: options)
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Type a command into a live pane's shell (adds a newline)."
        )

        @Argument(parsing: .captureForPassthrough, help: "The command line to run.")
        var command: [String]

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            let line = command.joined(separator: " ")
            guard !line.isEmpty else {
                Output.printError("nothing to run")
                throw ExitCode(1)
            }
            var args = target.controlArgs()
            args.run = line
            try runControlCommand(command: "pane.run", args: args, options: options)
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a key chord to a live pane (control/named keys, not text).",
            discussion: """
            Delivers a single key press through the terminal's key-encoding path \
            — the counterpart to `pane run`, which pastes text. Use it for control \
            keys and named keys that have no literal text form.

            The chord grammar matches keybinds: modifiers ctrl/cmd/shift/opt joined \
            with '+', then one key token. Examples:

              futuraterm pane key ctrl+c          # interrupt the foreground process
              futuraterm pane key escape          # send Esc to a TUI
              futuraterm pane key up              # arrow key (mode-aware encoding)
              futuraterm pane key 'ctrl+\\'        # SIGQUIT char (quote for the shell)
              futuraterm pane key enter           # submit (alias of 'return')

            With no pane/tab/session selector it targets the current pane via \
            $FUTURATERM_SESSION.
            """
        )

        @Argument(help: "The key chord, e.g. ctrl+c, escape, up, ctrl+\\.")
        var chord: String

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.key = chord
            try runControlCommand(command: "pane.key", args: args, options: options)
        }
    }

    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Left-click a 1-based viewport cell in a live pane.",
            discussion: """
            Synthesizes a left-button press and release at the center of the \
            given cell — the mouse path TUIs see, not a typed command. Origin \
            is the top-left visible cell (1,1).

              futuraterm pane click --col 2 --row 5
            """
        )

        @Option(help: "1-based column in the visible viewport.")
        var col: Int?

        @Option(help: "1-based row in the visible viewport.")
        var row: Int?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            guard let col, let row else {
                Output.printError(
                    "pane click requires --col and --row",
                    action: "cells are 1-based in the visible viewport"
                )
                throw ExitCode(1)
            }
            var args = target.controlArgs()
            args.cellCol = col
            args.cellRow = row
            try runControlCommand(command: "pane.click", args: args, options: options)
        }
    }

    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report a pane's live terminal-core state (grid, scrollback, foreground process)."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "pane.inspect", args: target.controlArgs(), options: options)
        }
    }

    struct Dump: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a pane's terminal text: the viewport, or the full scrollback with --scrollback."
        )

        @Flag(help: "Include the full scrollback, not just the visible viewport.")
        var scrollback = false

        @Option(name: .customLong("quiet-ms"), help: "Wait until the dump text is unchanged for this many milliseconds (50–2000).")
        var quietMs: Int?

        @Option(
            name: .customLong("timeout-ms"),
            help: "Give up waiting after this many milliseconds (100–30000). Default 5000 when --quiet-ms is set."
        )
        var timeoutMs: Int?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.scrollback = scrollback
            args.quietMs = quietMs
            args.timeoutMs = timeoutMs
            try runControlCommand(command: "pane.dump", args: args, options: options)
        }
    }

    struct Choices: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List numbered TUI choices in a pane's viewport."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "pane.choices",
                args: target.controlArgs(),
                options: options
            )
        }
    }

    struct Choose: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Activate a numbered TUI choice by typing its index and Return."
        )

        @Argument(help: "The menu number shown in the pane (not a dump line).")
        var choice: Int

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.choice = choice
            try runControlCommand(command: "pane.choose", args: args, options: options)
        }
    }

    struct Selection: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a pane's selected text (empty when nothing is selected)."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "pane.selection",
                args: target.controlArgs(),
                options: options
            )
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Select text in a live pane by line, UTF-16 range, or cell box.",
            discussion: """
            Exactly one mode:

              futuraterm pane select --line 3
              futuraterm pane select --start 0 --length 4
              futuraterm pane select --col 1 --row 2 --end-col 8 --end-row 2
            """
        )

        @Option(help: "1-based viewport line (selects the whole line).")
        var line: Int?

        @Option(help: "UTF-16 start in the visible viewport.")
        var start: Int?

        @Option(help: "UTF-16 length in the visible viewport.")
        var length: Int?

        @Option(help: "1-based start column in the visible viewport.")
        var col: Int?

        @Option(help: "1-based start row in the visible viewport.")
        var row: Int?

        @Option(help: "1-based end column (defaults to --col).")
        var endCol: Int?

        @Option(help: "1-based end row (defaults to --row).")
        var endRow: Int?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.line = line
            args.start = start
            args.length = length
            args.cellCol = col
            args.cellRow = row
            args.endCol = endCol
            args.endRow = endRow
            try runControlCommand(command: "pane.select", args: args, options: options)
        }
    }

    struct Zoom: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Toggle zoom on a pane (the tab renders only that pane while zoomed)."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "pane.zoom", args: target.controlArgs(), options: options)
        }
    }

    struct ResizeSplit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resize-split",
            abstract: "Set the ratio of the nearest split around a pane (0.15–0.85)."
        )

        @Option(help: "Split axis to resize: horizontal or vertical.")
        var axis: String

        @Option(help: "Absolute ratio for the split's first child (0.15–0.85).")
        var ratio: Double

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.axis = axis
            args.ratio = ratio
            try runControlCommand(command: "pane.resize-split", args: args, options: options)
        }
    }

    #if DEBUG
    /// DEBUG-only: isolated in-place surface resize for reflow debugging (#167).
    /// Absent from release CLIs; a release app also rejects `pane.resize`.
    struct Resize: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "[debug] Resize a pane's surface in place to COLS×ROWS, bypassing layout."
        )

        @Option(help: "Target columns.")
        var cols: Int

        @Option(help: "Target rows.")
        var rows: Int

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.cols = cols
            args.rows = rows
            try runControlCommand(command: "pane.resize", args: args, options: options)
        }
    }

    /// DEBUG-only (#227): the grab-handle drag-and-drop reshape as a verb, so
    /// reorders can be reproduced and regression-tested without a mouse.
    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "[debug] Move a pane: beside another pane (--dest) or to the workspace edge."
        )

        @Option(help: "Side to land on: left, right, top, or bottom.")
        var zone: String

        @Option(help: "Destination pane (UUID or index, same tab). Omit for the workspace edge.")
        var dest: String?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.zone = zone
            args.dest = dest
            try runControlCommand(command: "pane.move", args: args, options: options)
        }
    }
    #endif
}

// MARK: - Grid

struct Grid: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Split a pane into an equal ROWSxCOLS grid."
    )

    @Argument(help: "Grid shape, e.g. 2x2 or 3x1.")
    var shape: String

    @Option(name: .customLong("run"), help: "Command to run in each NEW pane (the source pane keeps its shell).")
    var runCommand: String?

    @OptionGroup var target: PaneTarget
    @OptionGroup var options: ConnectionOptions

    func run() throws {
        let parts = shape.lowercased().split(separator: "x")
        guard parts.count == 2, let rows = Int(parts[0]), let cols = Int(parts[1]) else {
            Output.printError("grid shape must look like 2x2")
            throw ExitCode(1)
        }
        var args = target.controlArgs()
        args.rows = rows
        args.cols = cols
        args.run = runCommand
        try runControlCommand(command: "grid", args: args, options: options)
    }
}

// MARK: - Session

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Inspect and kill zmx-backed terminal sessions.",
        subcommands: [List.self, Info.self, Kill.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List live zmx sessions.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "session.list", options: options)
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one zmx session.")

        @Argument(help: "Session name (futuraterm-<slug>-<hex>).")
        var name: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "session.info", args: ControlArgs(session: name), options: options)
        }
    }

    struct Kill: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Kill a zmx session (its shell dies; an attached pane's shell exits)."
        )

        @Argument(help: "Session name (futuraterm-<slug>-<hex>).")
        var name: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "session.kill", args: ControlArgs(session: name), options: options)
        }
    }
}

// MARK: - Layout

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Apply or save a project's declarative layout file.",
        subcommands: [Apply.self, Save.self]
    )

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reconcile the workspace to the project's central layout file."
        )

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @Flag(help: "Apply even when it would close panes.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "layout.apply",
                args: ControlArgs(project: project, force: force),
                options: options
            )
        }
    }

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save the live workspace as the project's layout file."
        )

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "layout.save", args: ControlArgs(project: project), options: options)
        }
    }
}
