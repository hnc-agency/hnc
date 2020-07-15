# See LICENSE for licensing information

PROJECT = hnc
PROJECT_DESCRIPTION = hnc - Erlang Worker Pool
PROJECT_VERSION = 0.1.0
PROJECT_REGISTERED = hnc_workercntl_sup

CT_OPTS += -pa ebin -pa test -ct_hooks hnc_ct_hook []

DOC_DEPS = asciideck

include erlang.mk
