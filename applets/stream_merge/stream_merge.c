/*
 * stream_merge.c -- sidecar-driven session clip cutter.
 *
 * This applet is deliberately file-based. An upstream ingestor writes a growing
 * session .bin file and a .meta.jsonl sidecar; stream_merge watches those files,
 * runs the gap-aware FSM, and emits clip byte-range JSON Lines to stdout.
 */

#include "libpipeline.h"
#include "sm_fsm.h"
#include "sm_reader.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_CLIP_MS 5000
#define DEFAULT_IDLE_MS 2000

/** Emit one normalized clip JSON record to stdout. */
static int emit_clip(const sm_clip_record_t *clip, const char *src, const char *session, int complete) {
    if (clip == NULL || !clip->active) {
        return 0;
    }

    long ts_sec = (long)(clip->start_ts_ms / 1000);
    char filename[PATH_MAX];
    char path[PATH_MAX];
    int n = snprintf(filename, sizeof(filename), "%s.bin", session);
    if (n < 0 || (size_t)n >= sizeof(filename) ||
        lp_build_artifact_path(path, sizeof(path), src, filename) != 0) {
        LOG_ERROR("path too long for session %s", session);
        return -1;
    }

    int rc = printf(
        "{\"type\":\"clip\","
        "\"session_id\":\"%s\","
        "\"ts\":%ld,"
        "\"path\":\"%s\","
        "\"offset\":%" PRIu64 ","
        "\"length\":%" PRIu64 ","
        "\"start_ts_ms\":%" PRId64 ","
        "\"end_ts_ms\":%" PRId64 ","
        "\"duration_ms\":%" PRId64 ","
        "\"boundary_mode\":\"%s\","
        "\"complete\":%s",
        session, ts_sec, path,
        clip->start_offset, clip->total_length,
        clip->start_ts_ms, clip->end_ts_ms,
        clip->end_ts_ms - clip->start_ts_ms,
        clip->boundary_mode == SM_BOUNDARY_CONTINUOUS_BYTE_RANGE ? "continuous_byte_range" : "metadata_boundary",
        complete ? "true" : "false");
    if (rc < 0) {
        return -1;
    }

    if (clip->events.count > 0) {
        dynamic_buffer_t events = {0};
        if (sm_event_set_append_json(&clip->events, &events) != 0) {
            dynamic_buffer_free(&events);
            return -1;
        }
        rc = printf(",\"events\":%s", events.data);
        dynamic_buffer_free(&events);
        if (rc < 0) {
            return -1;
        }
    }

    if (printf("}\n") < 0) {
        return -1;
    }
    return fflush(stdout) == EOF ? -1 : 0;
}

/** Convert an FSM action into the corresponding stdout emission. */
static int handle_action(sm_fsm_action_t action, const sm_clip_record_t *clip, const char *src, const char *session) {
    if (action == SM_FSM_EMIT_COMPLETE) {
        return emit_clip(clip, src, session, 1);
    }
    if (action == SM_FSM_EMIT_PARTIAL) {
        return emit_clip(clip, src, session, 0);
    }
    if (action == SM_FSM_REJECT_LATE) {
        LOG_WARN("rejecting late or duplicate chunk");
    }
    return 0;
}

/**
 * Drain newly appended metadata, split complete lines, and feed records to FSM.
 */
static int drain_meta(int meta_fd, dynamic_buffer_t *meta_buf, sm_fsm_t *fsm, const char *src, const char *session, int64_t clip_ms) {
    char chunk[4096];
    for (;;) {
        ssize_t got = read(meta_fd, chunk, sizeof(chunk));
        if (got < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            return -1;
        }
        if (got == 0) break;
        if (dynamic_buffer_append_mem(meta_buf, chunk, (size_t)got) != 0) {
            return -1;
        }
    }

    for (;;) {
        char *nl = memchr(meta_buf->data, '\n', meta_buf->len);
        if (nl == NULL) {
            break;
        }
        size_t line_len = (size_t)(nl - meta_buf->data);
        char saved = *nl;
        *nl = '\0';

        if (line_len > 0) {
            sm_meta_record_t rec;
            if (sm_reader_parse_line(meta_buf->data, &rec) == 0 &&
                rec.valid && strcmp(rec.kind, "data") == 0) {
                sm_clip_record_t clip = {0};
                sm_fsm_action_t action = sm_fsm_process_record(
                    fsm, &rec, clip_ms, pipeline_get_monotonic_time_ms(), &clip);
                if (handle_action(action, &clip, src, session) != 0) {
                    *nl = saved;
                    return -1;
                }
            } else {
                LOG_WARN("skipping meta line: %.80s", meta_buf->data);
            }
        }

        *nl = saved;
        size_t consumed = line_len + 1;
        size_t rest = meta_buf->len - consumed;
        memmove(meta_buf->data, meta_buf->data + consumed, rest);
        meta_buf->len = rest;
        meta_buf->data[rest] = '\0';
    }
    return 0;
}

