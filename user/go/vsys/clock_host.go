//go:build !virelai

package vsys

// The host build has no VirelaiOS counter and no CNTPCT_EL0: the clock is
// an honest 0 here, and every clock-dependent path is exercised with an
// injected nowFn (see clock_test.go / net_test.go).
func platformNano() int64 { return 0 }
