-module(hnc_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_, _) ->
	hnc_sup:start_link().

stop(_) ->
	ok.
