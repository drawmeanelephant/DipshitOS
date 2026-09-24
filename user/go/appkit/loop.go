// Package appkit is the shared Go application shell for tabbed desktop apps.
// It owns the lifecycle that used to be copied into every user/go/*/main.go:
// initialize through tabapp, present once, poll events, route window lifecycle
// actions, repaint only when an event says the frame changed, and exit through
// one close contract.
//
// Keep this package small. It intentionally does not import fmt, os, strings,
// or time: the Go EL0 image budget is part of every app's boot contract.
// Dialog state is pure and lives beside this loop; the visual widgets remain
// in virelai/widgets.
package appkit

import (
	"virelai/tabapp"
	"virelai/vi"
)

// EventSource is the injectable form of vi.PollEventRaw. Tests can provide a
// finite sequence without making guest syscalls.
type EventSource func() (vi.Event, int64, bool)

// Loop is the standard tab-app event loop. Draw must paint the current state;
// Handle returns true only when the event changed visible state. ShouldQuit is
// optional and is consulted after Handle, so an app can turn Escape or a
// button into a clean exit without bypassing the loop. OnExit, when supplied,
// owns the app-specific marker/cleanup contract; otherwise Loop calls
// TabApp.CloseAndExit directly.
type Loop struct {
	Tab              *tabapp.TabApp
	Draw             func()
	Handle           func(vi.Event) bool
	ShouldQuit       func() (status int, requested bool)
	OnExit           func(status int)
	OnInitialPresent func()

	presented bool
}

func NewLoop(ta *tabapp.TabApp, draw func(), handle func(vi.Event) bool) *Loop {
	return &Loop{Tab: ta, Draw: draw, Handle: handle}
}

// Present draws and flushes one frame. The callback is intentionally after
// Present: guest markers must only be emitted once the syscall returned.
func (l *Loop) Present() {
	if l.Draw != nil {
		l.Draw()
	}
	if l.Tab != nil {
		l.Tab.Present()
	}
	if l.OnInitialPresent != nil && !l.presented {
		l.OnInitialPresent()
	}
	l.presented = true
}

// Exit runs the configured clean-exit contract. A caller-supplied OnExit is
// used for app markers and cleanup; the default preserves tabapp's simple
// close-and-exit behaviour.
func (l *Loop) Exit(status int) {
	if l.OnExit != nil {
		l.OnExit(status)
		return
	}
	if l.Tab != nil {
		l.Tab.CloseAndExit(status)
	}
}

// Run presents the initial frame and then uses the live guest event source.
func (l *Loop) Run() int {
	return l.RunWith(vi.PollEventRaw, vi.Sleep)
}

// RunWith is the deterministic form used by host tests and embedders that
// already own their event source. A negative poll result ends the loop; an
// empty result yields to the scheduler.
func (l *Loop) RunWith(poll EventSource, sleep func(uint64)) int {
	l.Present()
	for {
		ev, result, ok := poll()
		if !ok {
			if result < 0 {
				// The former hand-written loops treated a queue refusal as a
				// normal loop exit and returned zero from main. Preserve that
				// process contract instead of leaking a kernel errno as the
				// application's exit status.
				return 0
			}
			if sleep != nil {
				sleep(1)
			}
			continue
		}

		if l.Tab != nil {
			switch l.Tab.Dispatch(ev) {
			case tabapp.ActionClosed:
				l.Exit(0)
				return 0
			case tabapp.ActionResized:
				l.Present()
			case tabapp.ActionNone:
				dirty := l.Handle != nil && l.Handle(ev)
				if l.ShouldQuit != nil {
					if status, requested := l.ShouldQuit(); requested {
						l.Exit(status)
						return status
					}
				}
				if dirty {
					l.Present()
				}
			}
			continue
		}
		if l.Handle != nil {
			dirty := l.Handle(ev)
			if l.ShouldQuit != nil {
				if status, requested := l.ShouldQuit(); requested {
					l.Exit(status)
					return status
				}
			}
			if dirty {
				l.Present()
			}
		}
	}
}
