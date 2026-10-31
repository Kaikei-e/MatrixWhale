FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang

ADD /matrix_whale /app
WORKDIR /app
RUN gleam build

EXPOSE 6000 8080

CMD ["gleam", "run"]
