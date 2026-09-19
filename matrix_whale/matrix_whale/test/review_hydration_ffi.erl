-module(review_hydration_ffi).
-export([read_only_snapshot/2]).

%% Manual benchmark only: pog.transaction uses pgo's five-second checkout
%% deadline for the entire transaction. A multi-sample comparison needs a
%% longer bounded checkout; retain one snapshot and always roll it back.
read_only_snapshot(Pool, Run) ->
    {ok, Ref, Conn} = pgo:checkout(Pool, [{timeout, 120000}]),
    try
        #{command := 'begin'} = pgo_handler:extended_query(
            Conn, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", [], #{}),
        Run({single_connection, Conn})
    after
        pgo_handler:extended_query(Conn, "ROLLBACK", [], #{}),
        pgo:checkin(Ref, Conn)
    end.
