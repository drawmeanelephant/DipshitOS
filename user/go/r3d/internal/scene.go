package internal

const SceneWidth = 220
const SceneHeight = 144

func Scene() *Image {
	im := NewImage(SceneWidth, SceneHeight, PixBGRA)
	cam := Cam{Pos: Vec3{0, 1.5, 4}, Target: Vec3{}, Up: Vec3{0, 1, 0}, FovDeg: 50, Aspect: float32(SceneWidth) / SceneHeight, Near: 0.1, Far: 100}
	r := NewRasterizer(im, cam, RGB{16, 16, 20})
	r.Reset()
	for _, t := range Model(Cube(1), Spin(0.6)) {
		r.Draw(t)
	}
	return im
}
