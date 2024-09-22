FROM node:22.9.0-bullseye AS build

ADD ./app /app

WORKDIR /app

RUN npm install && \
    npm run build

FROM node:22.9.0-bullseye-slim AS production

RUN mkdir /app

COPY --from=build /app /app

WORKDIR /app

EXPOSE 8080
CMD ["npm", "run", "preview"]
