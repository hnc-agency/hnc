-module(hnc_test_worker).

-behavior(hnc_worker).

-export([start_link/1]).
-export([init/1]).
-export([echo/2]).

start_link(Args) ->
	{ok, spawn_link(?MODULE, init, [Args])}.

echo(Pid, Msg) ->
	Ref=monitor(process, Pid),
	Pid ! {{self(), Ref}, Msg},
	receive
		{Ref, Msg} ->
			demonitor(Ref, [flush]),
			Msg;
		{'DOWN', Ref, process, Pid, Reason} ->
			error(Reason)
	end.

init(crash) ->
	exit(crash);
init(_) ->
	process_flag(trap_exit, true),
	loop().

loop() ->
	receive
		stop ->
			ok;
		crash ->
			exit(crash);
		{'EXIT', _, shutdown} ->
			timer:sleep(5000),
			ok;
		{'EXIT', _, Reason} ->
			exit(Reason);
		{{To, Tag}, Msg} ->
			To ! {Tag, Msg},
			loop()
	end.