/** Flush active state as a partial clip when no chunk arrives before timeout. */
static int check_idle(sm_fsm_t *fsm, int64_t idle_ms, const char *src, const char *session) {
    sm_clip_record_t clip = {0};
    int64_t now_ms = pipeline_get_monotonic_time_ms();
    sm_fsm_action_t action = sm_fsm_check_idle(fsm, idle_ms, now_ms, &clip);
    if (action == SM_FSM_EMIT_PARTIAL) {
        LOG_INFO("idle timeout after %" PRId64 "ms, emitting partial clip", idle_ms);
    }
    return handle_action(action, &clip, src, session);
}

/** Check whether the session completion sentinel already exists. */
static int sentinel_exists(const char *src) {
    char path[PATH_MAX];
    if (lp_build_artifact_path(path, sizeof(path), src, PIPELINE_SENTINEL_NAME) != 0) {
        return 0;
    }
    return access(path, F_OK) == 0;
}

/** Print CLI help text. */
static void print_usage(FILE *stream, const char *prog_name) {
    fprintf(stream, "Usage: %s [OPTIONS] <session_id> <src_dir>\n\n", prog_name);
    fprintf(stream, "Description:\n");
    fprintf(stream, "  Watches session sidecar metadata and emits clip JSON Lines.\n\n");
    fprintf(stream, "Options:\n");
    fprintf(stream, "      --clip-secs <n>    Target clip duration in seconds (default: 5.0)\n");
    fprintf(stream, "      --idle-secs <n>    Idle timeout before emitting partial clip (default: 2.0)\n");
    fprintf(stream, "  -h, --help             Show this help message and exit\n");
}

