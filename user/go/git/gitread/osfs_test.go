package gitread

// Host filesystem backend for tests only (_test.go: never part of the
// guest build). The guest uses VirelaiFS; the gate proves that path against
// a real `git` repository on the share.

import "os"

type osFS struct{}

func (osFS) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (osFS) ReadDir(path string) ([]DirInfo, error) {
	ents, err := os.ReadDir(path)
	if err != nil {
		return nil, err
	}
	out := make([]DirInfo, 0, len(ents))
	for _, e := range ents {
		out = append(out, DirInfo{Name: e.Name(), IsDir: e.IsDir()})
	}
	return out, nil
}
