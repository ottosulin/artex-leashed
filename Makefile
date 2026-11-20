.PHONY: build run stop policy test check clean distclean public-export

SHELL := /bin/bash
PUBLIC_DIR ?= dist/public

build:
	./scripts/build.sh

run:
	./scripts/run.sh

stop:
	./scripts/stop.sh

policy:
	./scripts/render-policy.sh

test:
	python3 -m unittest scripts.tests.test_render_policy -v

check:
	./scripts/check-host.sh

clean: stop
	rm -rf .runtime policy/generated.cedar

distclean: clean
	docker volume rm -f artex-leashed-pgdata
	rm -rf data keys

public-export:
	./scripts/export-public.sh "$(PUBLIC_DIR)"
