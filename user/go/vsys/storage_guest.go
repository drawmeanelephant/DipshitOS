//go:build virelai

package vsys

// Volume free space over sys_file_free (slot 37, ADR 0007).
//
// free(volume) returns the free byte count on a volume: 0 = DATA, 1 = ESP.
// Returns the byte count, or a negative errno (EINVAL bad volume, ENOENT
// unmounted).
const SlotFileFree uintptr = 37

// VolumeFree returns the free byte count on the given volume (slot 37), or
// the raw negative kernel error.
func VolumeFree(volume uint64) int64 {
	return syscallFn(SlotFileFree, uintptr(volume), 0, 0, 0)
}
