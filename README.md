# hnc (Agency) - Erlang worker pool

`hnc` is an Erlang worker pool application,
focussing on robustness and performance.

## Usage Example

```erlang
%% Start hnc application.
application:ensure_all_started(hnc).

%% Start a pool with default options.
{ok, _}=hnc:start_pool(my_pool, #{}, my_worker, []).

%% Check out a worker.
Ref=hnc:checkout(my_pool).

%% Get the worker pid from the identifier.
Worker=hnc:get_worker(Ref).

%% Do some stuff with the worker.
Result=my_worker:do_stuff(Worker).

%% Check worker back in.
ok=hnc:checkin(my_pool, Ref).

%% Or use a transaction to combine checking out,
%% doing stuff, and checking back in into one
%% convenient function.
Result=hnc:transaction(
    my_pool,
    fun (Worker) -> my_worker:do_stuff(Worker) end
).

%% Stop the pool
ok=hnc:stop_pool(my_pool).
```

## Usage as a dependency

### `Erlang.mk`

```
DEPS = hnc
dep_hnc = git https://github.com/hnc-agency/hnc 0.4.0
```

### `rebar3`

```
{deps, [
    {hnc, ".*", {git, "https://github.com/hnc-agency/hnc",
                   {tag, "0.4.0"}}}
]}.
```

## Authors

* Jan Uhlig (`juhlig`)
* Maria Scott (`Maria-12648430`)
