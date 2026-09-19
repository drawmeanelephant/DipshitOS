#pragma once
#include <stddef.h>
#include <stdarg.h>
int printf(const char *fmt, ...);
int snprintf(char *buf, size_t cap, const char *fmt, ...);
int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap);
int putchar(int c);
int puts(const char *s);
typedef struct FILE FILE;
