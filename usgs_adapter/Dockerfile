FROM golang:1.26.8-alpine3.23 AS builder

WORKDIR /app
COPY ./app ./
RUN go mod download && go build -o usgs_adapter .

FROM alpine:3.23 AS final
COPY --from=builder /app/usgs_adapter /usgs_adapter
WORKDIR /app
RUN apk add --no-cache ca-certificates && chmod +x /usgs_adapter
CMD ["/usgs_adapter"]
