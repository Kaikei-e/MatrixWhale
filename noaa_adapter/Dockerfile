FROM golang:1.23-alpine3.19 as builder

RUN mkdir /usr/bin/noaa_adapter
WORKDIR /usr/bin/noaa_adapter
COPY ./app ./
RUN go mod download &&\
    go build -o noaa_adapter .


FROM alpine:3.20.3 as final
COPY --from=builder /usr/bin/noaa_adapter/noaa_adapter /noaa_adapter

RUN chmod +x /noaa_adapter

CMD ["/noaa_adapter"]



