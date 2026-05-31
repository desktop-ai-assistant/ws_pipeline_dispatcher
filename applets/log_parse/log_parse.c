#include "libpipeline.h"
#include "log_filter_expr.h"
#include "log_output_format.h"
#include "log_regex.h"

#include <ctype.h>
#include <errno.h>
#include <getopt.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    regex_t regex;
    log_t log;
} regex_state_t;

typedef enum {
    AGG_NONE = 0,
    AGG_SUM,
    AGG_AVG,
    AGG_MIN,
    AGG_MAX
} agg_op_t;

static void print_usage(FILE *stream, const char *prog_name) {
    fprintf(stream, "Usage: %s [OPTIONS]\n\n", prog_name);
    fprintf(stream, "Description:\n");
    fprintf(stream, "  A lightweight structured log processor for UNIX pipelines.\n");
    fprintf(stream, "  Reads from stdin and writes to stdout. Diagnostic logs to stderr.\n\n");
    fprintf(stream, "Options:\n");
    fprintf(stream, "  -r, --regex <pattern>  Extract fields using POSIX extended regular expressions\n");
    fprintf(stream, "  -e, --fields <f1,f2>   Comma-separated field names for regex mode\n");
    fprintf(stream, "  -f, --filter <expr>    Filter expression: k=v, k!=v, k>v, or k~v\n");
    fprintf(stream, "      --build-full-log <path> Append every parsed structured record to JSONL log\n");
    fprintf(stream, "      --format <fmt>     Set output format (json|csv|count) (default: json)\n");
    fprintf(stream, "      --sum <field>      Compute sum of field\n");
    fprintf(stream, "      --avg <field>      Compute average of field\n");
    fprintf(stream, "      --min <field>      Find minimum of field\n");
    fprintf(stream, "      --max <field>      Find maximum of field\n");
    fprintf(stream, "  -E                     Ignored (always uses extended regex)\n");
    fprintf(stream, "  -h, --help             Show this help message and exit\n");
}

static void trim_line(char *line) {
    char *start = line;
    while (isspace((unsigned char)*start)) {
        ++start;
    }
    
    size_t len = strlen(start);
    while (len > 0 && isspace((unsigned char)start[len - 1])) {
        start[--len] = '\0';
    }

    if (start != line) {
        memmove(line, start, len + 1);
    }
}

static int parse_format(const char *arg, log_output_format_t *format) {
    if (arg == NULL) {
        return 0;
    }
    if (strcmp(arg, "json") == 0) {
        *format = LOG_OUTPUT_JSON;
    } else if (strcmp(arg, "csv") == 0) {
        *format = LOG_OUTPUT_CSV;
    } else if (strcmp(arg, "count") == 0) {
        *format = LOG_OUTPUT_COUNT;
    } else {
        return -1;
    }
    return 0;
}

