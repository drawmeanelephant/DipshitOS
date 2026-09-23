package main

// The view contract, host-tested: markers go into go-gitui.spec verbatim,
// and each view must carry only its own colour class (the gate's PNG
// asserts count exactly those pixels).

import (
	"strings"
	"testing"

	"virelai/git/gitread"
)

func testData() *Data {
	return &Data{
		Root: "/host/R",
		Status: gitread.Status{
			HaveIndex: true,
			Staged:    []gitread.FileEntry{{Code: 'A', Path: "staged.txt"}},
			Modified:  []gitread.FileEntry{{Code: 'M', Path: "hello.txt"}},
			Untracked: []gitread.FileEntry{{Code: '?', Path: "loose.txt"}},
		},
		Log: []gitread.Rev{
			{Subject: "seed: second"},
			{Subject: "seed: first"},
		},
		Diffs: []gitread.FileDiff{
			{
				Path:   "hello.txt",
				Header: "@@ -2,1 +2,1 @@",
				Lines: []gitread.DiffLine{
					{Op: '-', Text: "delta"},
					{Op: '+', Text: "omega"},
				},
			},
			{
				Path:   "staged.txt",
				Header: "@@ -0,0 +1,1 @@",
				Lines:  []gitread.DiffLine{{Op: '+', Text: "staged line"}},
			},
		},
	}
}

// TestMarkerContract pins the exact serial strings go-gitui.spec asserts.
func TestMarkerContract(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "gitui: open id="},
		{markerAttach, "gitui: attached"},
		{markerPainted, "gitui: painted"},
		{markerReady, "gitui: ready"},
		{markerKey, "gitui: key "},
		{markerRepaint, "gitui: repainted"},
		{markerView, "gitui: view "},
		{markerMouse, "gitui: mouse b="},
		{markerClose, "gitui: close"},
		{markerOK, "gitui OK"},
		{markerRepo, "gitui: repo "},
		{markerStatus, "gitui: status "},
		{markerEntry, "gitui: entry "},
		{markerLog, "gitui: log n="},
		{markerSubject, "gitui: subject "},
		{markerDiff, "gitui: diff "},
		{markerErr, "gitui: error "},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func TestViewNames(t *testing.T) {
	if viewName(viewStatus) != "status" || viewName(viewLog) != "log" || viewName(viewDiff) != "diff" {
		t.Fatalf("view names: %q %q %q",
			viewName(viewStatus), viewName(viewLog), viewName(viewDiff))
	}
}

func TestStatusFrame(t *testing.T) {
	f := RenderFrame(testData(), viewStatus, 0)
	for _, want := range []string{
		colHeader + "  VirelaiOS × GOGITUI",
		"status",   // tab strip (rebuilt from parts)
		"staged=1", // counts line
		"modified=1",
		"untracked=1",
		colStaged + "A staged.txt", // section rows, right colours
		colMod + "M hello.txt",
		colUntrk + "? loose.txt",
		"/host/R", // root in the header
	} {
		if !strings.Contains(f, want) {
			t.Fatalf("status frame missing %q:\n%s", want, f)
		}
	}
	// View exclusivity: log/diff content must not appear.
	for _, bad := range []string{"seed: second", "@@ -2,1", "+omega"} {
		if strings.Contains(f, bad) {
			t.Fatalf("status frame leaks %q:\n%s", bad, f)
		}
	}
}

func TestLogFrame(t *testing.T) {
	f := RenderFrame(testData(), viewLog, 0)
	for _, want := range []string{
		colSha, // cyan shas
		"seed: second",
		"seed: first",
	} {
		if !strings.Contains(f, want) {
			t.Fatalf("log frame missing %q:\n%s", want, f)
		}
	}
	for _, bad := range []string{"staged=1", "@@ -2,1", "+omega", "A staged.txt"} {
		if strings.Contains(f, bad) {
			t.Fatalf("log frame leaks %q:\n%s", bad, f)
		}
	}
}

func TestDiffFrame(t *testing.T) {
	f := RenderFrame(testData(), viewDiff, 0)
	for _, want := range []string{
		"diff hello.txt",
		colHunk + "@@ -2,1 +2,1 @@",
		colMinus + "-delta",
		colPlus + "+omega",
		"diff staged.txt",
		colPlus + "+staged line",
	} {
		if !strings.Contains(f, want) {
			t.Fatalf("diff frame missing %q:\n%s", want, f)
		}
	}
	for _, bad := range []string{"staged=1", "seed: second", "A staged.txt"} {
		if strings.Contains(f, bad) {
			t.Fatalf("diff frame leaks %q:\n%s", bad, f)
		}
	}
}

// TestTabAtCell pins the M73i click math: SGR cells are 1-based over the
// client grid; row 1 is the tab strip, x windows follow tabLabel.
func TestTabAtCell(t *testing.T) {
	cases := []struct {
		x, y, want int
	}{
		{4, 1, viewStatus}, // inside "status"
		{2, 1, viewStatus}, // left edge
		{7, 1, viewStatus}, // right edge
		{8, 1, -1},         // the space after "status"
		{9, 1, -1},         // "|"
		{12, 1, viewLog},   // inside "log"
		{11, 1, viewLog},
		{13, 1, viewLog},
		{18, 1, viewDiff}, // inside "diff"
		{17, 1, viewDiff},
		{20, 1, viewDiff},
		{4, 2, -1}, // only row 1 is clickable
		{12, 0, -1},
		{0, 1, -1},
	}
	for _, c := range cases {
		if got := tabAtCell(c.x, c.y); got != c.want {
			t.Fatalf("tabAtCell(%d,%d) = %d want %d", c.x, c.y, got, c.want)
		}
	}
}

func TestScrollClamp(t *testing.T) {
	d := testData()
	full := RenderFrame(d, viewLog, 0)
	huge := RenderFrame(d, viewLog, 10000)
	if huge != full {
		t.Fatalf("oversize scroll not clamped:\n%q\nvs\n%q", huge, full)
	}
	if neg := RenderFrame(d, viewLog, -5); neg != full {
		t.Fatalf("negative scroll not clamped")
	}
}
