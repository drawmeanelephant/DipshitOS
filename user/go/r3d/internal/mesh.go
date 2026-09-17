package internal

// Cube builds the demo mesh: a unit cube at the origin (half extent s)
// whose six faces carry six distinct flat colors. Winding is CCW seen from
// outside; the rasterizer is double-sided, so orientation only matters for
// shading sanity, not coverage.
func Cube(s float32) []Tri {
	r := RGB{0xE4, 0x3D, 0x3D} // +Z red
	g := RGB{0x3D, 0xE4, 0x3D} // -Z green
	b := RGB{0x3D, 0x6B, 0xE4} // +X blue
	y := RGB{0xE4, 0xD4, 0x3D} // -X yellow
	m := RGB{0xC3, 0x3D, 0xE4} // +Y magenta
	c := RGB{0x3D, 0xE4, 0xD4} // -Y cyan
	p := [][4]Vec3{
		// quads: (a,b,c,d) -> tris (a,b,c) (a,c,d)
		{{s, -s, s}, {s, s, s}, {-s, s, s}, {-s, -s, s}},     // +Z red
		{{-s, -s, -s}, {-s, s, -s}, {s, s, -s}, {s, -s, -s}}, // -Z green
		{{s, -s, -s}, {s, s, -s}, {s, s, s}, {s, -s, s}},     // +X blue
		{{-s, -s, s}, {-s, s, s}, {-s, s, -s}, {-s, -s, -s}}, // -X yellow
		{{-s, s, s}, {s, s, s}, {s, s, -s}, {-s, s, -s}},     // +Y magenta
		{{-s, -s, -s}, {s, -s, -s}, {s, -s, s}, {-s, -s, s}}, // -Y cyan
	}
	cols := [6][4]RGB{
		{r, r, r, r}, {g, g, g, g}, {b, b, b, b},
		{y, y, y, y}, {m, m, m, m}, {c, c, c, c},
	}
	tris := make([]Tri, 0, 12)
	for f, q := range p {
		cc := cols[f]
		tris = append(tris,
			Tri{V0: q[0], V1: q[1], V2: q[2], C0: cc[0], C1: cc[1], C2: cc[2]},
			Tri{V0: q[0], V1: q[2], V2: q[3], C0: cc[0], C1: cc[2], C2: cc[3]},
		)
	}
	return tris
}

// Spin returns a Y-axis rotation matrix for angle radians.
func Spin(a float32) Mat4 {
	s, c := sincosf(a)
	return Mat4{
		c, 0, s, 0,
		0, 1, 0, 0,
		-s, 0, c, 0,
		0, 0, 0, 1,
	}
}

// Model applies a model matrix to every triangle position (colors pass
// through).
func Model(tris []Tri, m Mat4) []Tri {
	out := make([]Tri, len(tris))
	for i, t := range tris {
		out[i] = t
		out[i].V0, _ = apply4(m, t.V0, 1)
		out[i].V1, _ = apply4(m, t.V1, 1)
		out[i].V2, _ = apply4(m, t.V2, 1)
	}
	return out
}
