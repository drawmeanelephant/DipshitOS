package vi

// M71h (#1567): the milestone-eleven title syscall (slot 61,
// `sys_win_set_title(id, text_ptr, text_len)` — kernel/src/syscall.zig) had no
// Go wrapper, because until GOVIEW.ELF no Go app needed one: on the tabbed
// desktop the tab's title rides the kind-8 declare, so an app never had to
// title a window itself.
//
// GOVIEW is the first Go app that also has to run off the seat (the
// live-image-viewer gate boots the shim compositor, where there is no tab strip
// to carry a title), and it replaces Zig VIEW.BIN, whose gate asserted that the
// app titled its window. So the wrapper lands with the app that needs it.
const SlotWinSetTitle uintptr = 61

// WinSetTitle sets the title bar of window id to text. The kernel truncates to
// its own bound; a negative return means the window refused it. Empty text
// clears the title rather than setting an empty one.
func WinSetTitle(id int, text string) int64 {
	if text == "" {
		return syscall3(SlotWinSetTitle, uintptr(id), 0, 0)
	}
	return syscall3(SlotWinSetTitle, uintptr(id), strPtr(text), uintptr(len(text)))
}
