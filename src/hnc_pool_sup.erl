%% Copyright (c) 2020, Jan Uhlig <j.uhlig@mailingwork.de>
%% Copyright (c) 2020, Maria Scott <maria-12648430@gmx.net>
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

-module(hnc_pool_sup).

-behavior(supervisor).

-export([start_link/4]).
-export([start_worker_sup/4]).
-export([init/1]).

-spec start_link(hnc:pool(), hnc:opts(), module(), term()) -> {ok, pid()}.
start_link(Name, Opts, Mod, Args) ->
	supervisor:start_link(?MODULE, {Name, Opts, Mod, Args}).

-spec start_worker_sup(pid(), module(), term(), timeout() | brutal_kill) -> {ok, pid()}.
start_worker_sup(Sup, Mod, Args, Shutdown) ->
	supervisor:start_child(
		Sup,
		#{
			id => hnc_worker_sup,
			start => {hnc_worker_sup, start_link, [Mod, Args, Shutdown]},
			restart => permanent,
			type => supervisor
		}
	).

init({Name, Opts, Mod, Args}) ->
	{
		ok,
		{
			#{
				strategy => one_for_all
			},
			[
				#{
					id => hnc_pool,
					start => {hnc_pool, start_link, [Name, Opts, Mod, Args]},
					restart => permanent
				}
			]
		}
	}.
