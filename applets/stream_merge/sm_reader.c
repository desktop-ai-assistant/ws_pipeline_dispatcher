#include "sm_reader.h"

#include "cJSON.h"
#include "libpipeline.h"

#include <ctype.h>
#include <string.h>

static cJSON *parse_object(const char *line) {
    const char *parse_end = NULL;
    cJSON *root = cJSON_ParseWithOpts(line, &parse_end, 0);
    if (root == NULL || !cJSON_IsObject(root)) {
        cJSON_Delete(root);
        return NULL;
    }
    while (parse_end != NULL && *parse_end != '\0' && isspace((unsigned char)*parse_end)) {
        ++parse_end;
    }
    if (parse_end == NULL || *parse_end != '\0') {
        cJSON_Delete(root);
        return NULL;
    }
    return root;
}

static int parse_events(const char *line, sm_event_set_t *events) {
    cJSON *root = parse_object(line);
    if (root == NULL) {
        return -1;
    }

    cJSON *items = cJSON_GetObjectItemCaseSensitive(root, "events");
    if (items == NULL) {
        cJSON_Delete(root);
        return 0;
    }
    if (!cJSON_IsArray(items)) {
        cJSON_Delete(root);
        return -1;
    }

    cJSON *item = NULL;
    cJSON_ArrayForEach(item, items) {
        if (!cJSON_IsString(item) || item->valuestring == NULL ||
            sm_event_set_add_tag(events, item->valuestring) != 0) {
            cJSON_Delete(root);
            return -1;
        }
    }

    cJSON_Delete(root);
    return 0;
}

int sm_reader_parse_line(const char *line, sm_meta_record_t *out) {
    if (line == NULL || out == NULL) {
        return -1;
    }

    memset(out, 0, sizeof(*out));
    if (jsonl_get_string(line, "kind", out->kind, sizeof(out->kind)) != 0 ||
        jsonl_get_uint64(line, "sequence", &out->seq) != 0 ||
        jsonl_get_uint64(line, "offset", &out->offset) != 0 ||
        jsonl_get_uint64(line, "length", &out->length) != 0 ||
        jsonl_get_int64(line, "ts_ms", &out->ts_ms) != 0) {
        return -1;
    }

    if (jsonl_get_bool(line, "continuous", &out->continuous) == 0 && out->continuous) {
        if (jsonl_get_uint64(line, "byte_rate", &out->byte_rate) != 0 || out->byte_rate == 0) {
            return -1;
        }
        if (jsonl_get_uint64(line, "frame_align", &out->frame_align) != 0) {
            out->frame_align = 1;
        }
    }

    if (parse_events(line, &out->events) != 0) {
        return -1;
    }

    out->valid = 1;
    return 0;
}
