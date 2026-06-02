#include "sm_fsm.h"

#include <string.h>

static uint64_t aligned_target_bytes(int64_t clip_ms, uint64_t byte_rate, uint64_t frame_align) {
    if (clip_ms <= 0 || byte_rate == 0) {
        return 0;
    }

    uint64_t target = (uint64_t)(((long double)clip_ms * (long double)byte_rate) / 1000.0L);
    if (frame_align > 1) {
        target -= target % frame_align;
    }
    return target;
}

/** Copy the active FSM state into an immutable output clip snapshot. */
static void snapshot_clip(const sm_fsm_t *fsm, sm_clip_record_t *out) {
    memset(out, 0, sizeof(*out));
    out->active = fsm->active;
    out->start_ts_ms = fsm->start_ts_ms;
    out->end_ts_ms = fsm->end_ts_ms;
    out->start_offset = fsm->start_offset;
    out->total_length = fsm->total_length;
    out->boundary_mode = fsm->boundary_mode;
    out->events = fsm->events;
}

static void snapshot_continuous_clip(const sm_fsm_t *fsm, int64_t clip_ms, uint64_t target_bytes, sm_clip_record_t *out) {
    snapshot_clip(fsm, out);
    out->end_ts_ms = fsm->start_ts_ms + clip_ms;
    out->total_length = target_bytes;
    out->boundary_mode = SM_BOUNDARY_CONTINUOUS_BYTE_RANGE;
}

/** Start a new collection window using the triggering metadata record. */
static void start_clip(sm_fsm_t *fsm, const sm_meta_record_t *rec, int64_t now_ms) {
    fsm->active = 1;
    fsm->start_ts_ms = rec->ts_ms;
    fsm->end_ts_ms = rec->ts_ms;
    fsm->start_offset = rec->offset;
    fsm->total_length = rec->length;
    fsm->expected_seq = rec->seq + 1;
    fsm->expected_offset = rec->offset + rec->length;
    fsm->last_chunk_wall_ms = now_ms;
    fsm->continuous = rec->continuous;
    fsm->byte_rate = rec->byte_rate;
    fsm->frame_align = rec->frame_align == 0 ? 1 : rec->frame_align;
    fsm->boundary_mode = SM_BOUNDARY_METADATA;
    fsm->events = rec->events;
}

/** Accumulate a contiguous record into the active collection window. */
static void append_record(sm_fsm_t *fsm, const sm_meta_record_t *rec, int64_t now_ms) {
    fsm->end_ts_ms = rec->ts_ms;
    fsm->total_length += rec->length;
    fsm->expected_seq = rec->seq + 1;
    fsm->expected_offset = rec->offset + rec->length;
    fsm->last_chunk_wall_ms = now_ms;
    fsm->boundary_mode = SM_BOUNDARY_METADATA;
    (void)sm_event_set_add_all(&fsm->events, &rec->events);
}

static int continuous_compatible(const sm_fsm_t *fsm, const sm_meta_record_t *rec) {
    uint64_t rec_align = rec->frame_align == 0 ? 1 : rec->frame_align;
    return fsm->continuous && rec->continuous &&
           fsm->byte_rate == rec->byte_rate &&
           fsm->frame_align == rec_align;
}

static sm_fsm_action_t maybe_emit_continuous_window(sm_fsm_t *fsm, int64_t clip_ms, sm_clip_record_t *out) {
    uint64_t target_bytes = aligned_target_bytes(clip_ms, fsm->byte_rate, fsm->frame_align);
    if (!fsm->continuous || target_bytes == 0 || fsm->total_length < target_bytes) {
        return SM_FSM_NONE;
    }

    snapshot_continuous_clip(fsm, clip_ms, target_bytes, out);
    fsm->start_offset += target_bytes;
    fsm->total_length -= target_bytes;
    fsm->start_ts_ms += clip_ms;
    fsm->end_ts_ms = fsm->start_ts_ms;
    fsm->boundary_mode = SM_BOUNDARY_METADATA;
    sm_event_set_reset(&fsm->events);
    return SM_FSM_EMIT_COMPLETE;
}

void sm_fsm_reset(sm_fsm_t *fsm) {
    if (fsm != NULL) {
        memset(fsm, 0, sizeof(*fsm));
    }
}

sm_fsm_action_t sm_fsm_process_record(sm_fsm_t *fsm, const sm_meta_record_t *rec, int64_t clip_ms, int64_t now_ms, sm_clip_record_t *out) {
    if (fsm == NULL || rec == NULL || out == NULL || !rec->valid) {
        return SM_FSM_NONE;
    }

    if (!fsm->active) {
        start_clip(fsm, rec, now_ms);
        return maybe_emit_continuous_window(fsm, clip_ms, out);
    }

    if (rec->seq < fsm->expected_seq) {
        return SM_FSM_REJECT_LATE;
    }

    if (fsm->total_length == 0 && (rec->seq > fsm->expected_seq || rec->offset != fsm->expected_offset)) {
        start_clip(fsm, rec, now_ms);
        return maybe_emit_continuous_window(fsm, clip_ms, out);
    }

    if (rec->seq > fsm->expected_seq || rec->offset != fsm->expected_offset) {
        /* A forward jump means bytes are missing; close the current clip as partial. */
        snapshot_clip(fsm, out);
        start_clip(fsm, rec, now_ms);
        return SM_FSM_EMIT_PARTIAL;
    }

    if (continuous_compatible(fsm, rec)) {
        append_record(fsm, rec, now_ms);
        return maybe_emit_continuous_window(fsm, clip_ms, out);
    }

    if (rec->ts_ms - fsm->start_ts_ms >= clip_ms) {
        /* The boundary chunk becomes the first chunk of the next window. */
        snapshot_clip(fsm, out);
        start_clip(fsm, rec, now_ms);
        return SM_FSM_EMIT_COMPLETE;
    }

    append_record(fsm, rec, now_ms);
    return SM_FSM_NONE;
}

sm_fsm_action_t sm_fsm_check_idle(sm_fsm_t *fsm, int64_t idle_ms, int64_t now_ms, sm_clip_record_t *out) {
    if (fsm == NULL || out == NULL || !fsm->active || fsm->total_length == 0) {
        return SM_FSM_NONE;
    }

    if (now_ms - fsm->last_chunk_wall_ms < idle_ms) {
        return SM_FSM_NONE;
    }

    snapshot_clip(fsm, out);
    sm_fsm_reset(fsm);
    return SM_FSM_EMIT_PARTIAL;
}

sm_fsm_action_t sm_fsm_flush_final(sm_fsm_t *fsm, sm_clip_record_t *out) {
    if (fsm == NULL || out == NULL || !fsm->active || fsm->total_length == 0) {
        return SM_FSM_NONE;
    }

    snapshot_clip(fsm, out);
    sm_fsm_reset(fsm);
    return SM_FSM_EMIT_COMPLETE;
}
