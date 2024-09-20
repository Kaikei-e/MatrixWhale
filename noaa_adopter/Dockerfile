FROM golang:1.23-alpine3.19 as builder

RUN mkdir /usr/bin/noaa_adopter
WORKDIR /usr/bin/noaa_adopter
COPY ./app ./
RUN go mod download &&\
    go build -o noaa_adopter .


FROM alpine:3.20.3 as final
COPY --from=builder /usr/bin/noaa_adopter/noaa_adopter /noaa_adopter

RUN chmod +x /noaa_adopter

CMD ["/noaa_adopter"]