int log_parse_main(int argc, char *argv[]) {
    stream_logger_set_tag("log_parse");

    char *regex_pattern = NULL;
    char *fields_arg = NULL;
    char *format_arg = NULL;
    char *filter_kv = NULL;
    char *full_log_path = NULL;
    FILE *full_log = NULL;
    filter_t filter = {0};
    log_output_format_t format = LOG_OUTPUT_JSON;
    agg_op_t agg_op = AGG_NONE;
    char *agg_field = NULL;
    double agg_sum = 0;
    double agg_min = 0;
    double agg_max = 0;
    size_t agg_count = 0;
    int has_agg = 0;
    int agg_field_idx = -1;
    
    regex_state_t regex_state = {0};
    int regex_mode = 0;
    int regex_ready = 0;
    int exit_code = 0;
    size_t matched_count = 0;

    int opt;
    static struct option long_options[] = {
        {"regex",  required_argument, 0, 'r'},
        {"fields", required_argument, 0, 'e'},
        {"filter", required_argument, 0, 'f'},
        {"format", required_argument, 0, 1000},
        {"sum",    required_argument, 0, 1001},
        {"avg",    required_argument, 0, 1002},
        {"min",    required_argument, 0, 1003},
        {"max",    required_argument, 0, 1004},
        {"build-full-log", required_argument, 0, 1005},
        {"help",   no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    while ((opt = getopt_long(argc, argv, "r:e:f:hE", long_options, NULL)) != -1) {
        switch (opt) {
            case 'r':
                regex_pattern = optarg;
                break;
            case 'e':
                fields_arg = optarg;
                break;
            case 'f':
                filter_kv = optarg;
                if (log_filter_parse(filter_kv, &filter) != 0) {
                    LOG_ERROR("invalid filter syntax; expected key=value, key!=value, key>value, or key~value");
                    return 1;
                }
                break;
            case 1000:
                format_arg = optarg;
                break;
            case 1001:
                agg_op = AGG_SUM;
                agg_field = optarg;
                has_agg = 1;
                break;
            case 1002:
                agg_op = AGG_AVG;
                agg_field = optarg;
                has_agg = 1;
                break;
            case 1003:
                agg_op = AGG_MIN;
                agg_field = optarg;
                has_agg = 1;
                break;
            case 1004:
                agg_op = AGG_MAX;
                agg_field = optarg;
                has_agg = 1;
                break;
            case 1005:
                full_log_path = optarg;
                break;
            case 'E':
                /* Compatibility with grep -E */
                break;
            case 'h':
                print_usage(stdout, argv[0]);
                exit(EXIT_SUCCESS);
            case '?':
                print_usage(stderr, argv[0]);
                exit(EXIT_FAILURE);
            default:
                exit(EXIT_FAILURE);
        }
    }

    if (parse_format(format_arg, &format) != 0) {
        LOG_ERROR("unsupported format=%s", format_arg);
        return 1;
    }

    if (full_log_path != NULL) {
        full_log = fopen(full_log_path, "a");
        if (full_log == NULL) {
            LOG_ERROR("open full log failed: %s", strerror(errno));
            return 1;
        }
    }

    if (regex_pattern != NULL) {
        regex_mode = 1;
        if (fields_arg == NULL) {
            LOG_ERROR("--fields is required with --regex");
            return 1;
        }
        if (log_regex_split_fields(fields_arg, &regex_state.log) != 0 || regex_state.log.count == 0) {
            LOG_ERROR("invalid --fields value");
            log_regex_free(&regex_state.log);
            return 1;
        }

        int rc = regcomp(&regex_state.regex, regex_pattern, REG_EXTENDED);
        if (rc != 0) {
            char err[256];
            regerror(rc, &regex_state.regex, err, sizeof(err));
            LOG_ERROR("invalid regex: %s", err);
            log_regex_free(&regex_state.log);
            return 1;
        }
        
        if (has_agg) {
            for (size_t i = 0; i < regex_state.log.count; ++i) {
                if (strcmp(regex_state.log.names[i], agg_field) == 0) {
                    agg_field_idx = (int)i;
                    break;
                }
            }
            if (agg_field_idx == -1) {
                LOG_ERROR("aggregate field '%s' not found in --fields", agg_field);
                log_regex_free(&regex_state.log);
                regfree(&regex_state.regex);
                return 1;
            }
        }
        
        regex_ready = 1;
    } else if (fields_arg != NULL || (format_arg != NULL && format != LOG_OUTPUT_COUNT && !has_agg)) {
        LOG_ERROR("--fields and --format json|csv require --regex");
        return 1;
    }

    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, stdin) > 0) {
        trim_line(line);

        if (regex_mode) {
            int rc = log_regex_parse_line(line, &regex_state.regex, &regex_state.log);
            if (rc < 0) {
                LOG_ERROR("out of memory while parsing line");
                exit_code = 2;
                break;
            }
            if (rc > 0) {
                LOG_WARN("line did not match regex; skipping");
                continue;
            }

            if (full_log != NULL && log_output_write_json(full_log, &regex_state.log) != 0) {
                LOG_ERROR("write full log failed");
                log_regex_free_values(&regex_state.log);
                exit_code = 2;
                break;
            }

            if (log_filter_match_fields(&regex_state.log, &filter)) {
                double val = 0;
                int val_found = 0;
                if (has_agg && agg_field_idx >= 0 && agg_field_idx < (int)regex_state.log.count) {
                    val = atof(regex_state.log.values[agg_field_idx]);
                    val_found = 1;
                }
                
                if (has_agg && val_found) {
                    if (agg_count == 0) {
                        agg_min = val;
                        agg_max = val;
                    }
                    agg_sum += val;
                    if (val < agg_min) agg_min = val;
                    if (val > agg_max) agg_max = val;
                    agg_count++;
                } else if (!has_agg) {
                    if (format == LOG_OUTPUT_JSON) {
                        if (log_output_emit_json(&regex_state.log) != 0) {
                            LOG_ERROR("out of memory while formatting JSON output");
                            log_regex_free_values(&regex_state.log);
                            exit_code = 2;
                            break;
                        }
                    } else if (format == LOG_OUTPUT_CSV) {
                        if (log_output_emit_csv(&regex_state.log) != 0) {
                            LOG_ERROR("out of memory while formatting CSV output");
                            log_regex_free_values(&regex_state.log);
                            exit_code = 2;
                            break;
                        }
                    } else {
                        ++matched_count;
                    }
                }
            }
            log_regex_free_values(&regex_state.log);
        } else {
            int matched = 0;

            if (log_filter_match_jsonl(line, &filter, &matched) != 0) {
                LOG_WARN("malformed JSON line; skipping");
                continue;
            }
            if (full_log != NULL && fprintf(full_log, "%s\n", line) < 0) {
                LOG_ERROR("write full log failed");
                exit_code = 2;
                break;
            }
            if (matched) {
                if (has_agg) {
                    int64_t i64 = 0;
                    if (jsonl_get_int64(line, agg_field, &i64) == 0) {
                        double val = (double)i64;
                        if (agg_count == 0) {
                            agg_min = val;
                            agg_max = val;
                        }
                        agg_sum += val;
                        if (val < agg_min) agg_min = val;
                        if (val > agg_max) agg_max = val;
                        agg_count++;
                    }
                } else if (format == LOG_OUTPUT_COUNT) {
                    ++matched_count;
                } else {
                    puts(line);
                }
            }
        }
    }

    if (ferror(stdin)) {
        LOG_ERROR("stdin read error");
        exit_code = 2;
    }

    free(line);
    if (exit_code == 0) {
        if (has_agg) {
            if (agg_count == 0) {
                printf("0\n");
            } else if (agg_op == AGG_SUM) {
                printf("%.2f\n", agg_sum);
            } else if (agg_op == AGG_AVG) {
                printf("%.2f\n", agg_sum / agg_count);
            } else if (agg_op == AGG_MIN) {
                printf("%.2f\n", agg_min);
            } else if (agg_op == AGG_MAX) {
                printf("%.2f\n", agg_max);
            }
        } else if (format == LOG_OUTPUT_COUNT) {
            printf("%zu\n", matched_count);
        }
    }
    
    if (regex_ready) {
        regfree(&regex_state.regex);
    }
    if (regex_mode) {
        log_regex_free(&regex_state.log);
    }
    if (full_log != NULL && fclose(full_log) != 0 && exit_code == 0) {
        LOG_ERROR("close full log failed: %s", strerror(errno));
        exit_code = 2;
    }
    fflush(stdout);

    return exit_code;
}
