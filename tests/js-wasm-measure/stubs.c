/* Freestanding C crumbs so an existing JS engine can link with
 *   zig cc -target wasm32-freestanding -nostdlib
 * without WASI or a libc. Size-measurement only — not a product runtime. */
#include <stdarg.h>
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d == s || n == 0) return dst;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    while (n--) {
        if (*x != *y) return (int)*x - (int)*y;
        x++;
        y++;
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    while (n && *a && *a == *b) {
        a++;
        b++;
        n--;
    }
    if (n == 0) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

char *strcpy(char *dst, const char *src) {
    char *d = dst;
    while ((*d++ = *src++)) {
    }
    return dst;
}

char *strncpy(char *dst, const char *src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i]; i++) dst[i] = src[i];
    for (; i < n; i++) dst[i] = 0;
    return dst;
}

char *strchr(const char *s, int c) {
    while (*s) {
        if ((unsigned char)*s == (unsigned char)c) return (char *)s;
        s++;
    }
    if (c == 0) return (char *)s;
    return 0;
}

void abort(void) {
    __builtin_trap();
}

void __assert_fail(const char *a, const char *b, unsigned c, const char *d) {
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    abort();
}

double modf(double x, double *iptr) {
    long long i = (long long)x;
    *iptr = (double)i;
    return x - *iptr;
}

double strtod(const char *nptr, char **endptr) {
    const char *s = nptr;
    int neg = 0;
    double v = 0.0;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    if (*s == '+' || *s == '-') {
        neg = (*s == '-');
        s++;
    }
    while (*s >= '0' && *s <= '9') {
        v = v * 10.0 + (double)(*s - '0');
        s++;
    }
    if (*s == '.') {
        double place = 0.1;
        s++;
        while (*s >= '0' && *s <= '9') {
            v += (double)(*s - '0') * place;
            place *= 0.1;
            s++;
        }
    }
    if (endptr) *endptr = (char *)s;
    return neg ? -v : v;
}

static void emit_char(char *buf, size_t cap, size_t *n, char ch) {
    if (*n + 1 < cap) buf[*n] = ch;
    (*n)++;
}

static void emit_str(char *buf, size_t cap, size_t *n, const char *s) {
    while (*s) emit_char(buf, cap, n, *s++);
}

static void emit_uint(char *buf, size_t cap, size_t *n, unsigned long v, int base, int upper) {
    char tmp[32];
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int i = 0;
    if (v == 0) {
        emit_char(buf, cap, n, '0');
        return;
    }
    while (v && i < (int)sizeof(tmp)) {
        tmp[i++] = dig[v % (unsigned)base];
        v /= (unsigned)base;
    }
    while (i--) emit_char(buf, cap, n, tmp[i]);
}

int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap) {
    size_t n = 0;
    if (cap == 0) buf = 0;
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            emit_char(buf, cap, &n, *fmt);
            continue;
        }
        fmt++;
        while (*fmt == 'l' || *fmt == 'z' || *fmt == '.' || (*fmt >= '0' && *fmt <= '9')) fmt++;
        switch (*fmt) {
            case '%':
                emit_char(buf, cap, &n, '%');
                break;
            case 's': {
                const char *s = va_arg(ap, const char *);
                emit_str(buf, cap, &n, s ? s : "(null)");
                break;
            }
            case 'c':
                emit_char(buf, cap, &n, (char)va_arg(ap, int));
                break;
            case 'd':
            case 'i': {
                long v = va_arg(ap, int);
                if (v < 0) {
                    emit_char(buf, cap, &n, '-');
                    emit_uint(buf, cap, &n, (unsigned long)(-v), 10, 0);
                } else {
                    emit_uint(buf, cap, &n, (unsigned long)v, 10, 0);
                }
                break;
            }
            case 'u':
                emit_uint(buf, cap, &n, va_arg(ap, unsigned), 10, 0);
                break;
            case 'x':
                emit_uint(buf, cap, &n, va_arg(ap, unsigned), 16, 0);
                break;
            case 'X':
                emit_uint(buf, cap, &n, va_arg(ap, unsigned), 16, 1);
                break;
            case 'p':
                emit_str(buf, cap, &n, "0x");
                emit_uint(buf, cap, &n, (unsigned long)(unsigned)va_arg(ap, void *), 16, 0);
                break;
            case 'g':
            case 'f':
            case 'e': {
                double d = va_arg(ap, double);
                if (d < 0) {
                    emit_char(buf, cap, &n, '-');
                    d = -d;
                }
                long whole = (long)d;
                emit_uint(buf, cap, &n, (unsigned long)whole, 10, 0);
                emit_char(buf, cap, &n, '.');
                long frac = (long)((d - (double)whole) * 1000000.0);
                if (frac < 0) frac = 0;
                emit_uint(buf, cap, &n, (unsigned long)frac, 10, 0);
                break;
            }
            default:
                emit_char(buf, cap, &n, '%');
                if (*fmt) emit_char(buf, cap, &n, *fmt);
                break;
        }
    }
    if (cap) {
        size_t term = n < cap ? n : cap - 1;
        buf[term] = 0;
    }
    return (int)n;
}

int snprintf(char *buf, size_t cap, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    return r;
}

int printf(const char *fmt, ...) {
    (void)fmt;
    return 0;
}

int putchar(int c) {
    return c;
}

int puts(const char *s) {
    (void)s;
    return 0;
}
