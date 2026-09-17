FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /src
COPY adapters/common ./adapters/common
COPY noaa_adapter/app ./noaa_adapter/app
RUN go work init ./adapters/common ./noaa_adapter/app
RUN go build -o /noaa_adapter ./noaa_adapter/app

FROM alpine:3.23 AS final
COPY --from=builder /noaa_adapter /noaa_adapter

WORKDIR /app
RUN chmod +x /noaa_adapter

CMD ["/noaa_adapter"]
