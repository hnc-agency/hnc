# hnc (Agency) - Erlang worker pool

```erlang
%% Start hnc application.
application:ensure_all_started(hnc).

%% Start a pool with default options.
{ok, _}=hnc:start_pool(my_pool, #{}, my_worker, []).

%% Check out a worker.
WorkerRef=hnc:checkout(my_pool).

%% Get the worker pid from the identifier.
Worker=hnc:get_worker(WorkerRef).

%% Do some stuff with the worker.
my_worker:do_stuff(Worker).

%% Check worker back in.
ok=hnc:checkin(my_pool, WorkerRef).

%% Stop the pool
ok=hnc:stop_pool(my_pool).
```
