package theme

import "testing"

func TestDarkMatchesZigThemeZig(t *testing.T) {
	// Byte-identical to user/src/lib/ui/theme.zig THEME_DARK / CHROME_DARK
	// for the colours #1530 asked to agree on.
	if Dark.Bg != 0x182026 || Dark.Surface != 0x222d35 || Dark.Border != 0x334155 {
		t.Fatalf("dark chrome %#x/%#x/%#x", Dark.Bg, Dark.Surface, Dark.Border)
	}
	if Dark.Accent != 0x3b82f6 || Dark.Text != 0xffffff || Dark.Muted != 0x94a3b8 {
		t.Fatalf("dark ink %#x/%#x/%#x", Dark.Accent, Dark.Text, Dark.Muted)
	}
	if Dark.BtnIdle != 0x2d3748 || Dark.BtnHover != 0x4a5568 || Dark.BtnPressed != 0x1a202c {
		t.Fatalf("dark buttons %#x/%#x/%#x", Dark.BtnIdle, Dark.BtnHover, Dark.BtnPressed)
	}
	if Dark.PadSM != 4 || Dark.PadMD != 8 || Dark.BorderW != 1 || Dark.FocusW != 2 {
		t.Fatalf("spacing pad_sm=%d pad_md=%d border=%d focus=%d", Dark.PadSM, Dark.PadMD, Dark.BorderW, Dark.FocusW)
	}
	if Dark.Danger != 0xef4444 || Dark.Caret != 0x3b82f6 {
		t.Fatalf("dark danger/caret %#x/%#x", Dark.Danger, Dark.Caret)
	}
}

func TestLightMatchesZigThemeLight(t *testing.T) {
	if Light.Bg != 0xf1f5f9 || Light.Surface != 0xffffff || Light.Accent != 0x2563eb {
		t.Fatalf("light %#x/%#x/%#x", Light.Bg, Light.Surface, Light.Accent)
	}
}

func TestSetAndName(t *testing.T) {
	saved := Current
	defer func() { Current = saved }()
	Current = Dark
	if !Set("light") || Name() != "light" || Current.Bg != Light.Bg {
		t.Fatal("Set(light) did not switch")
	}
	if !Set("dark") || Name() != "dark" {
		t.Fatal("Set(dark) did not switch back")
	}
	if Set("amber") || Set("") || Set("DARK") {
		t.Fatal("unknown names must be refused")
	}
}

func TestParseAndApplySettings(t *testing.T) {
	saved := Current
	defer func() { Current = saved }()
	Current = Dark
	if ParseSettings([]byte("#v2\nhostname=virelai\n")) != "" {
		t.Fatal("missing theme key must be empty")
	}
	if ParseSettings([]byte("#v2\ntheme=light\nwm=gotabwm\n")) != "light" {
		t.Fatal("theme=light")
	}
	if ParseSettings([]byte("theme=amber\n")) != "" {
		t.Fatal("amber has no Go reader")
	}
	if !ApplySettings([]byte("#v2\ntheme=light\n")) || Name() != "light" {
		t.Fatal("ApplySettings light")
	}
}

func TestHex6(t *testing.T) {
	if got := Hex6(0x182026); got != "0x182026" {
		t.Fatalf("Hex6 = %q", got)
	}
	if got := Hex6(0x3b82f6); got != "0x3b82f6" {
		t.Fatalf("Hex6 accent = %q", got)
	}
	if got := Hex6(0); got != "0x000000" {
		t.Fatalf("Hex6 zero = %q", got)
	}
}

func TestBootDefaultIsDark(t *testing.T) {
	if Current.Bg != Dark.Bg || Name() != "dark" {
		t.Fatal("package default must be dark")
	}
}
