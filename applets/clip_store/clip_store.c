#include "clip_store.h"

#include "db_compact.h"
#include "db_format.h"
#include "db_query.h"
#include "libpipeline.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

typedef enum {
    MODE_APPEND = 0,
    MODE_SET,
    MODE_GET,
    MODE_DELETE,
    MODE_LIST,
    MODE_PREFIX,
    MODE_COMPACT
} clip_mode_t;

/**
 * Print command-line usage for the clip_store applet.
 *
 * All diagnostics go to stderr through the caller, while --help sends this text
 * to stdout so it can be piped or inspected without being treated as an error.
 */
static void print_usage(FILE *stream, const char *prog_name) {
    fprintf(stream, "Usage: %s --db <path> [OPTIONS]\n\n", prog_name);
    fprintf(stream, "Description:\n");
    fprintf(stream, "  Plain-text clip index persistence applet for UNIX pipelines.\n");
    fprintf(stream, "  Default mode reads clip JSONL from stdin and appends records.\n\n");
    fprintf(stream, "Options:\n");
    fprintf(stream, "  -d, --db <path>          Path to the database file (required)\n");
    fprintf(stream, "  -t, --ttl <seconds>      TTL for appended records (default: 3600)\n");
    fprintf(stream, "      --set <k=v>          Insert/update one key-value record\n");
    fprintf(stream, "      --get <key>          Get latest live value for key\n");
    fprintf(stream, "      --list               List all live key-value rows\n");
    fprintf(stream, "      --prefix <prefix>    List live rows whose key starts with prefix\n");
    fprintf(stream, "      --delete <key>       Tombstone delete for key\n");
    fprintf(stream, "      --compact            Rewrite DB to keep live latest rows only\n");
    fprintf(stream, "      --gc                 Alias of --compact\n");
    fprintf(stream, "  -h, --help               Show this help message and exit\n");
}

/**
 * Split a --set argument into key and value parts.
 *
 * The CLI accepts --set key=value. This helper modifies arg in place by
 * replacing the first '=' with '\0', then returns pointers into the same argv
 * buffer. The caller must not free key or value separately.
 */
static int parse_set_expr(char *arg, char **key, char **value) {
    if (arg == NULL || key == NULL || value == NULL) {
        return -1;
    }
    char *eq = strchr(arg, '=');
    if (eq == NULL || eq == arg) {
        return -1;
    }
    /* Split string at the equal sign */
    *eq = '\0';
    *key = arg;
    *value = eq + 1;
    return 0;
}

/**
 * Print latest live rows, optionally filtered by key prefix.
 *
 * The database is append-only, so this first rebuilds the latest-state hash
 * index from the file. It then prints only rows that are not expired and not
 * tombstones. Prefix mode reuses the same path and filters keys before output.
 */
static int print_rows(FILE *fp, const char *prefix, long now) {
    row_index_t rows = {0};
    if (load_latest_rows(fp, &rows) != 0) {
        row_index_free(&rows);
        return -1;
    }

    for (size_t i = 0; i < rows.cap; ++i) {
        if (!rows.used[i]) {
            continue;
        }
        /* Filter out expired rows or tombstones */
        if (!row_is_live(&rows.rows[i], now)) {
            continue;
        }
        /* Filter by prefix if requested */
        if (prefix != NULL && strncmp(rows.rows[i].key, prefix, strlen(prefix)) != 0) {
            continue;
        }
        printf("%s\t%s\n", rows.rows[i].key, rows.rows[i].value);
    }

    row_index_free(&rows);
    return 0;
}

