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

-module(hnc_worker_sup).

-behavior(supervisor).

-export([start_link/5]).
-export([init/1]).
-export([wait_worker/1]).
-export([stop_worker/1]).

-spec start_link(module(), term(), hnc:shutdown(), [module()], pid()) -> {ok, pid()}.
start_link(Mod, Args, Shutdown, Modules, ReportTo) ->
	supervisor:start_link(?MODULE, {Mod, Args, Shutdown, Modules, ReportTo}).

-spec wait_worker(pid()) -> {ok, hnc:worker()} | {error, term()} | term().
wait_worker(Sup) ->
	receive
		{worker_start, Sup, {ok, Worker}} when is_pid(Worker) -> {ok, Worker};
		{worker_start, Sup, {ok, NotWorker}} -> {error, {not_a_worker, NotWorker}};
		{worker_start, Sup, {error, {Reason, _}}} -> {error, Reason};
		{worker_start, Sup, Other} -> Other
	end.

-spec stop_worker(pid()) -> ok.
stop_worker(Sup) ->
	supervisor:terminate_child(Sup, hnc_worker).	

init({Mod, Args, Shutdown, Modules, ReportTo}) ->
	ok=logger:update_process_metadata(#{hnc => #{module => ?MODULE}}),
	Self=self(),
	_=spawn_link(
		fun () ->
			Res=supervisor:start_child(
				Self,
				#{
					id => hnc_worker,
					start => {Mod, start_link, [Args]},
					restart => permanent,
					shutdown => Shutdown,
					modules => Modules
				}
			),
			ReportTo ! {worker_start, Self, Res}
		end
	),
	{ok, {#{intensity=>0}, []}}.
