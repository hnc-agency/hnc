%% Copyright (c) 2020-2022, Jan Uhlig <juhlig@hnc-agency.org>
%% Copyright (c) 2020-2022, Maria Scott <maria-12648430@hnc-agency.org>
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

-module(hnc_worker_sup_sup).

-behavior(supervisor).

-export([start_link/3]).
-export([start_worker_sup/1, stop_worker_sup/2]).
-export([init/1]).

-spec start_link(module(), term(), hnc:shutdown()) -> {ok, pid()}.
start_link(Mod, Args, Shutdown) ->
	supervisor:start_link(?MODULE, {Mod, Args, Shutdown}).

-spec start_worker_sup(pid()) -> {ok, pid()}.
start_worker_sup(Sup) ->
	supervisor:start_child(Sup, [self()]).

-spec stop_worker_sup(pid(), pid()) -> ok.
stop_worker_sup(Sup, WorkerSup) ->
	supervisor:terminate_child(Sup, WorkerSup).

init({Mod, Args, Shutdown}) ->
	{module, Mod}=code:ensure_loaded(Mod),
	Modules=case erlang:function_exported(Mod, get_modules, 0) of
		true -> Mod:get_modules();
		false -> [Mod]
	end,
	ok=logger:update_process_metadata(#{hnc => #{module => ?MODULE}}),
	{
		ok,
		{
			#{
				strategy => simple_one_for_one
			},
			[
				#{
					id => hnc_worker_sup,
					start => {hnc_worker_sup, start_link, [Mod, Args, Shutdown, Modules]},
					restart => temporary,
					type => supervisor
				}
			]
		}
	}.
