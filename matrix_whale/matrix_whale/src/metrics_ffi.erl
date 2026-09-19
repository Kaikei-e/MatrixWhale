-module(metrics_ffi).
-export([
    setup/0,
    counter_inc/2,
    counter_inc_by/3,
    histogram_observe/3,
    gauge_set/3,
    render/0,
    monotonic_now/0,
    monotonic_elapsed_seconds/1
]).

setup() ->
    application:ensure_all_started(prometheus),
    prometheus_counter:declare([
        {name, matrixwhale_http_requests_total},
        {help, "Total HTTP requests handled"},
        {labels, [listener, route, method, code]}
    ]),
    prometheus_histogram:declare([
        {name, matrixwhale_http_request_duration_seconds},
        {help, "HTTP request duration in seconds"},
        {labels, [listener, route]},
        {buckets, [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]},
        {duration_unit, false}
    ]),
    prometheus_counter:declare([
        {name, matrixwhale_intake_records_total},
        {help, "Total intake records processed by source and outcome"},
        {labels, [source, outcome]}
    ]),
    prometheus_histogram:declare([
        {name, matrixwhale_ingest_lag_seconds},
        {help, "Age of incoming records at ingest time in seconds"},
        {labels, [source, basis]},
        {buckets, [1, 5, 15, 30, 60, 120, 180, 300, 600, 1200, 1800, 3600, 7200, 21600, 86400]},
        {duration_unit, false}
    ]),
    prometheus_histogram:declare([
        {name, matrixwhale_db_duration_seconds},
        {help, "Database operation duration in seconds"},
        {labels, [op]},
        {buckets, [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]},
        {duration_unit, false}
    ]),
    prometheus_gauge:declare([
        {name, matrixwhale_sse_clients},
        {help, "Current active SSE client connections"},
        {labels, [stream]}
    ]),
    prometheus_histogram:declare([
        {name, matrixwhale_sse_publish_delay_seconds},
        {help, "SSE publish fanout delay in seconds"},
        {labels, [stream]},
        {buckets, [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5]},
        {duration_unit, false}
    ]),
    persistent_term:put({metrics_ffi, setup_done}, true),
    nil.

ensure_setup() ->
    case persistent_term:get({metrics_ffi, setup_done}, false) of
        true -> ok;
        false -> setup()
    end.

counter_inc(Name, Labels) ->
    ensure_setup(),
    prometheus_counter:inc(default, metric_name(Name), Labels, 1),
    nil.

counter_inc_by(Name, Labels, Amount) when Amount >= 0 ->
    ensure_setup(),
    prometheus_counter:inc(default, metric_name(Name), Labels, Amount),
    nil.

histogram_observe(Name, Labels, Value) ->
    ensure_setup(),
    prometheus_histogram:observe(default, metric_name(Name), Labels, Value),
    nil.

gauge_set(Name, Labels, Value) ->
    ensure_setup(),
    prometheus_gauge:set(default, metric_name(Name), Labels, Value),
    nil.

render() ->
    ensure_setup(),
    prometheus_text_format:format().

monotonic_now() ->
    erlang:monotonic_time().

monotonic_elapsed_seconds(Start) ->
    End = erlang:monotonic_time(),
    erlang:convert_time_unit(End - Start, native, microsecond) / 1000000.0.

metric_name(<<"matrixwhale_http_requests_total">>) -> matrixwhale_http_requests_total;
metric_name(<<"matrixwhale_http_request_duration_seconds">>) -> matrixwhale_http_request_duration_seconds;
metric_name(<<"matrixwhale_intake_records_total">>) -> matrixwhale_intake_records_total;
metric_name(<<"matrixwhale_ingest_lag_seconds">>) -> matrixwhale_ingest_lag_seconds;
metric_name(<<"matrixwhale_db_duration_seconds">>) -> matrixwhale_db_duration_seconds;
metric_name(<<"matrixwhale_sse_clients">>) -> matrixwhale_sse_clients;
metric_name(<<"matrixwhale_sse_publish_delay_seconds">>) -> matrixwhale_sse_publish_delay_seconds;
metric_name(Name) when is_atom(Name) -> Name;
metric_name(Name) when is_binary(Name) -> binary_to_existing_atom(Name, utf8).
