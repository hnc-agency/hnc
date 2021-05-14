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

-module(hnc_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

-spec start(_, _) -> {ok, pid()} | {error, Reason :: term()}.
start(_, _) ->
	_=logger:add_primary_filter(
		?MODULE,
		{
			fun
				%% Suppress pool_sup shutdown errors, they may happen if a pool shuts down.
				(#{meta:=#{hnc:=#{module:=hnc_pool_sup}}, msg:={report, #{label:={supervisor, shutdown_error}}}}, undefined) -> stop;
				%% Suppress worker_sup_sup shutdown errors, they may happen if a pool shuts down.
				(#{meta:=#{hnc:=#{module:=hnc_worker_sup_sup}}, msg:={report, #{label:={supervisor, shutdown_error}}}}, undefined) -> stop;
				%% Suppress worker_sup shutdown reports, they are expected if an agent crashes.
				(#{meta:=#{hnc:=#{module:=hnc_worker_sup}}, msg:={report, #{label:={supervisor, shutdown}}}}, undefined) -> stop;
				%% Suppress worker_sup shutdown reports, they are expected if an agent stops by itself.
				(#{meta:=#{hnc:=#{module:=hnc_worker_sup}}, msg:={report, #{label:={supervisor, child_terminated}}}}, undefined) -> stop;
				%% Suppress worker_sup shutdown errors, they are expected if an agent crashes.
				(#{meta:=#{hnc:=#{module:=hnc_worker_sup}}, msg:={report, #{label:={supervisor, shutdown_error}}}}, undefined) -> stop;
				%% Ignore everything else.
				(_, undefined) -> ignore
			end,
			undefined
		}
	),
	hnc_sup:start_link().

-spec stop(_) -> ok.
stop(_) ->
	_=logger:remove_primary_filter(?MODULE),
	ok.
