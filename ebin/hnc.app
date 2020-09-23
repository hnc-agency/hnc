{application, 'hnc', [
	{description, "hnc - Erlang Worker Pool"},
	{vsn, "0.3.0"},
	{modules, ['hnc','hnc_app','hnc_pool','hnc_pool_sup','hnc_sup','hnc_worker','hnc_worker_sup']},
	{registered, [hnc_sup]},
	{applications, [kernel,stdlib]},
	{mod, {hnc_app, []}},
	{env, []}
]}.