-module(hnc_ct_hook).

-export([init/2]).

init(_, _) ->
	application:ensure_all_started(hnc),
	{ok, undefined}.
