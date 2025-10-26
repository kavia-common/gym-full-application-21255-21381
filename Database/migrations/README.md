# Database Schema Changes and Migrations

## Overview
This document explains how to manage schema changes for the Gym Full Application database. It covers how to apply the current schema.sql, how to create and apply new migrations, how to roll forward and roll back, and how these changes should relate to the BackendAPI ORM models. It also outlines recommended workflows for local development and production. Finally, it provides guidance for adopting Alembic in the future if/when we move to a full migration framework.

## Current State
- The database is PostgreSQL and is initialized and updated by Database/startup.sh.
- The canonical schema is defined in Database/schema.sql and is written to be idempotent using CREATE ... IF NOT EXISTS, guarded triggers/functions, and safe grants.
- Seed data is defined in Database/seed.sql and also uses idempotent patterns (INSERT ... ON CONFLICT, WHERE NOT EXISTS).
- The startup script applies both schema.sql and seed.sql every time it runs, so changes in those files will be applied to an existing database without duplication.

Relevant files:
- Database/startup.sh
- Database/schema.sql
- Database/seed.sql

## Principles
- The schema.sql is the source of truth for database structure until a formal migration framework (e.g., Alembic) is adopted.
- Changes must be idempotent wherever possible to allow repeated application in local environments and CI.
- Keep schema changes synchronized with BackendAPI ORM models to avoid drift. When models change, the schema must change, and vice versa.

## Applying the current schema.sql
For local development:
1) Start or update the local database
   cd Database
   bash startup.sh

What this does:
- Ensures PostgreSQL is started on port 5000 (or connects if already running).
- Ensures the database myapp and role appuser exist, with the expected permissions.
- Applies schema.sql and seed.sql idempotently.

Manual apply (advanced):
- If you need to apply only the schema changes manually:
  psql postgresql://appuser:dbuser123@localhost:5000/myapp -f Database/schema.sql

- To reapply the seeds manually:
  psql postgresql://appuser:dbuser123@localhost:5000/myapp -f Database/seed.sql

For production:
- Use the same schema.sql as the canonical source and apply it with a proper DB connection user that has necessary DDL permissions.
- It is recommended to review the SQL diff and test on a staging environment before applying in production.
- Prefer an explicit migration script per release (see “Creating new migrations” below) instead of directly editing schema.sql on a live system.

## Creating new migrations (pre-Alembic workflow)
Until we adopt Alembic, treat each schema change as a standalone SQL migration that can be applied safely multiple times and is easy to review.

Recommended structure under Database/migrations/:
- 001_initial_schema.sql (optional historical reference if needed)
- 002_add_user_preferences.sql
- 003_add_waitlist.sql
- 004_add_notification_logs.sql
- 005_add_scheduler_jobs.sql
- ...
- YYYYMMDD_HHMM_description.sql

Guidelines:
- Each migration should be idempotent. Use patterns like CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, DO $$ ... $$ guards for triggers/functions, ALTER TABLE with conditional checks if needed.
- Do not rely on destructive operations without guards. If you must drop or rename, ensure the script handles the object’s possible absence or previous state.
- Keep migrations small and focused on a single concern for easier review and rollback planning.
- Update Database/schema.sql to reflect the new final state, so a fresh environment can be fully created from schema.sql without replaying all historical migrations.

Example migration template:
-- YYYY-MM-DD: Brief description
-- Safe, idempotent DDL changes here
CREATE TABLE IF NOT EXISTS public.example (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL
);

-- Add an index safely
CREATE INDEX IF NOT EXISTS idx_example_name ON public.example (name);

-- Guarded trigger/function creation
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = 'set_example_updated_at' AND n.nspname = 'public'
  ) THEN
    CREATE OR REPLACE FUNCTION public.set_example_updated_at()
    RETURNS TRIGGER AS $f$
    BEGIN
      NEW.updated_at = NOW();
      RETURN NEW;
    END;
    $f$ LANGUAGE plpgsql;
  END IF;
END$$;

## Applying migrations (pre-Alembic)
Local development:
- The simplest approach is to add your new changes directly into schema.sql while developing, then extract a corresponding standalone migration file (e.g., 006_add_new_feature.sql) for production rollout. This keeps local iteration fast and guarantees fresh environments can be built from schema.sql alone.
- To apply a specific migration file locally:
  psql postgresql://appuser:dbuser123@localhost:5000/myapp -f Database/migrations/006_add_new_feature.sql

Production:
- Prefer a “release bundle” approach:
  1) Create one or more migration files representing the changes since the last production release.
  2) Review and test those files in staging.
  3) Apply them in production during a maintenance window if needed:
     psql postgresql://<user>:<pass>@<host>:<port>/<db> -f Database/migrations/006_add_new_feature.sql
  4) After production is updated, commit the same changes integrated into schema.sql so that new environments stay consistent.

Tracking applied migrations:
- Pre-Alembic, you can maintain a lightweight ledger table to track applied migration filenames and timestamps:
  CREATE TABLE IF NOT EXISTS public.schema_migrations (
    id BIGSERIAL PRIMARY KEY,
    filename text NOT NULL UNIQUE,
    applied_at timestamptz NOT NULL DEFAULT now()
  );

