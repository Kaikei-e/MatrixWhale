# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MatrixWhale is a distributed data management system designed for processing large amounts of data. It consists of multiple microservices that work together to provide users with interactive search, manipulation, and analysis capabilities through a web interface. Initially built with reference to NOAA's API endpoints, it's designed for complex, diverse, and large-scale data processing.

## Architecture

The project follows a microservices architecture with the following components:

### Core Services
- **matrix_whale** (Port 8081:8080 streamer, 6000 receiver) - Main Gleam/BEAM service handling intake pipelines, canonical models, REST/SSE streaming, and timeline keyset pagination
- **federation_orchestrator** (Port 5000) - Go service that manages service coordination using gRPC/protobuf
- **noaa_adapter** (No exposed port) - Go service adapter for NOAA/NWS active alerts polling
- **usgs_adapter** (No exposed port) - Go service adapter for USGS earthquake feeds (startup `all_week` backfill, `all_day` polling with conditional GET)
- **emsc_adapter** (No exposed port) - Go service adapter for EMSC real-time WebSocket feed (`wss://www.seismicportal.eu/standing_order/websocket`) and FDSN backfill/gap-fill
- **gdacs_adapter** (No exposed port) - Go service adapter for GDACS multi-hazard polling (5-minute cycle) and core-driven pending geometry fetching (10s rate limiter)
- **cap_adapter** (No exposed port) - Go service adapter that follows the WMO Register of Alerting Authorities (daily) to ~200 national CAP feeds, polls feed indexes every 5 minutes with conditional GET and a per-host limiter, and fetches CAP documents from the core's pending list
- **rss_feed_adapter** (Port 8086:8085) - Go service for RSS feed processing
- **web** (Port 4174:4173) - SvelteKit frontend application with TypeScript, MapLibre nautical chart (`/globe`), tabbed side pane (Timeline, Earthquakes, Hazards, Alerts, Feed), `/feeds` CAP feed health page
- **proxy** (Port 8180:80, 9190:9090) - Plecto reverse proxy routing `/api` to streamer and `/` to web
- **db** (Port 5440:5432) - PostgreSQL 18 + PostGIS 3.6 database (`postgis/postgis:18-3.6`, storage `./db/data18`)
- **migrate** - Atlas runner applying versioned migrations from `db/migrations/` before `matrix_whale` starts

All services run in Docker containers with a custom network (10.254.100.0/24) for inter-service communication.

## Common Commands

### Development Setup
```bash
# Start all services
docker compose up -d

# View service logs
docker compose logs [service_name]

# Stop all services
docker compose down
```

### Matrix Whale (Gleam Service)
```bash
cd matrix_whale/matrix_whale

# Build the project
gleam build

# Run unit tests
gleam test

# Format code
gleam format

# Run the application
gleam run
```

### Database & Integration Testing
```bash
# Check migration status
make db-status

# Generate a new versioned migration from db/schema.sql
make db-diff name=<change_name>

# Apply pending migrations locally
make db-apply

# Run full Gleam integration test suite against a throwaway PostGIS container
make test-core

# Validate Architecture Decision Records (ADR) graph with DocDag
make adr-validate
```

### Web Frontend (SvelteKit)
```bash
cd web/app

# Install dependencies
npm install

# Development server
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview

# Run tests (Playwright + Vitest)
npm run test

# Type checking
npm run check

# Linting and formatting
npm run lint
npm run format
```

### Protocol Buffers (Federation Orchestrator)
```bash
# Generate protobuf files
make buf_generate

# Copy generated TypeScript files to web frontend
make copy_proto_ts
```

### Go Services & Adapters
```bash
# Shared adapter library
cd adapters/common && go test ./...

# NOAA adapter
cd noaa_adapter/app && go test ./...

# USGS adapter
cd usgs_adapter/app && go test -race ./...

# EMSC adapter
cd emsc_adapter/app && go test -race ./...

# GDACS adapter
cd gdacs_adapter/app && go test -race ./...

# CAP adapter (WMO RAA national feeds)
cd cap_adapter/app && go test -race ./...

# RSS feed adapter & Federation orchestrator
cd rss_feed_adapter/rss_feed_adapter && go test ./...
cd federation_orchestrator/federation_orchestrator && go test ./...
```

## Key Directories and Files

### Gleam Projects
- `matrix_whale/matrix_whale/` - Main Gleam application with dependency management in `gleam.toml`
- `matrix_whale/matrix_whale/src/` - Gleam source code (intake pipelines, canonical event matching, domain models, streamer, receiver)
- `matrix_whale/matrix_whale/test/` - Gleam unit and integration tests

### Web Frontend
- `web/app/` - SvelteKit application
- `web/app/src/` - Frontend source code (MapLibre nautical chart `/globe`, tabbed side pane, stores for alerts/earthquakes/hazards/timeline)
- `web/app/src/gen/` - Generated protobuf files from federation orchestrator
- `web/app/tests/` - Vitest unit tests and Playwright integration tests

