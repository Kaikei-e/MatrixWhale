buf_generate:
	cd federation_orchestrator/federation_orchestrator/rpc/ && buf generate

copy_proto_ts:
	cp -r federation_orchestrator/federation_orchestrator/rpc/web/gen/* ./web/app/src/gen/

db-diff:
	cd db && atlas migrate diff $(name) --env local

db-apply:
	cd db && atlas migrate apply --env local

db-status:
	cd db && atlas migrate status --env local

test-core:
	./db/scripts/test_core.sh

adr-validate:
	docdag validate

RATE ?= 1

perf-api:
	@mkdir -p perf/results
	@TS=$$(date -u +%Y%m%dT%H%M%SZ); \
	SHA=$$(git rev-parse --short HEAD); \
	FULL_SHA=$$(git rev-parse HEAD); \
	DIRTY=$$(test -n "$$(git status --porcelain)" && echo true || echo false); \
	LOAD=$$(head -n 1 /proc/loadavg); \
	FILE_NAME="$$TS-$$SHA.json"; \
	echo "Running load test (RATE=$(RATE)) -> perf/results/$$FILE_NAME"; \
	docker run --rm \
		--network matrixwhale_matrix_network \
		--user $$(id -u):$$(id -g) \
		-v $(CURDIR)/perf:/perf \
		-w / \
		-e BASE_URL=http://matrix_whale:8080 \
		-e RATE=$(RATE) \
		-e GIT_SHA=$$FULL_SHA \
		-e GIT_DIRTY=$$DIRTY \
		-e LOADAVG="$$LOAD" \
		-e STARTED_AT="$$TS" \
		-e RESULT_FILE=/perf/results/$$FILE_NAME \
		grafana/k6:2.2.0 run /perf/k6/api.js

perf-compare:
	@if [ -z "$(A)" ] || [ -z "$(B)" ]; then \
		echo "Usage: make perf-compare A=<file> B=<file>"; \
		exit 1; \
	fi
	@jq -r -s -f perf/compare.jq $(A) $(B)
