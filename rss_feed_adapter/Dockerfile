FROM golang:1.26.8-alpine3.23 AS build

ADD ./rss_feed_adapter /usr/src/app/rss_feed_adapter

WORKDIR /usr/src/app/rss_feed_adapter

RUN apk update && apk add --no-cache wget curl nodejs npm

RUN go build -o rss_feed_adapter_binary

FROM alpine:3.23 AS runtime

WORKDIR /usr/src/app/rss_feed_adapter

COPY --from=build /usr/src/app/rss_feed_adapter/rss_feed_adapter_binary .

CMD ["./rss_feed_adapter_binary"]
