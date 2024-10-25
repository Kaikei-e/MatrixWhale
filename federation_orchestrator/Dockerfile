FROM golang:1.23.2-alpine AS build

ADD ./federation_orchestrator /usr/src/app/federation_orchestrator

WORKDIR /usr/src/app/federation_orchestrator

RUN apk update && apk add curl

# install buf, grpcurl, protoc-gen-go, protoc-gen-connect-go
# RUN go install github.com/bufbuild/buf/cmd/buf@latest
# RUN go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
# RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
# RUN go install connectrpc.com/connect/cmd/protoc-gen-connect-go@latest
# RUN export PATH="$(go env GOBIN):$(go env GOPATH)/bin:${PATH}"
# RUN cd /usr/src/app/federation_orchestrator/rpc && buf generate
# RUN cd /usr/src/app/federation_orchestrator && go get ./...
# RUN go build -o federation_orchestrator main.go

# install buf, grpcurl, protoc-gen-go, protoc-gen-connect-go
RUN go install github.com/bufbuild/buf/cmd/buf@latest && \
  go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest && \
  go install google.golang.org/protobuf/cmd/protoc-gen-go@latest && \
  go install connectrpc.com/connect/cmd/protoc-gen-connect-go@latest && \
  export PATH="$(go env GOBIN):$(go env GOPATH)/bin:${PATH}" && \
  cd /usr/src/app/federation_orchestrator/rpc && buf generate && \
  cd /usr/src/app/federation_orchestrator && go get ./... && \
  go build -o federation_orchestrator main.go

# install buf
RUN BIN="/usr/local/bin" && \
  VERSION="1.45.0" && \
  curl -sSL \
  "https://github.com/bufbuild/buf/releases/download/v${VERSION}/buf-$(uname -s)-$(uname -m)" \
  -o "${BIN}/buf" && \
  chmod +x "${BIN}/buf"

FROM alpine:latest AS runtime

RUN mkdir -p /usr/src/app/federation_orchestrator && \
  cd /usr/src/app/federation_orchestrator

COPY --from=build /usr/src/app/federation_orchestrator/federation_orchestrator /usr/src/app/federation_orchestrator/federation_orchestrator

CMD ["/usr/src/app/federation_orchestrator/federation_orchestrator"]
