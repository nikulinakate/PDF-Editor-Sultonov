#ifndef PDF_COMPRESSION_H
#define PDF_COMPRESSION_H
#include <stddef.h>
int pe_inflate(const unsigned char *source, size_t source_count, unsigned char *destination, size_t capacity, size_t *written);
#endif
