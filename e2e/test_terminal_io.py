"""Terminal I/O round-trips: CLI → socket → AppState → libghostty → pty →
shell → renderer cell state, read back out with `pane dump`.

Commands typed into panes must parse in ANY login shell — CI runners use zsh,
dev machines may run fish or nushell — so everything is `/bin/sh -c "…"` with
a single-quote-free, backslash-free script: the one form POSIX shells and
nushell tokenize identically (the same trick as the benchmark's workload
command and RemoteSpawn's wire format).
"""

import uuid
from pathlib import Path

from _harness import wait_for


def test_typed_command_output_appears_in_dump(app, live_pane):
    nonce = uuid.uuid4().hex[:12]
    marker = f"e2e-{nonce}-ok"
    # printf assembles the marker at runtime, so the typed command line (which
    # the dump also shows, echoed at the prompt) never contains it — a match
    # proves the shell *executed* the command, not that the keystrokes echoed.
    app.pane_run(f'/bin/sh -c "printf e2e-%s-ok {nonce}; echo"', pane=live_pane["id"])
    wait_for(
        lambda: marker in (app.pane_text(pane=live_pane["id"], scrollback=True) or ""),
        timeout=60,
        message=f"marker {marker} in the pane's dump",
    )


def test_ctrl_c_interrupts_foreground_program(app, live_pane):
    """`pane key` drives libghostty's key-encoding path (a real control byte,
    not pasted text). Interrupt delivery is proven with output markers, not a
    ghostty-side idle/running signal — needsConfirmQuit is only accurate
    where shell integration reaches the zmx session shell, and CI's bash 3.2
    login shell gets none, reading as perpetually busy. The protocol:
    `started` printing proves sleep is running when the SIGINT goes in;
    `after` executing while `finished` never prints proves the interrupt
    landed (an uninterrupted sleep would hold the shell for 300s, leaving
    the `after` line an unexecuted buffered keystroke, and a non-interactive
    sh aborts on a SIGINT'd child so `finished` can only print if the
    interrupt missed)."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:12]

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    app.pane_run(
        f'/bin/sh -c "printf started-%s {nonce}; echo; sleep 300; printf finished-%s {nonce}; echo"',
        pane=pane_id,
    )
    wait_for(lambda: f"started-{nonce}" in dump(), timeout=60, message="the sleep to start")

    app.cli("pane", "key", "ctrl+c", "--pane", pane_id)
    app.pane_run(f'/bin/sh -c "printf after-%s {nonce}; echo"', pane=pane_id)
    wait_for(
        lambda: f"after-{nonce}" in dump(),
        timeout=60,
        message="the shell to execute a command after ctrl+c",
    )
    assert f"finished-{nonce}" not in dump()


def test_pane_select_line_reads_back_as_selection(app, live_pane):
    """`pane select --line` then `pane selection` round-trip on a live surface."""
    pane_id = live_pane["id"]
    dump_before = wait_for(
        lambda: app.pane_text(pane=pane_id),
        timeout=60,
        message="viewport dump",
    )
    first = dump_before.splitlines()[0]
    assert first, f"empty first line in {dump_before!r}"
    app.cli("pane", "select", "--line", "1", "--pane", pane_id)

    def selection_payload():
        data = app.cli_json("pane", "selection", "--pane", pane_id)["selection"]
        text = data.get("text") or ""
        if data.get("hasSelection") and text and (text in first or first.startswith(text)):
            return data
        return None

    payload = wait_for(
        selection_payload,
        timeout=10,
        message=f"selection overlapping first viewport line {first!r}",
    )
    dump_again = app.pane_text(pane=pane_id) or ""
    assert dump_again == dump_before


def test_pane_choose_types_the_menu_index(app, live_pane):
    """`pane choices` sees a printf 1./2. menu; `pane choose 2` types 2+Return
    into a waiting `read` (the Grok TUI path, driven here with POSIX sh)."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:12]
    # Menu lines need a space after `N.`; that can't live in a `/bin/sh -c`
    # double-quoted script (nushell/fish tokenize quotes differently). The
    # typed command is only `/bin/sh <file>` — any login shell accepts it.
    script = Path(app.home) / f"e2e-choose-{nonce}.sh"
    script.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' '1. first' '2. second'\n"
        f"printf 'menu-%s\\n' '{nonce}'\n"
        "read choice\n"
        "printf 'picked-%s\\n' \"$choice\"\n"
    )
    app.pane_run(f"/bin/sh {script}", pane=pane_id)

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    wait_for(lambda: f"menu-{nonce}" in dump(), timeout=60, message="the numbered menu")

    def listed_menu():
        choices = app.cli_json("pane", "choices", "--pane", pane_id).get("choices") or []
        if [c.get("index") for c in choices] == [1, 2] and choices[1].get("label") == "second":
            return choices
        return None

    wait_for(listed_menu, timeout=10, message="pane choices listing 1. first / 2. second")
    app.cli("pane", "choose", "2", "--pane", pane_id)
    wait_for(
        lambda: "picked-2" in dump(),
        timeout=60,
        message="read receiving choice 2",
    )


