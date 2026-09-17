package internal

import "testing"

// Smoke test: mesh -> camera -> raster -> pixels. Proves the pipeline
// produces non-trivial coverage on the host before any UI wiring.
func TestCubeRasterSmoke(t *testing.T) {
	_, im, lit := drawCube(t, 64, 64, 0.6)
	t.Logf("lit pixels: %d / %d", lit, im.W*im.H)
	if lit < 200 {
		t.Fatalf("cube barely drew: %d lit pixels", lit)
	}
}
