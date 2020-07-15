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
