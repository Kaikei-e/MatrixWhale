-module(intake_seen_set_ffi).
-export([new_table/1, unseen/3, mark/3, purge/2, size/1]).

%% Idempotent: a named ETS table survives for the life of the owning
%% process, so repeated `new/1` calls (e.g. across test cases sharing the
%% same runtime) must reuse rather than recreate it.
new_table(Name) ->
    Table = binary_to_atom(Name, utf8),
    case ets:info(Table) of
        undefined -> ets:new(Table, [named_table, public, set]);
        _ -> Table
    end,
    Table.

unseen(Table, Keys, NowMs) ->
    lists:filter(fun(Key) -> not is_seen(Table, Key, NowMs) end, Keys).

mark(Table, Keys, ExpiresAtMs) ->
    ets:insert(Table, [{Key, ExpiresAtMs} || Key <- Keys]),
    nil.

purge(Table, NowMs) ->
    ets:select_delete(Table, [{{'$1', '$2'}, [{'=<', '$2', NowMs}], [true]}]).

size(Table) ->
    ets:info(Table, size).

is_seen(Table, Key, NowMs) ->
    case ets:lookup(Table, Key) of
        [{Key, ExpiresAtMs}] -> ExpiresAtMs > NowMs;
        [] -> false
    end.
