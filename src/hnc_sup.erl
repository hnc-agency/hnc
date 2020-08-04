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

-module(hnc_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([start_pool/4]).
-export([stop_pool/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_pool(hnc:pool(), hnc:opts(), module(), term()) -> {ok, pid()}.
start_pool(Name, Opts, Mod, Args) ->
	ChildSpec0=hnc:child_spec(Name, Opts, Mod, Args),
	ChildSpec1=ChildSpec0#{restart => temporary},
	supervisor:start_child(
		?MODULE,
		ChildSpec1
	).

-spec stop_pool(hnc:pool()) -> ok.
stop_pool(Name) ->
	supervisor:terminate_child(?MODULE, {hnc_pool, Name}).

init([]) ->
	{
		ok,
		{
			#{
				strategy => one_for_one
			},
			[]
		}
	}.