int stream_merge_main(int argc, char *argv[]) {
    stream_logger_set_tag("stream_merge");

    int64_t clip_ms = DEFAULT_CLIP_MS;
    int64_t idle_ms = DEFAULT_IDLE_MS;

    int opt;
    static struct option long_options[] = {
        {"clip-secs", required_argument, 0, 1000},
        {"idle-secs", required_argument, 0, 1001},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    while ((opt = getopt_long(argc, argv, "h", long_options, NULL)) != -1) {
        switch (opt) {
            case 1000:
                clip_ms = (int64_t)(atof(optarg) * 1000.0);
                break;
            case 1001:
                idle_ms = (int64_t)(atof(optarg) * 1000.0);
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

    if (optind + 2 > argc) {
        fprintf(stderr, "Error: Missing required arguments <session_id> and/or <src_dir>\n\n");
        print_usage(stderr, argv[0]);
        return 1;
    }

    const char *session = argv[optind];
    const char *src = argv[optind + 1];

    char bin_path[PATH_MAX], meta_path[PATH_MAX];
    char bin_name[PATH_MAX], meta_name[PATH_MAX];
    if (snprintf(bin_name, sizeof(bin_name), "%s.bin", session) < 0 ||
        snprintf(meta_name, sizeof(meta_name), "%s.meta.jsonl", session) < 0 ||
        lp_build_artifact_path(bin_path, sizeof(bin_path), src, bin_name) != 0 ||
        lp_build_artifact_path(meta_path, sizeof(meta_path), src, meta_name) != 0) {
        LOG_ERROR("path construction failed");
        return 1;
    }

    int bin_fd = open(bin_path, O_RDONLY);
    if (bin_fd < 0) {
        LOG_ERROR("open %s: %s", bin_path, strerror(errno));
        return 1;
    }

    int dir_wd = -1;
    int dir_fd = lp_watch_dir(src, &dir_wd);
    if (dir_fd < 0) {
        LOG_ERROR("inotify dir watch failed: %s", strerror(errno));
        close(bin_fd);
        return 1;
    }

    int saw_sentinel = sentinel_exists(src);
    int meta_fd = open(meta_path, O_RDONLY);
    if (meta_fd < 0 && errno == ENOENT) {
        LOG_INFO("meta file not yet present, waiting up to 5s");
        int64_t deadline = pipeline_get_monotonic_time_ms() + 5000;
        while (meta_fd < 0 && !saw_sentinel) {
            int64_t remaining = deadline - pipeline_get_monotonic_time_ms();
            if (remaining <= 0) {
                LOG_ERROR("timed out waiting for %s", meta_path);
                close(dir_fd);
                close(bin_fd);
                return 1;
            }
            struct pollfd wpfd = { .fd = dir_fd, .events = POLLIN };
            int prc = poll(&wpfd, 1, (int)remaining);
            if (prc < 0) {
                if (errno == EINTR) continue;
                LOG_ERROR("poll waiting for meta: %s", strerror(errno));
                close(dir_fd);
                close(bin_fd);
                return 1;
            }
            if (prc > 0) {
                if (lp_consume_inotify_events(dir_fd, &saw_sentinel) != 0) {
                    LOG_WARN("inotify read: %s", strerror(errno));
                }
            }
            if (!saw_sentinel) {
                meta_fd = open(meta_path, O_RDONLY);
            }
        }
        if (meta_fd >= 0) {
            LOG_INFO("meta file appeared");
        } else if (saw_sentinel) {
            LOG_INFO("session completed before meta file appeared");
        }
    } else if (meta_fd < 0) {
        LOG_ERROR("open %s: %s", meta_path, strerror(errno));
        close(dir_fd);
        close(bin_fd);
        return 1;
    }

    if (meta_fd < 0) {
        close(dir_fd);
        close(bin_fd);
        return 0;
    }

    int meta_wd = -1;
    int meta_wfd = lp_watch_file(meta_path, &meta_wd);
    if (meta_wfd < 0) {
        LOG_ERROR("inotify meta watch failed: %s", strerror(errno));
        close(dir_fd);
        close(meta_fd);
        close(bin_fd);
        return 1;
    }

    dynamic_buffer_t meta_buf = {0};
    sm_fsm_t fsm = {0};
    int rc = 0;

    if (drain_meta(meta_fd, &meta_buf, &fsm, src, session, clip_ms) != 0) {
        rc = 1;
    }

    while (rc == 0 && !saw_sentinel) {
        int64_t now = pipeline_get_monotonic_time_ms();
        int64_t timeout = 1000;
        if (fsm.active) {
            int64_t idle_left = idle_ms - (now - fsm.last_chunk_wall_ms);
            timeout = idle_left < timeout ? (idle_left > 0 ? idle_left : 0) : timeout;
        }

        struct pollfd pfds[2] = {
            { .fd = meta_wfd, .events = POLLIN },
            { .fd = dir_fd, .events = POLLIN }
        };
        int prc = poll(pfds, 2, (int)timeout);
        if (prc < 0) {
            if (errno == EINTR) continue;
            LOG_ERROR("poll: %s", strerror(errno));
            rc = 1;
            break;
        }

        if (pfds[0].revents & POLLIN) {
            int ignored = 0;
            if (lp_consume_inotify_events(meta_wfd, &ignored) != 0) {
                LOG_WARN("inotify read: %s", strerror(errno));
            }
            if (drain_meta(meta_fd, &meta_buf, &fsm, src, session, clip_ms) != 0) {
                rc = 1;
                break;
            }
        }
        if (pfds[1].revents & POLLIN) {
            if (lp_consume_inotify_events(dir_fd, &saw_sentinel) != 0) {
                LOG_WARN("inotify read: %s", strerror(errno));
            }
        }
        if (sentinel_exists(src)) {
            saw_sentinel = 1;
        }
        if (check_idle(&fsm, idle_ms, src, session) != 0) {
            rc = 1;
            break;
        }
    }

    if (rc == 0 && drain_meta(meta_fd, &meta_buf, &fsm, src, session, clip_ms) != 0) {
        rc = 1;
    }
    if (rc == 0) {
        sm_clip_record_t clip = {0};
        sm_fsm_action_t action = sm_fsm_flush_final(&fsm, &clip);
        if (handle_action(action, &clip, src, session) != 0) {
            rc = 1;
        }
    }

    dynamic_buffer_free(&meta_buf);
    close(meta_wfd);
    close(dir_fd);
    close(meta_fd);
    close(bin_fd);
    return rc;
}
