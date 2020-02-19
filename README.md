# hnc (Agency) - Erlang worker pool

```erlang
%% Start hnc application.
application:ensure_all_started(hnc).

%% Start a pool with default options.
{ok, _}=hnc:start_pool(my_pool, #{}, my_worker, []).

%% Check out a worker.
Worker=hnc:checkout(my_pool).

%% ... Do some stuff with the worker...

%% Check worker back in.
ok=hnc:checkin(my_pool, Worker).

%% Stop the pool
ok=hnc:stop_pool(my_pool).
```
