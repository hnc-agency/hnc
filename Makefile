PROJECT = hnc
PROJECT_DESCRIPTION = Agency - Erlang Worker Pool
PROJECT_VERSION = 0.0.1
PROJECT_REGISTERED = hnc_workercntl_sup

CT_OPTS += -pa ebin -pa test -ct_hooks hnc_ct_hook []

include erlang.mk