def test_pane_click_cell_reaches_the_pty(app, live_pane):
    """`pane click --col --row` is the mouse path. A shell that has enabled
    X10 mouse tracking (DECSET 1000) receives a report on stdin — proof the
    click hit the live surface, not merely that the CLI returned."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:12]
    script = Path(app.home) / f"e2e-click-{nonce}.sh"
    # X10 report is ESC [ M + 3 bytes. Cooked mode would hold those from
    # `dd` until a newline, so drop ICANON first. Seeing `got` means the
    # click's report arrived on the pty.
    script.write_text(
        "#!/bin/sh\n"
        "printf '\\033[?1000h'\n"
        f"printf 'mouse-ready-%s\\n' '{nonce}'\n"
        "stty -echo -icanon min 1 time 0\n"
        "dd bs=1 count=6 2>/dev/null\n"
        f"printf 'mouse-got-%s\\n' '{nonce}'\n"
        "printf '\\033[?1000l'\n"
        "stty sane\n"
    )
    app.pane_run(f"/bin/sh {script}", pane=pane_id)

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    wait_for(
        lambda: f"mouse-ready-{nonce}" in dump(),
        timeout=60,
        message="mouse tracking enabled",
    )
    app.cli("pane", "click", "--col", "1", "--row", "1", "--pane", pane_id)
    wait_for(
        lambda: f"mouse-got-{nonce}" in dump(),
        timeout=60,
        message="X10 mouse report after pane click",
    )


def test_pane_dump_quiet_ms_times_out_while_output_changes(app, live_pane):
    """`pane dump --quiet-ms` keeps polling while the buffer is still growing
    and reports `quietTimedOut` when `--timeout-ms` elapses first."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:12]

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    app.pane_run(
        f'/bin/sh -c "printf started-%s {nonce}; echo; while :; do echo tick-{nonce}; sleep 0.2; done"',
        pane=pane_id,
    )
    wait_for(lambda: f"started-{nonce}" in dump(), timeout=60, message="the ticker to start")

    payload = app.cli_json(
        "pane",
        "dump",
        "--scrollback",
        "--quiet-ms",
        "300",
        "--timeout-ms",
        "800",
        "--pane",
        pane_id,
    )["dump"]
    assert payload["quietTimedOut"] is True
    assert f"started-{nonce}" in (payload.get("text") or "")

    app.cli("pane", "key", "ctrl+c", "--pane", pane_id)
    app.pane_run(f'/bin/sh -c "printf after-%s {nonce}; echo"', pane=pane_id)
    wait_for(lambda: f"after-{nonce}" in dump(), timeout=60, message="the shell after ctrl+c")
    settled = app.cli_json(
        "pane",
        "dump",
        "--scrollback",
        "--quiet-ms",
        "300",
        "--pane",
        pane_id,
    )["dump"]
    assert settled.get("quietTimedOut") is False
    assert f"after-{nonce}" in (settled.get("text") or "")
