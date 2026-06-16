# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Novu is an open-source communication infrastructure platform (notifications, Inbox, email, SMS, push, chat) for both products and AI agents. It is a **pnpm monorepo** managed with **Nx** and requires Node.js 22 and pnpm 11.

## Requirements

- Node.js v22.x (engine constraint: `>=22 <23`)
- pnpm 11 (`packageManager: pnpm@11.0.9`)
- MongoDB, Redis, ClickHouse (via Docker — see Infrastructure)

## Commands

### Setup

```bash
pnpm setup:project     # First-time setup: install, create .env files, build all
docker compose -f docker/local/docker-compose.yml up -d   # Start backing services
```

### Development

```bash
pnpm start:api:dev     # API on port 3000 (NestJS watch mode)
pnpm start:dashboard   # Dashboard on port 4201 (Vite dev server)
pnpm start:worker      # Worker (needed for notification flows)
pnpm start:ws          # WebSocket service (needed for real-time Inbox)
```

### Build

```bash
pnpm build             # Build everything
pnpm build:v2          # Build api, worker, ws, dashboard + packages
# After editing packages/ or libs/ — rebuild before restarting apps:
pnpm build             # or target a single app: nx build @novu/api-service
```

> Direct changes to `apps/` do not require a rebuild (dev servers rebuild on watch). Rebuild is only needed after changes to `packages/`, `libs/`, or `enterprise/`.

### Testing

```bash
# API unit tests (Mocha)
cd apps/api && pnpm test

# Run a single API test file
cd apps/api && pnpm test -- --grep "test name pattern"

# Worker unit tests (Mocha)
cd apps/worker && pnpm test

# Dashboard E2E (Playwright — start dashboard first)
cd apps/dashboard && pnpm test:e2e
```

### Linting & Formatting

```bash
pnpm lint              # Nx run-many lint across all packages
pnpm check             # Biome check (lint + format)
pnpm check:fix         # Auto-fix Biome issues
pnpm format:fix        # Format only

# Per-app
cd apps/api && pnpm check
cd apps/dashboard && pnpm check
```

### ClickHouse Migrations

```bash
cd apps/api && pnpm run clickhouse:migrate:local
```

### OpenAPI Validation (requires API running)

```bash
cd apps/api && npm run lint:openapi
```

## Architecture

### Monorepo Layout

```
apps/
  api/          NestJS REST API (port 3000) — primary backend
  dashboard/    React 19 + Vite frontend (port 4201)
  worker/       NestJS background job processor (Bull + Redis)
  ws/           NestJS WebSocket service (Socket.io, port 3002)
  webhook/      Inbound webhook handler — inactive, do not touch
libs/
  dal/                  MongoDB data access layer (Mongoose repositories)
  application-generic/  Shared NestJS providers: queues, services, use-cases
  testing/              Test harness and setup helpers (use instead of custom harnesses)
  internal-sdk/         Auto-generated SDK — never edit manually
packages/               Published to npm
  shared/     Types, DTOs, enums, utilities — used by both backend and frontend
  framework/  Code-first workflow SDK (developer-facing API)
  js/         Browser/Node.js notification client
  react/      React components including <Inbox />
  providers/  Channel provider implementations (email, SMS, push, etc.)
enterprise/   Enterprise submodule (separate repo, linked via pnpm)
```

### Dependency Graph

```
api → application-generic → dal
worker → application-generic
ws → application-generic
api, worker → shared
dashboard → react → js → shared
dashboard → framework
```

### Infrastructure Services

| Service     | Port(s)         | Purpose                            |
|-------------|----------------|------------------------------------|
| MongoDB     | 27017          | Primary database                   |
| Redis       | 6379           | Bull queues + caching              |
| ClickHouse  | 8123 / 9000    | Analytics, activity feed, traces   |
| LocalStack  | 4566           | S3 emulation (optional)            |

## Code Conventions

### General

- File/directory names: lowercase with dashes (`components/auth-wizard`)
- Named exports for all components
- TypeScript: `interface` on the backend, `type` on the frontend
- Blank line before every `return` statement
- No nested ternaries
- Animations: import from `"motion/react"` (not `"framer-motion"`)

### API Service (`apps/api`)

