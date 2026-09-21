FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY jma_adapter/app ./jma_adapter/app
RUN go work init ./adapters/common ./jma_adapter/app
RUN go build -o /jma_adapter ./jma_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /jma_adapter /jma_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates tzdata && chmod +x /jma_adapter
CMD ["/jma_adapter"]
