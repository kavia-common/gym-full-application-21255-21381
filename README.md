# gym-full-application-21255-21381

Database (PostgreSQL) Setup

This repository includes a lightweight database container folder at Database/ with scripts to start a local PostgreSQL instance, create the database and user, apply the schema, and seed sample data.

What’s included
- schema.sql: Defines core tables (users, memberships, classes, bookings, workouts, payments, refresh_tokens, audit_logs), constraints, and helpful indexes. Idempotent.
- seed.sql: Inserts sample users (member, trainer, admin), a few classes, a booking, a workout, a payment, and an audit log. Uses upserts/guards for idempotence.
- startup.sh: Starts PostgreSQL (if not already running), creates DB and user, applies schema.sql and seed.sql automatically.
- db_visualizer/: A small Node.js viewer to inspect the database. Environment variables are written to db_visualizer/postgres.env by startup.sh.

Quick start
1) Start the database and apply schema + seeds
   cd Database
   bash startup.sh

What it does:
- Starts PostgreSQL on port 5000 (or connects if already running).
- Creates database myapp and user appuser (password dbuser123).
- Applies schema.sql and seed.sql idempotently.
- Writes a connection helper to db_connection.txt.

2) Connect to the DB
   # Option 1
   psql -h localhost -U appuser -d myapp -p 5000

   # Option 2 (from db_connection.txt)
   cat Database/db_connection.txt
   psql postgresql://appuser:dbuser123@localhost:5000/myapp

3) Use the simple DB viewer (optional)
   # From Database/db_visualizer
   cd Database/db_visualizer
   source postgres.env
   npm install
   npm start
   # Visit http://localhost:3000 and choose postgres

Environment variables
- Written by startup.sh to Database/db_visualizer/postgres.env for convenience:
  POSTGRES_URL=postgresql://localhost:5000/myapp
  POSTGRES_USER=appuser
  POSTGRES_PASSWORD=dbuser123
  POSTGRES_DB=myapp
  POSTGRES_PORT=5000

Idempotency notes
- schema.sql uses CREATE TABLE IF NOT EXISTS and guarded triggers/functions.
- seed.sql uses INSERT ... ON CONFLICT or WHERE NOT EXISTS checks.
- Running startup.sh multiple times is safe; it will re-apply schema and seeds without duplications.

Troubleshooting
- If PostgreSQL binaries are not found under /usr/lib/postgresql/<version>/bin, update startup.sh’s PG_BIN variable accordingly.
- Ensure port 5000 is free or adjust DB_PORT at the top of startup.sh (and update db_visualizer/postgres.env or re-run startup.sh which regenerates it).
- To back up or restore, see Database/backup_db.sh and Database/restore_db.sh.