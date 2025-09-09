# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MatrixWhale is a distributed data management system designed for processing large amounts of data. It consists of multiple microservices that work together to provide users with interactive search, manipulation, and analysis capabilities through a web interface. Initially built with reference to NOAA's API endpoints, it's designed for complex, diverse, and large-scale data processing.

## Architecture

The project follows a microservices architecture with the following components:

### Core Services
- **matrix_whale** (Port 8080, 6000) - Main Gleam service that handles data processing and API endpoints
- **federation_orchestrator** (Port 5000) - Go service that manages service coordination using gRPC/protobuf
- **noaa_adapter** (No exposed port) - Go service adapter for NOAA data integration
- **rss_feed_adapter** (Port 8085) - Go service for RSS feed processing
- **web** (Port 4173) - SvelteKit frontend application with TypeScript
- **proxy** (Port 80) - Nginx proxy for routing requests
- **db** (Port 5432) - PostgreSQL database

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

# Run tests
gleam test

# Format code
gleam format

# Run the application
gleam run
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

# Run tests
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

### Go Services
```bash
# For noaa_adapter, rss_feed_adapter, federation_orchestrator
cd [service_directory]/[service_name]

# Build
go build

# Run
go run main.go

# Test
go test ./...
```

## Key Directories and Files

### Gleam Projects
- `matrix_whale/matrix_whale/` - Main Gleam application with dependency management in `gleam.toml`
- `matrix_whale/matrix_whale/src/` - Gleam source code
- `matrix_whale/matrix_whale/test/` - Gleam tests

### Web Frontend
- `web/app/` - SvelteKit application
- `web/app/src/` - Frontend source code
- `web/app/src/gen/` - Generated protobuf files from federation orchestrator

### Go Services
- `noaa_adapter/app/` - Go NOAA adapter with `go.mod`
- `rss_feed_adapter/rss_feed_adapter/` - Go RSS feed service with `go.mod`
- `federation_orchestrator/federation_orchestrator/` - Go orchestrator with gRPC/protobuf definitions

### Infrastructure
- `compose.yaml` - Docker Compose configuration for all services
- `Makefile` - Build automation for protobuf generation
- `db/` - PostgreSQL database configuration and initialization scripts
- `proxy/` - Nginx proxy configuration

## Development Workflow

1. **Protobuf Changes**: When modifying gRPC definitions, run `make buf_generate` and `make copy_proto_ts` to regenerate code
2. **Database Changes**: Modify scripts in `db/init/` and recreate the database container
3. **Gleam Development**: Use standard Gleam workflow with `gleam build`, `gleam test`, `gleam format`
4. **Frontend Development**: Standard Node.js workflow with package.json scripts
5. **Go Services**: Standard Go development with modules

## Environment Setup

- Environment variables defined in `.env` file (use `.envTemplate` as reference)
- Services communicate via Docker network with fixed IP addresses
- Health checks configured for critical services (matrix_whale, federation_orchestrator, rss_feed_adapter, db)

## Testing

- **Gleam**: `gleam test` in matrix_whale/matrix_whale/
- **Frontend**: `npm run test` (includes Playwright integration tests and Vitest unit tests)
- **Go Services**: `go test ./...` in respective service directories
- **Integration**: Web testing available in `testing/web/` with Playwright configuration