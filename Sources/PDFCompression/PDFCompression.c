#include "PDFCompression.h"
#include <zlib.h>
#include <limits.h>
int pe_inflate(const unsigned char *source, size_t count, unsigned char *destination, size_t capacity, size_t *written) {
    if (count > UINT_MAX || capacity > UINT_MAX || !written) return -1;
    z_stream stream = {0};
    stream.next_in = (Bytef *)source;
    stream.avail_in = (uInt)count;
    stream.next_out = destination;
    stream.avail_out = (uInt)capacity;
    if (inflateInit(&stream) != Z_OK) return -1;
    int result = inflate(&stream, Z_FINISH);
    *written = stream.total_out;
    int complete = result == Z_STREAM_END && stream.avail_in == 0;
    inflateEnd(&stream);
    return complete ? 0 : -1;
}
