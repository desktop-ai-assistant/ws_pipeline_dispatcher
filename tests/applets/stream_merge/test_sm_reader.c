#include "sm_reader.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); \
        ++failures; \
    } \
} while (0)

static void test_parse_valid_line(void)
{
    const char *line = "{\"kind\":\"data\",\"sequence\":12,\"offset\":1024,\"length\":256,\"ts_ms\":1700,\"continuous\":true,\"byte_rate\":1000,\"frame_align\":4,\"events\":[\"motion\",\"person\"]}";
    sm_meta_record_t rec;
    
    CHECK(sm_reader_parse_line(line, &rec) == 0);
    CHECK(strcmp(rec.kind, "data") == 0);
    CHECK(rec.seq == 12);
    CHECK(rec.offset == 1024);
    CHECK(rec.length == 256);
    CHECK(rec.ts_ms == 1700);
    CHECK(rec.continuous == 1);
    CHECK(rec.byte_rate == 1000);
    CHECK(rec.frame_align == 4);
    CHECK(rec.events.count == 2);
    CHECK(strcmp(rec.events.items[0], "motion") == 0);
    CHECK(strcmp(rec.events.items[1], "person") == 0);
    CHECK(rec.valid == 1);
}

static void test_parse_invalid_line(void)
{
    /* Missing offset */
    const char *line1 = "{\"kind\":\"data\",\"sequence\":12,\"length\":256,\"ts_ms\":1700}";
    sm_meta_record_t rec1;
    CHECK(sm_reader_parse_line(line1, &rec1) == -1);
    
    /* Missing sequence */
    const char *line2 = "{\"kind\":\"data\",\"offset\":1024,\"length\":256,\"ts_ms\":1700}";
    sm_meta_record_t rec2;
    CHECK(sm_reader_parse_line(line2, &rec2) == -1);

    /* Continuous streams must declare a byte rate. */
    const char *line3 = "{\"kind\":\"data\",\"sequence\":12,\"offset\":1024,\"length\":256,\"ts_ms\":1700,\"continuous\":true}";
    sm_meta_record_t rec3;
    CHECK(sm_reader_parse_line(line3, &rec3) == -1);
}

int main(void)
{
    test_parse_valid_line();
    test_parse_invalid_line();

    if (failures == 0) {
        printf("OK: sm_reader tests passed\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d sm_reader check(s)\n", failures);
    return 1;
}
