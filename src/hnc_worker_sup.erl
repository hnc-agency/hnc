%% Copyright (c) 2020-2021, Jan Uhlig <juhlig@hnc-agency.org>
%% Copyright (c) 2020-2021, Maria Scott <maria-12648430@hnc-agency.org>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(hnc_worker_sup).

-behavior(supervisor).

-export([start_link/0]).
-export([start_agent/5]).
-export([stop_agent/1]).
-export([start_worker/4]).
-export([stop_worker/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
	supervisor:start_link(?MODULE, {}).

-spec start_agent(Sup :: pid(), Pool :: pid(), Opts :: hnc:opts(), WorkerMod :: module(), WorkerArgs :: term()) -> supervisor:startchild_ret().
start_agent(Sup, Pool, Opts, Mod, Args) ->
	supervisor:start_child(
		Sup,
		#{
			id => hnc_agent,
			start => {hnc_agent, start_link, [Pool, Opts, Mod, Args]},
			restart => permanent,
			shutdown => brutal_kill
		}
	).

-spec stop_agent(Sup :: pid()) -> ok.
stop_agent(Sup) ->
	_=supervisor:terminate_child(Sup, hnc_agent),
	ok.

-spec start_worker(Sup :: pid(), WorkerMod :: module(), WorkerArgs :: term(), Shutdown :: (timeout() | brutal_kill)) -> supervisor:startchild_ret().
start_worker(Sup, Mod, Args, Shutdown) ->
	{module, Mod}=code:ensure_loaded(Mod),
	Modules=case erlang:function_exported(Mod, get_modules, 0) of
		true -> Mod:get_modules();
		false -> [Mod]
	end,
	supervisor:start_child(
		Sup,
		#{
			id => hnc_worker,
			start => {Mod, start_link, [Args]},
			restart => temporary,
			shutdown => Shutdown,
			modules => Modules
		}
	).

-spec stop_worker(Sup :: pid()) -> ok.
stop_worker(Sup) ->
	_=supervisor:terminate_child(Sup, hnc_worker),
	_=supervisor:delete_child(Sup, hnc_worker),
	ok.

init({}) ->
	ok=logger:update_process_metadata(#{hnc => #{module => ?MODULE}}),
	{
		ok,
		{
			#{
				strategy => one_for_all,
				intensity => 0
		 	},
			[
			]
		}
	}.
