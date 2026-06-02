#include "sm_fsm.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); \
        ++failures; \
    } \
} while (0)

static void test_fsm_reset(void)
{
    sm_fsm_t fsm;
    fsm.active = 1;
    fsm.start_ts_ms = 1000;
    
    sm_fsm_reset(&fsm);
    CHECK(fsm.active == 0);
    CHECK(fsm.start_ts_ms == 0);
    CHECK(fsm.expected_seq == 0);
}

static void test_fsm_process_record(void)
{
    sm_fsm_t fsm;
    sm_fsm_reset(&fsm);
    
    sm_meta_record_t rec1 = {
        .seq = 1,
        .offset = 0,
        .length = 100,
        .ts_ms = 5000,
        .valid = 1
    };
    strcpy(rec1.kind, "data");
    
    sm_clip_record_t out;
    
    /* First record activates FSM but does not emit */
    sm_fsm_action_t act1 = sm_fsm_process_record(&fsm, &rec1, 5000, 100, &out);
    CHECK(act1 == SM_FSM_NONE);
    CHECK(fsm.active == 1);
    CHECK(fsm.expected_seq == 2);
    
    /* Next record within window */
    sm_meta_record_t rec2 = {
        .seq = 2,
        .offset = 100,
        .length = 200,
        .ts_ms = 6000,
        .valid = 1
    };
    strcpy(rec2.kind, "data");
    
    sm_fsm_action_t act2 = sm_fsm_process_record(&fsm, &rec2, 5000, 200, &out);
    CHECK(act2 == SM_FSM_NONE);
    CHECK(fsm.expected_seq == 3);
    CHECK(fsm.total_length == 300);
    
    /* Third record exceeds clip_ms window (5000ms), triggers flush */
    sm_meta_record_t rec3 = {
        .seq = 3,
        .offset = 300,
        .length = 50,
        .ts_ms = 11000,
        .valid = 1
    };
    strcpy(rec3.kind, "data");
    
    sm_fsm_action_t act3 = sm_fsm_process_record(&fsm, &rec3, 5000, 300, &out);
    CHECK(act3 == SM_FSM_EMIT_COMPLETE);
    CHECK(out.active == 1);
    CHECK(out.start_ts_ms == 5000);
    CHECK(out.end_ts_ms == 6000);
    CHECK(out.total_length == 300);
    
    /* Verify FSM was restarted with rec3 */
    CHECK(fsm.active == 1);
    CHECK(fsm.start_ts_ms == 11000);
    CHECK(fsm.expected_seq == 4);
    CHECK(fsm.total_length == 50);
}

static void test_fsm_check_idle_and_flush(void)
{
    sm_fsm_t fsm;
    sm_fsm_reset(&fsm);
    
    sm_meta_record_t rec = {
        .seq = 1,
        .offset = 0,
        .length = 100,
        .ts_ms = 1000,
        .valid = 1
    };
    strcpy(rec.kind, "data");
    
    sm_clip_record_t out;
    sm_fsm_process_record(&fsm, &rec, 5000, 100, &out); /* wall time 100 */
    
    /* Before idle timeout */
    CHECK(sm_fsm_check_idle(&fsm, 2000, 1500, &out) == SM_FSM_NONE);
    
    /* After idle timeout */
    CHECK(sm_fsm_check_idle(&fsm, 2000, 3000, &out) == SM_FSM_EMIT_PARTIAL);
    CHECK(out.active == 1);
    CHECK(fsm.active == 0); /* should be reset after emit */
    
    /* Flush final when empty */
    CHECK(sm_fsm_flush_final(&fsm, &out) == SM_FSM_NONE);
    
    /* Flush final when active */
    sm_fsm_process_record(&fsm, &rec, 5000, 3100, &out);
    CHECK(fsm.active == 1);
    CHECK(sm_fsm_flush_final(&fsm, &out) == SM_FSM_EMIT_COMPLETE);
    CHECK(out.active == 1);
    CHECK(fsm.active == 0);
}

static void test_fsm_continuous_byte_range(void)
{
    sm_fsm_t fsm;
    sm_fsm_reset(&fsm);

    sm_meta_record_t rec1 = {
        .seq = 1,
        .offset = 0,
        .length = 3000,
        .ts_ms = 0,
        .continuous = 1,
        .byte_rate = 1000,
        .frame_align = 1,
        .valid = 1
    };
    strcpy(rec1.kind, "data");

    sm_meta_record_t rec2 = {
        .seq = 2,
        .offset = 3000,
        .length = 3000,
        .ts_ms = 3000,
        .continuous = 1,
        .byte_rate = 1000,
        .frame_align = 1,
        .valid = 1
    };
    strcpy(rec2.kind, "data");

    sm_clip_record_t out;
    CHECK(sm_fsm_process_record(&fsm, &rec1, 5000, 100, &out) == SM_FSM_NONE);
    CHECK(sm_fsm_process_record(&fsm, &rec2, 5000, 200, &out) == SM_FSM_EMIT_COMPLETE);
    CHECK(out.start_offset == 0);
    CHECK(out.total_length == 5000);
    CHECK(out.start_ts_ms == 0);
    CHECK(out.end_ts_ms == 5000);
    CHECK(out.boundary_mode == SM_BOUNDARY_CONTINUOUS_BYTE_RANGE);

    CHECK(fsm.active == 1);
    CHECK(fsm.start_offset == 5000);
    CHECK(fsm.total_length == 1000);
    CHECK(fsm.expected_seq == 3);
    CHECK(fsm.expected_offset == 6000);

    CHECK(sm_fsm_flush_final(&fsm, &out) == SM_FSM_EMIT_COMPLETE);
    CHECK(out.start_offset == 5000);
    CHECK(out.total_length == 1000);
    CHECK(out.boundary_mode == SM_BOUNDARY_METADATA);
}

int main(void)
{
    test_fsm_reset();
    test_fsm_process_record();
    test_fsm_check_idle_and_flush();
    test_fsm_continuous_byte_range();

    if (failures == 0) {
        printf("OK: sm_fsm tests passed\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d sm_fsm check(s)\n", failures);
    return 1;
}
