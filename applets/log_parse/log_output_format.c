#include "log_output_format.h"

#include "libpipeline.h"

#include <stdio.h>
#include <string.h>

#define TRY_DBUF(expr, fail_label) do { \
    if ((expr) != 0) { \
        goto fail_label; \
    } \
} while (0)

int log_output_write_json(FILE *stream, const log_t *log) {
    dynamic_buffer_t buf = {0};
    TRY_DBUF(dynamic_buffer_append_char(&buf, '{'), buffer_fail);
    for (size_t i = 0; i < log->count; ++i) {
        if (i > 0) {
            TRY_DBUF(dynamic_buffer_append_char(&buf, ','), buffer_fail);
        }
        TRY_DBUF(jsonl_write_string(&buf, log->names[i]), buffer_fail);
        TRY_DBUF(dynamic_buffer_append_char(&buf, ':'), buffer_fail);
        TRY_DBUF(jsonl_write_string(&buf, log->values[i]), buffer_fail);
    }
    TRY_DBUF(dynamic_buffer_append_str(&buf, "}\n"), buffer_fail);
    if (fputs(buf.data, stream) == EOF) {
        dynamic_buffer_free(&buf);
        return -1;
    }
    dynamic_buffer_free(&buf);
    return 0;

buffer_fail:
    dynamic_buffer_free(&buf);
    return -1;
}

int log_output_emit_json(const log_t *log) {
    return log_output_write_json(stdout, log);
}

static int append_csv_field(dynamic_buffer_t *buf, const char *s) {
    int quote = strchr(s, ',') != NULL ||
                strchr(s, '"') != NULL ||
                strchr(s, '\n') != NULL ||
                strchr(s, '\r') != NULL;
    if (!quote) {
        return dynamic_buffer_append_str(buf, s);
    }
    TRY_DBUF(dynamic_buffer_append_char(buf, '"'), fail);
    for (const char *p = s; *p != '\0'; ++p) {
        if (*p == '"') {
            TRY_DBUF(dynamic_buffer_append_char(buf, '"'), fail);
        }
        TRY_DBUF(dynamic_buffer_append_char(buf, *p), fail);
    }
    TRY_DBUF(dynamic_buffer_append_char(buf, '"'), fail);
    return 0;

fail:
    return -1;
}

int log_output_emit_csv(const log_t *log) {
    dynamic_buffer_t buf = {0};
    for (size_t i = 0; i < log->count; ++i) {
        if (i > 0) {
            TRY_DBUF(dynamic_buffer_append_char(&buf, ','), buffer_fail);
        }
        TRY_DBUF(append_csv_field(&buf, log->values[i]), buffer_fail);
    }
    TRY_DBUF(dynamic_buffer_append_char(&buf, '\n'), buffer_fail);
    fputs(buf.data, stdout);
    dynamic_buffer_free(&buf);
    return 0;

buffer_fail:
    dynamic_buffer_free(&buf);
    return -1;
}
