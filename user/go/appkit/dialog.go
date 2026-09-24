package appkit

import (
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// DialogKind identifies the small set of app-owned modal flows appkit owns.
// These are deliberately not replacements for the kernel's WIN_UNSAVED dialog:
// an app may ask for a path or confirm an overwrite, while the kernel remains
// the authority for the unsaved-document contract.
type DialogKind uint8

const (
	MessageDialog DialogKind = iota
	ConfirmDialog
	PromptDialog
)

// DialogButton is both a drawable control and its hit rectangle. Keeping the
// rectangle beside the label makes the pure state machine and the guest draw
// path agree without a second geometry source.
type DialogButton struct {
	Label string
	R     widgets.Rect
}

// Dialog is a modal state machine. It has no syscall or drawing dependency in
// its state transitions, so host tests can cover focus, cancellation, and text
// input without a window.
type Dialog struct {
	Kind    DialogKind
	Title   string
	Message string
	Input   string
	Buttons []DialogButton
	Focus   int
	Result  string
	Open    bool
	R       widgets.Rect
}

// NewMessage creates a one-button informational dialog.
func NewMessage(title, message string) Dialog {
	return newDialog(MessageDialog, title, message, false)
}

// NewConfirm creates a Yes/No dialog. No is the safe default focus.
func NewConfirm(title, message string) Dialog {
	d := newDialog(ConfirmDialog, title, message, false)
	d.Focus = 1
	return d
}

// NewPrompt creates a bounded single-line text prompt.
func NewPrompt(title, message string) Dialog {
	return newDialog(PromptDialog, title, message, true)
}

func newDialog(kind DialogKind, title, message string, prompt bool) Dialog {
	d := Dialog{
		Kind:    kind,
		Title:   title,
		Message: message,
		Open:    true,
		R:       widgets.Rect{X: 96, Y: 72, W: 320, H: 156},
	}
	if prompt {
		d.Buttons = []DialogButton{
			{Label: "OK", R: widgets.Rect{X: 246, Y: 184, W: 72, H: 28}},
			{Label: "Cancel", R: widgets.Rect{X: 326, Y: 184, W: 72, H: 28}},
		}
	} else if kind == ConfirmDialog {
		d.Buttons = []DialogButton{
			{Label: "Yes", R: widgets.Rect{X: 206, Y: 184, W: 72, H: 28}},
			{Label: "No", R: widgets.Rect{X: 286, Y: 184, W: 72, H: 28}},
		}
	} else {
		d.Buttons = []DialogButton{{Label: "OK", R: widgets.Rect{X: 286, Y: 184, W: 72, H: 28}}}
	}
	return d
}

// HandleKey consumes one event while the dialog is open. changed means the
// caller should repaint; done means the dialog has produced its result and
// has closed itself.
func (d *Dialog) HandleKey(ev vi.Event) (changed, done bool) {
	if !d.Open || ev.Kind != vi.EvKeyDown {
		return false, false
	}
	// The event wire exposes the HID usage in Arg0 and the decoded symbol in
	// Arg1. Accept both spellings, matching existing app handlers and tests.
	usage, ch := ev.Arg0, ev.Arg1
	switch {
	case usage == 0x28 || ch == '\r' || ch == '\n':
		d.choose()
		return true, true
	case usage == 0x29 || ch == 0x1b:
		d.cancel()
		return true, true
	case usage == 0x2b || ch == '\t':
		if len(d.Buttons) > 0 {
			d.Focus = (d.Focus + 1) % len(d.Buttons)
		}
		return true, false
	case (usage == 0x2a || ch == 0x08 || ch == 0x7f) && d.Kind == PromptDialog:
		if d.Input != "" {
			d.Input = d.Input[:len(d.Input)-1]
		}
		return true, false
	case d.Kind == PromptDialog && ch >= 0x20 && ch < 0x7f:
		if len(d.Input) < 128 {
			d.Input += string(byte(ch))
		}
		return true, false
	}
	return false, false
}

// HandleMouse handles a left-button press at a canvas point. A click focuses
// and chooses the matching button; it never returns to the app handler.
func (d *Dialog) HandleMouse(x, y int, down bool) (changed, done bool) {
	if !d.Open || !down {
		return false, false
	}
	for i := range d.Buttons {
		if d.Buttons[i].R.Contains(x, y) {
			d.Focus = i
			d.choose()
			return true, true
		}
	}
	return false, false
}

func (d *Dialog) choose() {
	if d.Focus < 0 || d.Focus >= len(d.Buttons) {
		d.cancel()
		return
	}
	d.Result = d.Buttons[d.Focus].Label
	if d.Kind == PromptDialog && d.Focus == 0 {
		d.Result = d.Input
	}
	d.Open = false
}

func (d *Dialog) cancel() {
	d.Result = "cancel"
	d.Open = false
}

// Draw renders the dialog on the same integer canvas as the app widgets. It
// is intentionally simple: a plate, text rows, and the existing Button widget.
// The app remains responsible for choosing the plate rect and for repainting
// the frame around it.
func (d *Dialog) Draw(c widgets.Canvas) {
	if !d.Open {
		return
	}
	tok := theme.Current
	c.FillRect(d.R, tok.Surface)
	heading := widgets.Text{R: d.R.Inset(12), Label: d.Title, Fg: tok.Text, Bg: tok.Surface}
	heading.Draw(c)
	body := widgets.Text{R: widgets.Rect{X: d.R.X + 12, Y: d.R.Y + 42, W: d.R.W - 24, H: 28}, Label: d.Message, Fg: tok.Muted, Bg: tok.Surface}
	body.Draw(c)
	if d.Kind == PromptDialog {
		line := widgets.Text{R: widgets.Rect{X: d.R.X + 12, Y: d.R.Y + 82, W: d.R.W - 24, H: 24}, Label: d.Input, Fg: tok.Ink, Bg: tok.ChromeBg}
		line.Draw(c)
	}
	for i := range d.Buttons {
		b := &widgets.Button{
			R:        d.Buttons[i].R,
			Label:    d.Buttons[i].Label,
			Focused:  i == d.Focus,
			Face:     tok.BtnIdle,
			Border:   tok.Border,
			LabelRGB: tok.Text,
		}
		b.Draw(c)
	}
}
