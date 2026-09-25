FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY wis2_adapter/app ./wis2_adapter/app
RUN go work init ./adapters/common ./wis2_adapter/app
RUN go build -o /wis2_adapter ./wis2_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /wis2_adapter /wis2_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates && chmod +x /wis2_adapter
CMD ["/wis2_adapter"]
