# Authoring a VirelaiOS Go app

This is the short path from an empty `user/go/<app>/main.go` to an app
that can be staged into a VZ gate. It describes the Go EL0 surface; it does
not replace the syscall or window-management ADRs.

## 1. Start with the app shell

A normal windowed Go app uses `tabapp` for the window/WM handshake and
`appkit.Loop` for the lifecycle. `appkit` is deliberately small: it presents
once, dispatches close/resize events, and repaints only when the app says its
state changed.

```go
package main

import (
	"virelai/appkit"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "MYAPP.ELF"
	appTitle = "My App"
	natW     = 512
	natH     = 384
)

func draw(ta *tabapp.TabApp) {
	r := ta.Layout(tabapp.Rect{W: natW, H: natH}, natW, natH)
	// Replace this with the app's current frame and paint r into ta.Win.
	_ = r
}

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle,
		X: 32, Y: 32, W: natW, H: natH,
	})
	if ta == nil {
		vi.ConsoleLine("myapp: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine("myapp: open id=" + vi.Itoa64(int64(ta.Win)))

	loop := appkit.NewLoop(ta, func() { draw(ta) }, nil)
	loop.OnInitialPresent = func() { vi.ConsoleLine("myapp: present") }
	loop.OnExit = func(status int) {
		ta.Close()
		vi.ConsoleLine("myapp: close") // after WinClose returned
		vi.Exit(status)
	}
	loop.Run()
}
```

`tabapp.Init` opens the window and makes a best-effort fullscreen-tab
declaration. A refused declaration is not fatal: the app remains a normal
window at its requested size. The live implementation is in
[`user/go/tabapp/tabapp.go`](../user/go/tabapp/tabapp.go); the lifecycle
implementation is in [`user/go/appkit/loop.go`](../user/go/appkit/loop.go).
The [`user/go/tabapp/demo`](../user/go/tabapp/demo) app shows widgets and
resize-aware drawing.

For keyboard, mouse, dialog, or button state, use the existing widgets and
pure helpers rather than inventing a second event or geometry model. The
small dialog state machine is in
[`user/go/appkit/dialog.go`](../user/go/appkit/dialog.go), and the widget
surface is [`user/go/widgets/widgets.go`](../user/go/widgets/widgets.go).

A TTY application is different: it owns `/dev/tty` and feeds terminal bytes
into its own model. [`user/go/charmhello/main.go`](../user/go/charmhello/main.go)
is the bound-tty/Bubble Tea example; do not put a TUI behind the widget
window loop merely because both are Go apps.

## 2. Markers are evidence, not decoration

A gate marker must be printed only after the operation that makes it true has
returned. For example:

```go
ta.Present()
vi.ConsoleLine("myapp: present") // after WinPresent returned
```

Likewise, print an error only after the syscall or operation that produced it
has returned, and keep the marker's value stable enough for a spec to pin.
`vi.ConsoleLine` is serial-observable; bytes written to a windowed `/dev/tty`
paint the terminal grid instead. Choose the channel deliberately, and never
claim a result from a marker printed before the work.

## 3. WM_RPC: ask, do not bypass

Apps do not call the WM-only `wmctl` syscall. They send a 38-byte WM_RPC
frame through the registered seat with the helpers in
[`user/go/vi/wmclient.go`](../user/go/vi/wmclient.go). The frame is bounded:
64-byte mailbox maximum, 24-byte title, 8-bit window id and requester, and a
short bounded wait for the matching ack. A timeout, missing seat, or invalid
width is an honest `false`, not a reason to spin.

The current `GOTABWM.ELF` Go seat applies these request kinds:

| Kind | Name | Meaning |
| ---: | --- | --- |
| 1 | `raise` | Focus/raise the tab. |
| 5 | `attach` | Add/attach the client tab. |
| 6 | `detach` | Remove the client tab. |
| 7 | `cycle` | Advance tab focus. |
| 8 | `declare_fullscreen` | Register the tab and propose the full viewport. |

