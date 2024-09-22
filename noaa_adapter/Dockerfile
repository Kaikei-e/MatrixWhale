FROM golang:1.23-alpine3.19 AS builder

WORKDIR /app
COPY ./app ./
RUN go mod download && \
    go build -o noaa_adapter .

FROM alpine:3.19 AS final
COPY --from=builder /app/noaa_adapter /noaa_adapter

WORKDIR /app
RUN chmod +x /noaa_adapter

CMD ["/noaa_adapter"]