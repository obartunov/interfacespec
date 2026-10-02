MODULE_big = d2proto
OBJS = d2proto.o d2_ctl.o
EXTENSION = d2proto
DATA = d2proto--0.1.sql

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
