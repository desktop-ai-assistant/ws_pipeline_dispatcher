#ifndef SM_FSM_H
#define SM_FSM_H

#include "sm_events.h"

#include <stdint.h>

/**
 * @brief One normalized metadata row representing a single chunk.
 */
typedef struct {
    char kind[16];              /* Record kind; only "data" is processed. */
    uint64_t seq;               /* Canonical monotonic sequence number. */
    uint64_t offset;            /* Byte offset in the session .bin file. */
    uint64_t length;            /* Payload length in bytes. */
    int64_t ts_ms;              /* Source timestamp in milliseconds. */
    int continuous;             /* 1 when byte offsets map linearly to time. */
    uint64_t byte_rate;         /* Bytes per second for continuous streams. */
    uint64_t frame_align;       /* Optional byte alignment for exact cuts. */
    sm_event_set_t events;      /* Optional events attached to this chunk. */
    int valid;                  /* 1 when parsing and validation succeeded. */
} sm_meta_record_t;

typedef enum {
    SM_BOUNDARY_METADATA = 0,
    SM_BOUNDARY_CONTINUOUS_BYTE_RANGE
} sm_boundary_mode_t;

/**
 * @brief One clip byte-range snapshot produced by the FSM.
 */
typedef struct {
    int active;
    int64_t start_ts_ms;
    int64_t end_ts_ms;
    uint64_t start_offset;
    uint64_t total_length;
    sm_boundary_mode_t boundary_mode;
    sm_event_set_t events;
} sm_clip_record_t;

/**
 * @brief In-memory working state for gap-aware clip aggregation.
 */
typedef struct {
    int active;
    int64_t start_ts_ms;
    int64_t end_ts_ms;
    uint64_t start_offset;
    uint64_t total_length;
    uint64_t expected_seq;
    uint64_t expected_offset;
    int64_t last_chunk_wall_ms;
    int continuous;
    uint64_t byte_rate;
    uint64_t frame_align;
    sm_boundary_mode_t boundary_mode;
    sm_event_set_t events;
} sm_fsm_t;

/**
 * @brief Outcome returned after a metadata record or timeout is processed.
 */
typedef enum {
    SM_FSM_NONE = 0,
    SM_FSM_REJECT_LATE,
    SM_FSM_EMIT_COMPLETE,
    SM_FSM_EMIT_PARTIAL
} sm_fsm_action_t;

/**
 * @brief Reset the FSM to the idle state.
 *
 * @param fsm State machine to reset.
 */
void sm_fsm_reset(sm_fsm_t *fsm);

/**
 * @brief Process one validated metadata record.
 *
 * Applies the core gap state machine: late records are rejected, sequence gaps
 * flush the current clip as partial, and time-window boundaries flush complete
 * clips. When a flush occurs, out receives the clip that must be emitted.
 *
 * @param fsm State machine to update.
 * @param rec Valid data metadata record.
 * @param clip_ms Target clip window in milliseconds.
 * @param now_ms Current monotonic time in milliseconds.
 * @param out Output clip snapshot when the return value is an emit action.
 * @return FSM action describing what the caller should do next.
 */
sm_fsm_action_t sm_fsm_process_record(sm_fsm_t *fsm, const sm_meta_record_t *rec, int64_t clip_ms, int64_t now_ms, sm_clip_record_t *out);

/**
 * @brief Flush the current clip when no chunks arrive before idle timeout.
 *
 * @param fsm State machine to inspect and update.
 * @param idle_ms Idle timeout in milliseconds.
 * @param now_ms Current monotonic time in milliseconds.
 * @param out Output clip snapshot when a partial clip is emitted.
 * @return SM_FSM_EMIT_PARTIAL on timeout, otherwise SM_FSM_NONE.
 */
sm_fsm_action_t sm_fsm_check_idle(sm_fsm_t *fsm, int64_t idle_ms, int64_t now_ms, sm_clip_record_t *out);

/**
 * @brief Flush any active clip at end of stream.
 *
 * @param fsm State machine to flush.
 * @param out Output clip snapshot when active data exists.
 * @return SM_FSM_EMIT_COMPLETE when a final clip is emitted, otherwise SM_FSM_NONE.
 */
sm_fsm_action_t sm_fsm_flush_final(sm_fsm_t *fsm, sm_clip_record_t *out);

#endif
