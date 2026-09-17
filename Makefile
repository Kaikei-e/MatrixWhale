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
