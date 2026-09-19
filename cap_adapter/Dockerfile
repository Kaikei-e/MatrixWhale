FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY cap_adapter/app ./cap_adapter/app
RUN go work init ./adapters/common ./cap_adapter/app
RUN go build -o /cap_adapter ./cap_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /cap_adapter /cap_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates && chmod +x /cap_adapter
CMD ["/cap_adapter"]