### Go Services and Adapters
- `adapters/common/` - Shared adapter utilities (core HTTP client, backoff, acknowledgments, logging, User-Agent)
- `noaa_adapter/app/` - Go NOAA active alerts polling adapter
- `usgs_adapter/app/` - Go USGS earthquake feed adapter
- `emsc_adapter/app/` - Go EMSC real-time WebSocket and FDSN backfill adapter
- `gdacs_adapter/app/` - Go GDACS multi-hazard polling and pending geometry adapter
- `cap_adapter/app/` - Go WMO RAA registry, national CAP feed polling, and pending CAP document adapter
- `rss_feed_adapter/rss_feed_adapter/` - Go RSS feed service with `go.mod`
- `federation_orchestrator/federation_orchestrator/` - Go orchestrator with gRPC/protobuf definitions

### Infrastructure & Database
- `compose.yaml` - Docker Compose configuration for all services and network `10.254.100.0/24`
- `Makefile` - Build and test automation (db migrations, test-core, adr-validate, protobuf)
- `db/schema.sql` - Desired state SQL schema for the `sea` database
- `db/migrations/` - Atlas-managed versioned migrations
- `db/data18/` - Host mount directory for PostgreSQL 18 + PostGIS 3.6 data
- `proxy/` - Plecto reverse proxy configuration and source
- `docs/ADR/` - Architecture Decision Records validated by DocDag (`docdag.yaml` at the repo root)

## Development Workflow

1. **Architecture Decisions**: Record major changes in `docs/ADR/` using `docs/ADR/template.md`. Run `make adr-validate` to check frontmatter dependencies.
2. **Database Changes**: Edit `db/schema.sql`, run `make db-diff name=<change>` to generate a migration under `db/migrations/`, review the SQL, and verify with `make test-core`. The `migrate` compose service applies pending migrations on container boot.
3. **Gleam Development**: Follow Gleam OTP/Wisp/Mist patterns. Place domain logic in pure functions under `src/domain/` and database queries under `src/repository/`. Run `gleam test` and `make test-core`.
4. **Go Adapters**: Inherit shared behaviors (exponential backoff, core client POST, structured logging) from `adapters/common`. Ensure `-race` tests pass.
5. **Frontend Development**: SvelteKit 5 runes (`$state`, `$derived`, `$effect`). Maintain tab synchronization in `src/lib/pane/state.ts` and test with `npm run test`.
6. **Protobuf Changes**: When modifying gRPC definitions, run `make buf_generate` and `make copy_proto_ts` to regenerate code.

## Environment Setup

- Environment variables defined in `.env` file (use `.envTemplate` as reference)
- Services communicate via Docker network with fixed IP addresses
- Health checks configured for critical services (matrix_whale, federation_orchestrator, rss_feed_adapter, db)

## Testing

- **Gleam**: `gleam test` in `matrix_whale/matrix_whale/` (unit tests) and `make test-core` at root (database integration tests)
- **Frontend**: `npm run test` in `web/app/` (Playwright integration tests and Vitest unit tests), `npm run check`
- **Go Services**: `go test -race ./...` in respective adapter directories
- **Architecture Validation**: `make adr-validate` verifies ADR graph validity using DocDag

## Antigravity delegation

This project uses the local `antigravity` MCP server (`agy`) as the preferred implementer, with Claude reviewing and running the checks. Use `mode: "plan"` for research or a second opinion and `mode: "accept-edits"` for implementation, both with `autonomy: "safe"`; safe follows the configured `agy` permissions and is not a read-only guarantee.

- Keep each delegated request narrowly scoped, give it the files it owns, and use this repository's absolute workspace path. Parallel runs share the working tree, so their file scopes must not overlap.
- Up to 4 `agy` calls can run at once. Calls longer than about 2 minutes move to the background and report back when they finish.
- Preserve a returned `conversation_id` and provide it with the same workspace to `antigravity_continue` for follow-up work, including after a run was cut off.
- Runs are headless. Any shell command not allowed in `~/.gemini/antigravity-cli/settings.json` (`permissions.allow`, `command(<prefix>)`) is auto-denied and aborts the whole run. Command lines with globs, pipes, redirects or parentheses are denied even when the command is allowed. Tell the agent to run plain commands one at a time and to search with its built-in tools.
- Commands longer than about 10 s go async inside `agy`. Tell the agent to poll `command_status` until the command finishes and never to end its turn while one is running. Otherwise it returns without a report, and an interrupted Playwright run can leave `vite preview` listening on port 4199.
- Forbid the agent's own subagents: they are killed when its turn ends.
- Quotas are per model and reset after a few hours ("Individual quota reached"). After a quota, connection or 503 failure, the edits made so far remain on disk. Check `git diff` and the build before continuing.
- Do not ask a delegated agent to invoke this MCP server or otherwise create recursive delegation.
