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

-module(hnc_test_worker).

-behavior(hnc_worker).

-export([start_link/1]).
-export([init/1]).
-export([echo/2]).

start_link(start_crash) ->
	exit(start_crash);
start_link(start_error) ->
	{error, start_error};
start_link(start_ignore) ->
	ignore;
start_link({delay_start, Time}) ->
	timer:sleep(Time),
	{ok, spawn_link(?MODULE, init, [undefined])};
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
init(Args={delay_stop, _}) ->
	erlang:process_flag(trap_exit, true),
	loop(Args);
init(Args) ->
	loop(Args).

loop(Args) ->
	receive
		stop ->
			ok;
		crash ->
			exit(crash);
		{{To, Tag}, Msg} ->
			To ! {Tag, Msg},
			loop(Args);
		{'EXIT', _, Reason} ->
			case Args of
				{delay_stop, Time} ->
					timer:sleep(Time),
					ok;
				_ ->
					ok
			end,
			exit(Reason)
	end.
