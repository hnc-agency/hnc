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

-module(hnc_test_worker).

-behavior(hnc_worker).

-export([start_link/1]).
-export([init/1]).
-export([echo/2]).

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
init(_) ->
	loop().

loop() ->
	receive
		stop ->
			ok;
		crash ->
			exit(crash);
		{{To, Tag}, Msg} ->
			To ! {Tag, Msg},
			loop()
	end.
