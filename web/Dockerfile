FROM node:22.11.0-bullseye-slim AS base


FROM base AS dependencies

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable

WORKDIR /app

COPY ./app/package.json ./app/pnpm-lock.yaml ./
COPY ./app .

# RUN npm install -g pnpm && pnpm install
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store pnpm fetch --frozen-lockfile
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store pnpm install --frozen-lockfile --prod


FROM base AS build

RUN corepack enable
WORKDIR /app

COPY ./app/package.json ./app/pnpm-lock.yaml ./

RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store pnpm fetch --frozen-lockfile
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store pnpm install --frozen-lockfile
COPY ./app .

RUN pnpm build


# RUN npm install -g vite && \
#   pnpm install
FROM base AS production

WORKDIR /app

COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=build ./app/build /app/build
COPY ./app/.env ./app/.env
ENV NODE_ENV=production

EXPOSE 4173
ENV PORT=4173

CMD ["node", "--env-file=./app/.env", "build"]
