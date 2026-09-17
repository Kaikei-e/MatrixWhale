FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY usgs_adapter/app ./usgs_adapter/app
RUN go work init ./adapters/common ./usgs_adapter/app
RUN go build -o /usgs_adapter ./usgs_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /usgs_adapter /usgs_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates && chmod +x /usgs_adapter
CMD ["/usgs_adapter"]
