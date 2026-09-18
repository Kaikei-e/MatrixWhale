FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY gdacs_adapter/app ./gdacs_adapter/app
RUN go work init ./adapters/common ./gdacs_adapter/app
RUN go build -o /gdacs_adapter ./gdacs_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /gdacs_adapter /gdacs_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates && chmod +x /gdacs_adapter
CMD ["/gdacs_adapter"]
