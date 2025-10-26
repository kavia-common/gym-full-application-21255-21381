-- Gym Full Application - PostgreSQL Schema
-- This script is idempotent (uses IF NOT EXISTS, safe constraints, and guards).

-- Ensure public schema exists
CREATE SCHEMA IF NOT EXISTS public;

-- Users table
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL CHECK (role IN ('member', 'trainer', 'admin')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Helper function/trigger to keep updated_at current
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname = 'set_updated_at' AND n.nspname = 'public'
    ) THEN
        CREATE OR REPLACE FUNCTION public.set_updated_at()
        RETURNS TRIGGER AS $f$
        BEGIN
            NEW.updated_at = NOW();
            RETURN NEW;
        END;
        $f$ LANGUAGE plpgsql;
    END IF;
END$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE t.tgname = 'trg_users_updated_at' AND c.relname = 'users'
    ) THEN
        CREATE TRIGGER trg_users_updated_at
        BEFORE UPDATE ON public.users
        FOR EACH ROW
        EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END$$;

-- Memberships table
CREATE TABLE IF NOT EXISTS public.memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    type VARCHAR(50) NOT NULL, -- e.g., basic, premium
    status VARCHAR(50) NOT NULL CHECK (status IN ('active', 'paused', 'cancelled', 'expired')),
    start_date DATE NOT NULL,
    end_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_memberships_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE t.tgname = 'trg_memberships_updated_at' AND c.relname = 'memberships'
    ) THEN
        CREATE TRIGGER trg_memberships_updated_at
        BEFORE UPDATE ON public.memberships
        FOR EACH ROW
        EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END$$;

-- Classes table
CREATE TABLE IF NOT EXISTS public.classes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(200) NOT NULL,
    description TEXT,
    trainer_id UUID NOT NULL,
    capacity INTEGER NOT NULL CHECK (capacity > 0),
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_classes_trainer FOREIGN KEY (trainer_id) REFERENCES public.users(id) ON DELETE SET NULL
);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE t.tgname = 'trg_classes_updated_at' AND c.relname = 'classes'
    ) THEN
        CREATE TRIGGER trg_classes_updated_at
        BEFORE UPDATE ON public.classes
        FOR EACH ROW
        EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END$$;

-- Bookings table
CREATE TABLE IF NOT EXISTS public.bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    class_id UUID NOT NULL,
    member_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'booked' CHECK (status IN ('booked', 'cancelled', 'attended', 'no_show')),
    booked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (class_id, member_id),
    CONSTRAINT fk_bookings_class FOREIGN KEY (class_id) REFERENCES public.classes(id) ON DELETE CASCADE,
    CONSTRAINT fk_bookings_member FOREIGN KEY (member_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Workouts table
CREATE TABLE IF NOT EXISTS public.workouts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id UUID NOT NULL,
    trainer_id UUID,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    plan JSONB, -- workout plan details
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_workouts_member FOREIGN KEY (member_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT fk_workouts_trainer FOREIGN KEY (trainer_id) REFERENCES public.users(id) ON DELETE SET NULL
);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE t.tgname = 'trg_workouts_updated_at' AND c.relname = 'workouts'
    ) THEN
        CREATE TRIGGER trg_workouts_updated_at
        BEFORE UPDATE ON public.workouts
        FOR EACH ROW
        EXECUTE PROCEDURE public.set_updated_at();
    END IF;
END$$;

-- Payments table
CREATE TABLE IF NOT EXISTS public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
    currency VARCHAR(10) NOT NULL DEFAULT 'USD',
    status VARCHAR(50) NOT NULL CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
    payment_method VARCHAR(50), -- e.g., card, cash
    provider_ref VARCHAR(255), -- external processor reference
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_payments_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Refresh tokens table (for auth)
CREATE TABLE IF NOT EXISTS public.refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    token TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_refresh_tokens_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Audit logs
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID,
    action VARCHAR(100) NOT NULL,
    entity_type VARCHAR(100),
    entity_id VARCHAR(100),
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_audit_logs_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL
);

-- Useful indexes
CREATE INDEX IF NOT EXISTS idx_users_email ON public.users (email);
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users (role);
CREATE INDEX IF NOT EXISTS idx_memberships_user ON public.memberships (user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_status ON public.memberships (status);
CREATE INDEX IF NOT EXISTS idx_classes_trainer_time ON public.classes (trainer_id, start_time);
CREATE INDEX IF NOT EXISTS idx_bookings_class ON public.bookings (class_id);
CREATE INDEX IF NOT EXISTS idx_bookings_member ON public.bookings (member_id);
CREATE INDEX IF NOT EXISTS idx_workouts_member_date ON public.workouts (member_id, date);
CREATE INDEX IF NOT EXISTS idx_payments_user_status ON public.payments (user_id, status);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON public.refresh_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON public.audit_logs (action);

-- Extensions (optional but helpful)
DO $$
BEGIN
    -- Enable pgcrypto for gen_random_uuid if not available by default
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
        CREATE EXTENSION pgcrypto;
    END IF;
END$$;
