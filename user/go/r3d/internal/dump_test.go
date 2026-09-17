package internal

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// TestDumpCanvas writes the 1094x701 canvas BGRX bytes (the exact stream
// windowSink produces for the 1100x720 tab viewport at the TABWM sidebar)
// to $R3D_DUMP so the host golden is generated from the same pipeline the
// guest paints.
func TestDumpCanvas(t *testing.T) {
	out := os.Getenv("R3D_DUMP")
	if out == "" {
		t.Skip("R3D_DUMP not set")
	}
	im := Scene()
	CW, CH := 1094, 701
	buf := make([]byte, CW*CH*4)
	for y := 0; y < CH; y++ {
		sy := y * SceneHeight / CH
		for x := 0; x < CW; x++ {
			sx := x * SceneWidth / CW
			r, g, b := im.GetPx(sx, sy)
			k := (y*CW + x) * 4
			buf[k+0] = b
			buf[k+1] = g
			buf[k+2] = r
		}
	}
	if err := os.WriteFile(out, buf, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(buf)
	t.Log("raw sha256", hex.EncodeToString(sum[:]))
}
