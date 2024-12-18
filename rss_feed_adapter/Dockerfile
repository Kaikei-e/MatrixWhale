FROM golang:1.23.3-alpine AS build

ADD ./rss_feed_adapter /usr/src/app/rss_feed_adapter

WORKDIR /usr/src/app/rss_feed_adapter

RUN apk update && apk add --no-cache wget curl nodejs npm

RUN go build -o rss_feed_adapter_binary

FROM alpine:latest AS runtime

WORKDIR /usr/src/app/rss_feed_adapter

COPY --from=build /usr/src/app/rss_feed_adapter/rss_feed_adapter_binary .

CMD ["./rss_feed_adapter_binary"]
