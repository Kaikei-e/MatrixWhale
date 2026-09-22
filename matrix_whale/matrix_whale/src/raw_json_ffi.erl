-module(raw_json_ffi).
-export([raw/1]).

%% Returns a JSON text binary as-is, for embedding pre-serialized JSON
%% (e.g. ST_AsGeoJSON output) into a gleam_json Json value without re-parsing.
raw(Bin) when is_binary(Bin) -> Bin.
