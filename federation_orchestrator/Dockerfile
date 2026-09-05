FROM golang:1.26.8-alpine3.23 AS build

ADD ./federation_orchestrator /usr/src/app/federation_orchestrator

WORKDIR /usr/src/app/federation_orchestrator

RUN apk update && apk add --no-cache wget curl nodejs npm

# install buf, grpcurl, protoc-gen-go, protoc-gen-connect-go
RUN go install github.com/bufbuild/buf/cmd/buf@v1.72.0 && \
  go install github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 && \
  go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12 && \
  go install connectrpc.com/connect/cmd/protoc-gen-connect-go@v1.20.0 && \
  export PATH="$(go env GOBIN):$(go env GOPATH)/bin:${PATH}" && \
  npm install -g @bufbuild/protoc-gen-es@2.14.1 @connectrpc/protoc-gen-connect-es@1.7.0 && \
  cd /usr/src/app/federation_orchestrator/rpc && buf generate && \
  cd /usr/src/app/federation_orchestrator && go mod download && \
  go build -o federation_orchestrator main.go

# install buf
RUN BIN="/usr/local/bin" && \
  VERSION="1.72.0" && \
  curl -sSL \
  "https://github.com/bufbuild/buf/releases/download/v${VERSION}/buf-$(uname -s)-$(uname -m)" \
  -o "${BIN}/buf" && \
  chmod +x "${BIN}/buf"

FROM alpine:3.23 AS runtime

RUN mkdir -p /usr/src/app/federation_orchestrator && \
  cd /usr/src/app/federation_orchestrator

COPY --from=build /usr/src/app/federation_orchestrator/federation_orchestrator /usr/src/app/federation_orchestrator/federation_orchestrator

CMD ["/usr/src/app/federation_orchestrator/federation_orchestrator"]
