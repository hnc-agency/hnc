-module(hnc_worker).

-callback start_link(term()) -> {ok, pid()}.
