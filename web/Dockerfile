FROM node:22.9.0-bullseye as build

ADD ./app /app

WORKDIR /app

RUN npm install && \
    npm run build

FROM node:22.9.0-bullseye-slim as production

RUN mkdir /app

COPY --from=build /app /app
EXPOSE 8080

CMD ["npm run start"]
