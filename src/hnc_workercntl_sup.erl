-module(hnc_workercntl_sup).

-behavior(supervisor).

-export([start_link/0]).
-export([start_worker/1]).
-export([stop_worker/2]).
-export([return_worker/3]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_worker(pid()) -> {ok, pid()}.
start_worker(WorkerSup) ->
	supervisor:start_child(?MODULE, [start_worker, self(), WorkerSup, undefined]).

-spec stop_worker(pid(), hnc:worker()) -> {ok, pid()}.
stop_worker(WorkerSup, Worker) ->
	supervisor:start_child(?MODULE, [stop_worker, self(), WorkerSup, Worker]).

-spec return_worker(pid(), hnc:worker(), hnc:on_return()) -> {ok, pid()}.
return_worker(WorkerSup, Worker, ReturnCb) ->
	supervisor:start_child(?MODULE, [{return_worker, ReturnCb}, self(), WorkerSup, Worker]).

init([]) ->
	{
		ok,
		{
			#{
				strategy => simple_one_for_one
			},
			[
				#{
					id => hnc_workercntl,
					start => {hnc_workercntl, start_link, []},
					restart => temporary
				}
			]
		}
	}.
