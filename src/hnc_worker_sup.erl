-module(hnc_worker_sup).

-behavior(supervisor).

-export([start_link/3]).
-export([start_worker/1, stop_worker/2]).
-export([init/1]).

-spec start_link(module(), term(), hnc:shutdown()) -> {ok, pid()}.
start_link(Mod, Args, Shutdown) ->
	supervisor:start_link(?MODULE, {Mod, Args, Shutdown}).

-spec start_worker(pid()) -> {ok, hnc:worker()}.
start_worker(Sup) ->
	supervisor:start_child(Sup, []).

-spec stop_worker(pid(), hnc:worker()) -> ok.
stop_worker(Sup, Worker) ->
	supervisor:terminate_child(Sup, Worker).

init({Mod, Args, Shutdown}) ->
	{
		ok,
		{
			#{
				strategy => simple_one_for_one
			},
			[
				#{
					id => hnc_worker,
					start => {Mod, start_link, [Args]},
					restart => temporary,
					shutdown => Shutdown
				}
			]
		}
	}.
