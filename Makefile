# See LICENSE for licensing information

PROJECT = hnc
PROJECT_DESCRIPTION = hnc - Erlang Worker Pool
PROJECT_VERSION = 0.4.0

CT_OPTS += -pa ebin -pa test -ct_hooks hnc_ct_hook []

DOC_DEPS = asciideck

TEST_DEPS = ct_helper
dep_ct_helper = git https://github.com/ninenines/ct_helper master

include erlang.mk
