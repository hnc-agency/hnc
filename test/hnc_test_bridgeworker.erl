-module(hnc_test_bridgeworker).

-behavior(hnc_worker).

-export([start_link/1, get_modules/0]).

start_link(Args) ->
	hnc_test_worker:start_link(Args).

get_modules() ->
	[hnc_test_worker].
