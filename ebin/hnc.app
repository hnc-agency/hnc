{application, 'hnc', [
	{description, "hnc - Erlang Worker Pool"},
	{vsn, "0.1.0"},
	{modules, ['hnc','hnc_app','hnc_embedded_sup','hnc_pool','hnc_pool_sup','hnc_sup','hnc_worker','hnc_worker_sup','hnc_workercntl','hnc_workercntl_sup','hnc_workercntl_sup_proxy']},
	{registered, [hnc_sup,hnc_workercntl_sup]},
	{applications, [kernel,stdlib]},
	{mod, {hnc_app, []}},
	{env, []}
]}.