// fib.go — exercise 2 sample program for GOOS=virelai.
//
// Deliberately dependency-free: println only, no os/syscall imports
// (the phase-2 std port layer is not part of GOOS=virelai yet).
package main

func fib(n int) int {
	if n < 2 {
		return n
	}
	a, b := 0, 1
	for i := 2; i <= n; i++ {
		a, b = b, a+b
	}
	return b
}

func main() {
	for i := 0; i <= 10; i++ {
		println("fib", i, "=", fib(i))
	}
	println("fib-lab OK")
}
