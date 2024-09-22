FROM ghcr.io/gleam-lang/gleam:v1.5.0-erlang

ADD /matrix_whale /app
WORKDIR /app
RUN gleam build

EXPOSE 6000

CMD ["gleam", "run"]