- Every protected route must use `@RequireAuthentication()`.
- Routes accessible via user API keys or the official SDK must also use `@ExternalApiAccessible`.
- Business logic lives in use-case classes (CQRS pattern), not controllers. Use-cases receive a typed command and return a typed result via `execute(command)`.
- Controller method names: `getEntityName`, `listEntityName`, `createEntityName`, `updateEntityName`, `deleteEntityName`.
- Every endpoint needs `@ApiOperation`, `@ApiResponse`, and `@ApiTags` decorators.
- List endpoints must support pagination and use `@SdkUsePagination`.
- Canonical example: `apps/api/src/app/tenant/tenant.controller.ts`

### DAL (`libs/dal`)

- **New repositories must extend `BaseRepositoryV2`**; existing 32 repos stay on the deprecated `BaseRepository`.
- Every `BaseRepositoryV2` read method requires an explicit `select` argument (array, object, or `'*'`). Omitting `select` is a compile error.
- Never access `_model` or `MongooseModel` directly — always use inherited methods.
- All queries must include `_environmentId` or `_organizationId` for tenant isolation.
- Transactions: `repository.withTransaction(async (session) => { ... })` — run operations sequentially inside (no `Promise.all`).

### Dashboard (`apps/dashboard`)

- Use TanStack Query (`useQuery`, `useMutation`) for all server state — no `useEffect` + `fetch` directly.
- Build on Radix UI primitives and the existing shadcn/ui components in `src/components/ui/`.
- Use Tailwind utility classes; avoid `style` props except for dynamic values.
- Navigation: React Router v6 `<Link>` / `useNavigate` — not `window.location`.
- Canonical example: `apps/dashboard/src/components/environments/edit-environment-sheet.tsx`

### Worker (`apps/worker`)

- Each notification channel has a dedicated `send-message` use-case under `apps/worker/src/app/workflow/usecases/`.
- Keep channel-specific logic isolated — do not share send-message logic across channels.
- Retry logic and failure handling are configured at the queue level in `libs/application-generic` — don't duplicate in worker use-cases.

### WebSocket (`apps/ws`)

- New Socket.io event types require matching updates in both `@novu/js` and `@novu/react`.

### ClickHouse

- Inject `ClickHouseService` (single queries) or `ClickHouseBatchService` (high-throughput) — never instantiate clients directly.
- All ClickHouse repositories extend `LogRepository` in `libs/application-generic/src/services/analytic-logs/`.
- New ClickHouse-dependent behavior must be gated behind a feature flag (see `packages/shared/src/types/feature-flags.ts`).
- Migrations are additive only — never alter or drop columns in place.

### Shared Packages (`packages/`)

- All exported symbols are public API — follow semver strictly.
- `packages/shared` must stay free of runtime side-effects (imported by both Node.js and browser bundles).

## Distribution Modes

Novu ships in three modes:
- **Community Edition** — open-source baseline
- **Enterprise Cloud** — gated with environment variables and feature flags
- **On-Prem Enterprise** — self-hosted, must not be broken by Cloud-only changes

When making Enterprise-targeted changes, gate them behind flags or `NOVU_ENTERPRISE` env variables; Cloud-only changes must not affect on-prem.

## Boundaries

**Work freely in:** `apps/api`, `apps/dashboard`, `apps/worker`, `apps/ws`, `packages/shared`, `packages/framework`, `packages/js`, `packages/react`, `libs/dal`, `libs/application-generic`

**Ask before:** creating new UI components outside `apps/dashboard/src/components/`, adding npm dependencies, modifying MongoDB models or ClickHouse table definitions, touching `enterprise/` or `packages/providers/`

**Never touch:** `apps/webhook` (inactive), `libs/internal-sdk` (auto-generated), `playground/` patterns in production code

## Pull Request Format

Title: `type(scope): Description fixes NV-<ticket-id>`

Scopes: `dashboard`, `api-service`, `worker`, `shared`, `js`, `react`, `react-native`, `nextjs`, `providers`, `root`

Include screenshots for UI changes. For non-trivial logic changes, include a Mermaid diagram. When changes touch `enterprise/`, also open a matching PR in `novuhq/packages-enterprise` on a branch from `next`.