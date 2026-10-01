MODULES = d1laws d1_ctl
EXTENSION = d1laws
DATA = d1laws--0.1.sql
REGRESS = d1_laws

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
