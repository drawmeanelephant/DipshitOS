package internal

type clipVertex struct {
	X, Y, Z, W, R, G, B float32
}

func newClip(p Vec3, w float32, c RGB) clipVertex {
	return clipVertex{p.X, p.Y, p.Z, w, float32(c.R), float32(c.G), float32(c.B)}
}

func (v clipVertex) distance(p int) float32 {
	switch p {
	case 0:
		return v.W + v.X
	case 1:
		return v.W - v.X
	case 2:
		return v.W + v.Y
	case 3:
		return v.W - v.Y
	case 4:
		return v.Z
	default:
		return v.W - v.Z
	}
}

func clipPlane(in []clipVertex, plane int) []clipVertex {
	if len(in) == 0 {
		return nil
	}
	out := make([]clipVertex, 0, len(in)+1)
	a := in[len(in)-1]
	da := a.distance(plane)
	for _, b := range in {
		db := b.distance(plane)
		if (da >= 0) != (db >= 0) {
			t := da / (da - db)
			out = append(out, clipVertex{
				a.X + t*(b.X-a.X), a.Y + t*(b.Y-a.Y),
				a.Z + t*(b.Z-a.Z), a.W + t*(b.W-a.W),
				a.R + t*(b.R-a.R), a.G + t*(b.G-a.G), a.B + t*(b.B-a.B),
			})
		}
		if db >= 0 {
			out = append(out, b)
		}
		a, da = b, db
	}
	return out
}

func (v clipVertex) ndc() Vert {
	iw := 1 / v.W
	return Vert{v.X * iw, v.Y * iw, v.Z * iw, iw, v.R * iw, v.G * iw, v.B * iw}
}