- Add the following to the end of each migration file to record it:
  INSERT INTO public.schema_migrations (filename)
  VALUES ('006_add_new_feature.sql')
  ON CONFLICT (filename) DO NOTHING;

- This allows you to check what has been applied:
  SELECT * FROM public.schema_migrations ORDER BY applied_at DESC;

## Rolling forward and rolling back
General guidance:
- Prefer roll-forward fixes over rollbacks in shared environments, especially if data changes occurred.
- If you must rollback, prepare a corresponding reverse migration that undoes the changes safely and idempotently. For example, if you added a column, the rollback might drop that column only if it is safe and does not cause data loss you need to keep.

Examples:
- Roll forward (hotfix):
  -- Add missing index to improve performance
  CREATE INDEX IF NOT EXISTS idx_bookings_status ON public.bookings (status);

- Roll back (reversible simple change):
  DO $$
  BEGIN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'deprecated_col'
    ) THEN
      ALTER TABLE public.users DROP COLUMN deprecated_col;
    END IF;
  END$$;

Data migrations:
- Treat data migrations with extra caution. For production, run them in small batches, test on staging, and ensure they are idempotent or safely re-runnable.

## Relationship to BackendAPI ORM models
- When you modify SQL schema (new tables/columns/indexes, constraints, enums), update BackendAPI ORM models accordingly in the BackendAPI container so that models and DB are consistent.
- Sequence:
  1) Update Database/schema.sql and add an idempotent migration under Database/migrations/.
  2) Update BackendAPI ORM models to match the new schema (fields, relationships, constraints).
  3) Run Database/startup.sh locally to apply schema changes, then run BackendAPI tests and manual checks to verify the API works with the new schema.
  4) For production, apply the migration file(s) first, deploy BackendAPI changes immediately after (or in a compatible order that avoids breaking changes).
- Compatibility mindset:
  - Prefer additive changes (adding columns with defaults, adding new tables) that are backward compatible with old API versions during rolling deploys.
  - For breaking changes (renames, drops), plan a two-phase rollout: add new columns/structures first, update code to write/read both, migrate data, then remove old columns in a follow-up release.

## Local development workflow
- Iterative approach:
  1) Edit Database/schema.sql to define the new structure.
  2) Optionally add seed data updates to Database/seed.sql if needed for local testing.
  3) Run:
     cd Database
     bash startup.sh
  4) Verify the structure:
     psql postgresql://appuser:dbuser123@localhost:5000/myapp -c "\dt+"
  5) Update BackendAPI ORM models and run backend tests.
  6) Extract a focused, idempotent migration file under Database/migrations/ for production.

- Resetting local data (optional):
  - Use Database/backup_db.sh and Database/restore_db.sh to snapshot and restore.
  - Or drop and recreate the database if needed, then run startup.sh again.

## Production workflow
- Prepare migration files under Database/migrations/ with idempotent, reviewable SQL.
- Validate on staging using real-like data.
- Apply migrations on production during a planned window:
  psql postgresql://<user>:<pass>@<host>:<port>/<db> -f Database/migrations/<migration_filename.sql>
- Deploy BackendAPI changes alongside or right after, depending on the compatibility strategy.
- Keep Database/schema.sql updated to reflect the final state.

## Adopting Alembic later (recommended)
Alembic is a migration tool commonly used with SQLAlchemy. If we adopt Alembic in the BackendAPI container:
- The Alembic migrations would become the authoritative history for schema changes. schema.sql can still exist as a convenience for fresh environments but should be generated from or aligned with latest Alembic head.
- Typical steps to adopt:
  1) Add Alembic to BackendAPI (pip install alembic) and initialize it (alembic init).
  2) Configure alembic.ini and env.py to connect to the same PostgreSQL database as in Database/startup.sh.
  3) Generate an initial migration that reflects the current schema (alembic revision --autogenerate -m "baseline").
  4) From this point, use alembic revision --autogenerate for changes and alembic upgrade head to apply in all environments.
  5) Decide whether to keep applying Database/schema.sql in local-only contexts, or to shift all environments (including local) to Alembic-only upgrades.
- In production, you would then run:
  alembic upgrade head
  as part of the deployment, instead of manually applying SQL files.

## FAQs and Tips
- Why use IF NOT EXISTS guards?
  They make scripts re-runnable and safer across environments.
- How to handle ENUM-like constraints?
  Prefer CHECK constraints or referenced lookup tables for flexibility; if using PostgreSQL enums, plan evolutions carefully.
- How to keep performance healthy?
  Add indexes as part of migrations when adding new query patterns, and prefer CREATE INDEX IF NOT EXISTS for safe re-application.
- What about extensions?
  schema.sql already includes a guard to create pgcrypto if missing. Add similar guarded blocks for other extensions.

## Appendix: Commands cheat sheet
- Apply all (local): 
  cd Database && bash startup.sh
- Apply a single migration (local): 
  psql postgresql://appuser:dbuser123@localhost:5000/myapp -f Database/migrations/<file.sql>
- List tables:
  psql postgresql://appuser:dbuser123@localhost:5000/myapp -c "\dt"
- Check applied migration ledger (if used):
  psql postgresql://appuser:dbuser123@localhost:5000/myapp -c "SELECT * FROM public.schema_migrations ORDER BY applied_at DESC;"
