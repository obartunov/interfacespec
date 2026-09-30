MODULES = opclass_laws ctl_opclass
EXTENSION = opclass_laws
DATA = opclass_laws--0.1.sql
REGRESS = standard_types control_opclass limits

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