int clip_store_main(int argc, char *argv[]) {
    stream_logger_set_tag("clip_store");

    const char *db = NULL;
    const char *ttl_arg = "3600";
    clip_mode_t mode = MODE_APPEND;
    char *set_arg = NULL;
    char *get_key = NULL;
    char *delete_key = NULL;
    char *prefix = NULL;

    int opt;
    static struct option long_options[] = {
        {"db", required_argument, 0, 'd'},
        {"ttl", required_argument, 0, 't'},
        {"set", required_argument, 0, 1000},
        {"get", required_argument, 0, 1001},
        {"list", no_argument, 0, 1002},
        {"prefix", required_argument, 0, 1003},
        {"delete", required_argument, 0, 1004},
        {"compact", no_argument, 0, 1005},
        {"gc", no_argument, 0, 1006},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    while ((opt = getopt_long(argc, argv, "d:t:h", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd':
                db = optarg;
                break;
            case 't':
                ttl_arg = optarg;
                break;
            case 1000:
                mode = MODE_SET;
                set_arg = optarg;
                break;
            case 1001:
                mode = MODE_GET;
                get_key = optarg;
                break;
            case 1002:
                mode = MODE_LIST;
                break;
            case 1003:
                mode = MODE_PREFIX;
                prefix = optarg;
                break;
            case 1004:
                mode = MODE_DELETE;
                delete_key = optarg;
                break;
            case 1005:
            case 1006:
                mode = MODE_COMPACT;
                break;
            case 'h':
                print_usage(stdout, argv[0]);
                return 0;
            case '?':
                print_usage(stderr, argv[0]);
                return 1;
            default:
                return 1;
        }
    }

    if (db == NULL && optind < argc) {
        db = argv[optind];
    }
    if (db == NULL) {
        LOG_ERROR("--db <path> is required");
        return 1;
    }

    char *end = NULL;
    long ttl = strtol(ttl_arg, &end, 10);
    if (end == ttl_arg || *end != '\0' || ttl < 0) {
        LOG_ERROR("invalid ttl=%s", ttl_arg);
        return 1;
    }

    int fd = open(db, O_RDWR | O_CREAT, 0600);
    if (fd < 0) {
        LOG_ERROR("open db failed: %s", strerror(errno));
        return 1;
    }
    /* Lock the file to prevent concurrent access issues */
    if (flock(fd, LOCK_EX) != 0) {
        LOG_ERROR("lock db failed: %s", strerror(errno));
        close(fd);
        return 1;
    }

    FILE *fp = fdopen(fd, "r+");
    if (fp == NULL) {
        LOG_ERROR("fdopen db failed: %s", strerror(errno));
        close(fd);
        return 1;
    }

    int rc = 0;
    long now = (long)time(NULL);
    if (mode == MODE_GET) {
        row_t row = {0};
        int found = load_latest_row(fp, get_key, &row);
        if (found < 0) {
            rc = 1;
        } else if (found > 0 && row_is_live(&row, now)) {
            puts(row.value);
        }
        free(row.key);
        free(row.value);
    } else if (mode == MODE_SET) {
        char *key = NULL;
        char *value = NULL;
        if (parse_set_expr(set_arg, &key, &value) != 0 || key[0] == '\0' || value[0] == '\0') {
            LOG_ERROR("invalid --set syntax; expected non-empty key and value");
            rc = 1;
        } else {
            long expire_at = ttl == 0 ? 0 : now + ttl;
            rc = append_db_row(fp, key, value, expire_at) == 0 ? 0 : 1;
        }
    } else if (mode == MODE_DELETE) {
        if (delete_key == NULL || delete_key[0] == '\0') {
            LOG_ERROR("--delete requires non-empty key");
            rc = 1;
        } else {
            /* Deletion writes a tombstone with an empty value */
            rc = append_db_row(fp, delete_key, "", 0) == 0 ? 0 : 1;
        }
    } else if (mode == MODE_LIST) {
        rc = print_rows(fp, NULL, now) == 0 ? 0 : 1;
    } else if (mode == MODE_PREFIX) {
        rc = print_rows(fp, prefix, now) == 0 ? 0 : 1;
    } else if (mode == MODE_COMPACT) {
        rc = db_rewrite_compact(fp, db, now) == 0 ? 0 : 1;
    } else {
        /* Default mode: Read pipeline JSON lines from stdin */
        char *line = NULL;
        size_t cap = 0;
        while (getline(&line, &cap, stdin) > 0) {
            char session[128] = {0};
            int64_t ts = 0;
            size_t line_len = strlen(line);
            while (line_len > 0 && (line[line_len - 1] == '\n' || line[line_len - 1] == '\r')) {
                line[--line_len] = '\0';
            }

            /* Extract required fields from JSON record */
            if (jsonl_get_string(line, "session_id", session, sizeof(session)) != 0 ||
                jsonl_get_int64(line, "ts", &ts) != 0) {
                LOG_WARN("malformed clip JSON; skipping");
                continue;
            }

            dynamic_buffer_t key = {0};
            char ts_buf[32];
            snprintf(ts_buf, sizeof(ts_buf), "%lld", (long long)ts);
            long row_now = (long)time(NULL);
            long expire_at = ttl == 0 ? 0 : row_now + ttl;
            
            /* Construct database key as "session_id:ts" */
            if (dynamic_buffer_append_str(&key, session) != 0 ||
                dynamic_buffer_append_char(&key, ':') != 0 ||
                dynamic_buffer_append_str(&key, ts_buf) != 0 ||
                append_db_row(fp, key.data, line, expire_at) != 0) {
                LOG_ERROR("write db failed: %s", strerror(errno));
                dynamic_buffer_free(&key);
                rc = 1;
                break;
            }
            dynamic_buffer_free(&key);
        }
        free(line);
    }

    fclose(fp);
    return rc;
}
