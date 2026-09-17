FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY emsc_adapter/app ./emsc_adapter/app
RUN go work init ./adapters/common ./emsc_adapter/app
RUN go build -o /emsc_adapter ./emsc_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /emsc_adapter /emsc_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates && chmod +x /emsc_adapter
CMD ["/emsc_adapter"]