The current `GOTABWM.ELF` seat refuses kinds **2 (`config`), 3
(`register_action`), 4 (`invoke_action`), 9 (`nav_declare`), and 10
(`nav_poll`)** with `applied=0`. Those kinds exist in the frozen/additive wire
vocabulary, but a guide must not imply that the current Go seat implements
them. Use the higher-level `tabapp` methods when available and handle refusal
explicitly if an app needs a capability that is not implemented yet.

`tabapp.Init` already performs kind 8. For an app that implements a later
capability, call the corresponding `vi` helper only after checking its return
value, and keep the fallback path in the same app rather than making the WM
silently guess.

## 4. Build and run the host tests

The guest build uses the pinned `GOOS=virelai` fork. Ordinary Go package tests
run from the module root:

```bash
cd user/go
go test ./...
```

A shipping app gets a small builder beside the existing builders. The compact
[`tools/go/build-goterm.sh`](../tools/go/build-goterm.sh) is the basic example;
[`tools/go/build-rss.sh`](../tools/go/build-rss.sh) shows the complete current
image checks. A builder must:

1. set `GOOS=virelai GOARCH=arm64`, `CGO_ENABLED=0`, and the pinned
   `GOROOT`; use `GO111MODULE=off` with a temporary `GOPATH` for a basic app,
   or the transient module/overlay shape when the app has external modules;
2. build `virelai/<app>` to `.build/go/<APP>.ELF`;
3. fail if the output is missing or its initialized image exceeds 32 MiB; leave
   the loader's 64 MiB mapped-image bound and any stricter ceiling required by
   the chosen image shape enforced; and
4. leave module-cache and repository sources unchanged.

Run the builder before a live gate:

```bash
bash tools/go/build-myapp.sh
```

The guest has no libc or POSIX. Prefer the `virelai/vi`, `virelai/tabapp`,
`virelai/appkit`, and `virelai/widgets` packages already in this tree over
host-only standard-library assumptions.

## 5. Add one declarative gate

Copy the shape of [`tools/gate/specs/go-charmhello.spec`](../tools/gate/specs/go-charmhello.spec),
not a new ad-hoc verification script. A useful app spec has:

- a `vgate_name`, `vgate_share seed`, and runner flags;
- a monitor script that launches the app;
- a setup block that fails honestly if `.build/go/<APP>.ELF` is missing, then
  stages it into the share;
- a bounded `vgate_run` with a script/input stage keyed to an app marker;
- `vgate_assert` lines for boot, launch, lifecycle, and absence of crashes;
- a final `--script-expect` set to the app's post-close marker, so the runner
  stops only after that marker rather than after a script-supplied echo.

Use `--input-chords` for HID input, `--input-string` for literal text, and
`--screenshot-after` only when the claim is about scanout pixels. The gate must
be able to fail if the app is replaced by a constant: sequence on a marker
emitted after the syscall or after real work, and assert a value that the guest
computed. Keep each run bounded; a missing marker is a failure, never a skip.

The reusable spec format is documented in
[`tools/gate/SPEC.md`](../tools/gate/SPEC.md). Run one class-B member with:

```bash
just gate <gate-id>
```

A class-A host test is still useful for pure state and byte-shaping logic, but
it is not a substitute for the VZ gate when the card claims real guest input,
window ownership, or pixels.

## 6. Ship it in the desktop catalogue

For a user-visible app, add its executable to [`image/apps.txt`](../image/apps.txt)
with the display name, icon, and (when appropriate) `dock=true`. Keep the
manifest executable name and the builder's output name in agreement. A gate
may stage an app directly without adding it to the daily catalogue, but that
proves the binary, not the launcher integration.

Before opening a PR, run the focused host tests, the app's class-B gate,
`bash tools/status/verify-issue-coordination.sh`, and the relevant portable
checks. The canonical gate policy is in [`docs/testing.md`](testing.md); the
canonical milestone state is in [`docs/status.md`](status.md).
