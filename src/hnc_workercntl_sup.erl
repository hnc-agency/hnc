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

-module(hnc_workercntl_sup).

-behavior(supervisor).

-export([start_link/2]).
-export([start_worker/1]).
-export([stop_worker/2]).
-export([return_worker/3]).
-export([init/1]).

-spec start_link(pid(), pid()) -> {ok, pid()}.
start_link(Pool, WorkerSup) ->
	supervisor:start_link(?MODULE, {Pool, WorkerSup}).

-spec start_worker(pid()) -> {ok, pid()}.
start_worker(Sup) ->
	supervisor:start_child(Sup, [start_worker, undefined]).

-spec stop_worker(pid(), hnc:worker()) -> {ok, pid()}.
stop_worker(Sup, Worker) ->
	supervisor:start_child(Sup, [stop_worker, Worker]).

-spec return_worker(pid(), hnc:worker(), hnc:on_return()) -> {ok, pid()}.
return_worker(Sup, Worker, ReturnCb) ->
	supervisor:start_child(Sup, [{return_worker, ReturnCb}, Worker]).

init({Pool, WorkerSup}) ->
	{
		ok,
		{
			#{
				strategy => simple_one_for_one
			},
			[
				#{
					id => hnc_workercntl,
					start => {hnc_workercntl, start_link, [Pool, WorkerSup]},
					restart => temporary
				}
			]
		}
	}.
