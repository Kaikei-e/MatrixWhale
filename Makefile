buf_generate:
	cd federation_orchestrator/federation_orchestrator/rpc/ && buf generate

copy_proto_ts:
	cp -r federation_orchestrator/federation_orchestrator/rpc/web/gen/* ./web/app/src/gen/
