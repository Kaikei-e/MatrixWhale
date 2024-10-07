FROM node:22.9.0-bullseye AS build

WORKDIR /app

COPY ./app/package.json ./

RUN npm install

COPY ./app .

RUN npm run build

FROM node:22.9.0-bullseye-slim AS production

WORKDIR /app

COPY --from=build /app .

RUN npm install -g vite && npm install

EXPOSE 4173

CMD ["npm", "run", "preview"]