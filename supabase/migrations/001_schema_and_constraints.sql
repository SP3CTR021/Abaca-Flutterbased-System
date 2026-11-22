-- ============================================================================
-- 001_schema_and_constraints.sql
-- Abaca System — Zero-Anomaly PostgreSQL Schema (12 Core Tables)
--
-- Key fixes over DATABASE_HANDOFF.md:
-- 1. UUID primary/foreign keys everywhere (matches Dart String IDs & Firestore).
-- 2. Removed password column from employees (bound 1:1 to auth.users(id)).
-- 3. Replaced destructive ON DELETE CASCADE on master tables with
--    ON DELETE RESTRICT + is_active archival flags.
-- 4. Added orders.inventory_id FK (composite FK with ON UPDATE CASCADE on
--    (inventory_id, abaca_type)) eliminating unreferenced string joins.
-- 5. Added stock_outs.delivery_id (UNIQUE) + order_id + notes and
--    deliveries.delivered_at + notes; removed duplicate MySQL delivery triggers
--    in favor of atomic rpc_complete_delivery.
-- 6. Added payments.employee_id + reference_number for financial accountability.
-- 7. Added inventory.min_stock_threshold_kg + description + is_active + created_at.
-- 8. Expanded customers.address & suppliers.address to VARCHAR(500).
-- 9. Added append-only activity_logs table.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- Shared timestamp trigger helpers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_inventory_last_updated()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.last_updated := NOW();
    RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 1. employees (1:1 with auth.users)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.employees (
    employee_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
    first_name VARCHAR(255) NOT NULL,
    middle_name VARCHAR(255) NULL,
    last_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL CHECK (
        role IN ('manager', 'warehouse_staff', 'delivery_driver', 'accountant')
    ),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employees_email_lower
    ON public.employees (LOWER(email));

CREATE INDEX IF NOT EXISTS idx_employees_role_active
    ON public.employees (role, is_active);

DROP TRIGGER IF EXISTS trg_employees_updated_at ON public.employees;
CREATE TRIGGER trg_employees_updated_at
    BEFORE UPDATE ON public.employees
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. suppliers
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.suppliers (
    supplier_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name VARCHAR(255) NOT NULL,
    middle_name VARCHAR(255) NULL,
    last_name VARCHAR(255) NOT NULL,
    contact_number VARCHAR(100) NULL,
    address VARCHAR(500) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_suppliers_active_name
    ON public.suppliers (is_active, last_name, first_name);

DROP TRIGGER IF EXISTS trg_suppliers_updated_at ON public.suppliers;
CREATE TRIGGER trg_suppliers_updated_at
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 3. customers
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customers (
    customer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name VARCHAR(255) NOT NULL,
    middle_name VARCHAR(255) NULL,
    last_name VARCHAR(255) NOT NULL,
    contact_number VARCHAR(100) NULL,
    address VARCHAR(500) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_customers_active_name
    ON public.customers (is_active, last_name, first_name);

DROP TRIGGER IF EXISTS trg_customers_updated_at ON public.customers;
CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE ON public.customers
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 4. inventory (master stock ledger per abaca grade)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory (
    inventory_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    abaca_type VARCHAR(100) NOT NULL UNIQUE,
    description VARCHAR(500) NULL,
    current_stock_kg NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (current_stock_kg >= 0),
    min_stock_threshold_kg NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (min_stock_threshold_kg >= 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_inventory_id_abaca_type UNIQUE (inventory_id, abaca_type)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_abaca_type_lower
    ON public.inventory (LOWER(abaca_type));

CREATE INDEX IF NOT EXISTS idx_inventory_active_type
    ON public.inventory (is_active, abaca_type);

DROP TRIGGER IF EXISTS trg_inventory_last_updated ON public.inventory;
CREATE TRIGGER trg_inventory_last_updated
    BEFORE UPDATE ON public.inventory
    FOR EACH ROW
    EXECUTE FUNCTION public.set_inventory_last_updated();

INSERT INTO public.inventory (abaca_type, description, current_stock_kg, min_stock_threshold_kg)
VALUES
    ('S2', 'Grade S2 abaca fiber', 0.00, 50.00),
    ('S3', 'Grade S3 abaca fiber', 0.00, 50.00),
    ('G',  'Grade G abaca fiber',  0.00, 50.00),
    ('I',  'Grade I abaca fiber',  0.00, 50.00),
    ('JK', 'Grade JK abaca fiber', 0.00, 50.00)
ON CONFLICT (abaca_type) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 5. orders (composite FK on (inventory_id, abaca_type) cascades grade renames)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
    order_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL REFERENCES public.customers(customer_id) ON DELETE RESTRICT,
    employee_id UUID NOT NULL REFERENCES public.employees(employee_id) ON DELETE RESTRICT,
    inventory_id UUID NOT NULL,
    abaca_type VARCHAR(100) NOT NULL,
    order_date DATE NOT NULL,
    quantity_kg NUMERIC(10, 2) NOT NULL CHECK (quantity_kg > 0),
    price_per_kg NUMERIC(10, 2) NOT NULL CHECK (price_per_kg >= 0),
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount = ROUND(quantity_kg * price_per_kg, 2)),
    status VARCHAR(50) NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'stocked', 'delivered', 'cancelled')
    ),
    notes TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_orders_inventory_grade
        FOREIGN KEY (inventory_id, abaca_type)
        REFERENCES public.inventory(inventory_id, abaca_type)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON public.orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_employee ON public.orders (employee_id);
CREATE INDEX IF NOT EXISTS idx_orders_inventory ON public.orders (inventory_id);
CREATE INDEX IF NOT EXISTS idx_orders_status_date ON public.orders (status, order_date DESC);

DROP TRIGGER IF EXISTS trg_orders_updated_at ON public.orders;
CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON public.orders
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 6. deliveries (strict 1:1 with orders via UNIQUE(order_id))
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deliveries (
    delivery_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL UNIQUE REFERENCES public.orders(order_id) ON DELETE RESTRICT,
    employee_id UUID NOT NULL REFERENCES public.employees(employee_id) ON DELETE RESTRICT,
    delivery_date DATE NOT NULL,
    delivered_at TIMESTAMPTZ NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'delivered')),
    notes TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_deliveries_status_timestamp CHECK (
        (status = 'pending' AND delivered_at IS NULL) OR
        (status = 'delivered' AND delivered_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_deliveries_employee_status_date
    ON public.deliveries (employee_id, status, delivery_date);

DROP TRIGGER IF EXISTS trg_deliveries_updated_at ON public.deliveries;
CREATE TRIGGER trg_deliveries_updated_at
    BEFORE UPDATE ON public.deliveries
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 7. stock_ins (inbound stock receipt headers)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stock_ins (
    stockin_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NULL REFERENCES public.orders(order_id) ON DELETE SET NULL,
    supplier_id UUID NOT NULL REFERENCES public.suppliers(supplier_id) ON DELETE RESTRICT,
    employee_id UUID NOT NULL REFERENCES public.employees(employee_id) ON DELETE RESTRICT,
    date_received DATE NOT NULL,
    notes TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_ins_supplier ON public.stock_ins (supplier_id);
CREATE INDEX IF NOT EXISTS idx_stock_ins_order ON public.stock_ins (order_id);
CREATE INDEX IF NOT EXISTS idx_stock_ins_date_received ON public.stock_ins (date_received DESC);

DROP TRIGGER IF EXISTS trg_stock_ins_updated_at ON public.stock_ins;
CREATE TRIGGER trg_stock_ins_updated_at
    BEFORE UPDATE ON public.stock_ins
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 8. stock_in_items (attributed M:N line items between stock_ins & inventory)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stock_in_items (
    stock_in_item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stockin_id UUID NOT NULL REFERENCES public.stock_ins(stockin_id) ON DELETE CASCADE,
    inventory_id UUID NOT NULL REFERENCES public.inventory(inventory_id) ON DELETE RESTRICT,
    quantity_kg NUMERIC(10, 2) NOT NULL CHECK (quantity_kg > 0),
    cost_per_kg NUMERIC(10, 2) NOT NULL CHECK (cost_per_kg >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_in_items_stockin ON public.stock_in_items (stockin_id);
CREATE INDEX IF NOT EXISTS idx_stock_in_items_inventory ON public.stock_in_items (inventory_id);

DROP TRIGGER IF EXISTS trg_stock_in_items_updated_at ON public.stock_in_items;
CREATE TRIGGER trg_stock_in_items_updated_at
    BEFORE UPDATE ON public.stock_in_items
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 9. stock_outs (outbound stock movements, optionally linked 1:1 to delivery)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stock_outs (
    stockout_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inventory_id UUID NOT NULL REFERENCES public.inventory(inventory_id) ON DELETE RESTRICT,
    employee_id UUID NOT NULL REFERENCES public.employees(employee_id) ON DELETE RESTRICT,
    delivery_id UUID NULL UNIQUE REFERENCES public.deliveries(delivery_id) ON DELETE RESTRICT,
    order_id UUID NULL REFERENCES public.orders(order_id) ON DELETE RESTRICT,
    quantity_kg NUMERIC(10, 2) NOT NULL CHECK (quantity_kg > 0),
    reason VARCHAR(50) NOT NULL CHECK (
        reason IN ('released', 'damaged', 'discarded', 'lost')
    ),
    notes TEXT NULL,
    date DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_stock_outs_delivery_reason CHECK (
        (delivery_id IS NULL) OR (reason = 'released')
    )
);

CREATE INDEX IF NOT EXISTS idx_stock_outs_inventory_date
    ON public.stock_outs (inventory_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_stock_outs_reason ON public.stock_outs (reason);
CREATE INDEX IF NOT EXISTS idx_stock_outs_order ON public.stock_outs (order_id);

DROP TRIGGER IF EXISTS trg_stock_outs_updated_at ON public.stock_outs;
CREATE TRIGGER trg_stock_outs_updated_at
    BEFORE UPDATE ON public.stock_outs
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 10. payments (customer payments against stocked/delivered orders)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payments (
    payment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(order_id) ON DELETE RESTRICT,
    employee_id UUID NOT NULL REFERENCES public.employees(employee_id) ON DELETE RESTRICT,
    amount_paid NUMERIC(12, 2) NOT NULL CHECK (amount_paid > 0),
    payment_date DATE NOT NULL,
    payment_method VARCHAR(100) NOT NULL,
    reference_number VARCHAR(150) NULL,
    notes TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payments_order ON public.payments (order_id);
CREATE INDEX IF NOT EXISTS idx_payments_employee_date
    ON public.payments (employee_id, payment_date DESC);
CREATE INDEX IF NOT EXISTS idx_payments_date ON public.payments (payment_date DESC);

DROP TRIGGER IF EXISTS trg_payments_updated_at ON public.payments;
CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE ON public.payments
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 11. expenses (operational expenses)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expenses (
    expense_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES public.employees(employee_id) ON DELETE RESTRICT,
    expense_type VARCHAR(150) NOT NULL,
    amount NUMERIC(12, 2) NOT NULL CHECK (amount >= 0),
    date DATE NOT NULL,
    notes TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_expenses_employee_date
    ON public.expenses (employee_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_expenses_type_date
    ON public.expenses (expense_type, date DESC);

DROP TRIGGER IF EXISTS trg_expenses_updated_at ON public.expenses;
CREATE TRIGGER trg_expenses_updated_at
    BEFORE UPDATE ON public.expenses
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 12. activity_logs (immutable append-only system audit trail)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activity_logs (
    activity_log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_employee_id UUID NULL REFERENCES public.employees(employee_id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL CHECK (
        action IN (
            'created',
            'updated',
            'deleted',
            'archived',
            'restored',
            'status_changed',
            'stock_adjusted',
            'delivery_completed',
            'payment_recorded',
            'payment_voided',
            'signed_in',
            'signed_out'
        )
    ),
    entity_type VARCHAR(50) NOT NULL CHECK (
        entity_type IN (
            'employee',
            'supplier',
            'customer',
            'inventory',
            'order',
            'stock_in',
            'stock_out',
            'delivery',
            'payment',
            'expense',
            'auth'
        )
    ),
    entity_id VARCHAR(128) NOT NULL,
    description TEXT NOT NULL,
    old_values JSONB NULL,
    new_values JSONB NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_activity_logs_entity
    ON public.activity_logs (entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_logs_actor
    ON public.activity_logs (actor_employee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_logs_created_at
    ON public.activity_logs (created_at DESC);

-- Enable Supabase Realtime replication when running inside a Supabase cluster.
DO $$
DECLARE
    v_table TEXT;
    v_tables TEXT[] := ARRAY[
        'employees',
        'suppliers',
        'customers',
        'inventory',
        'orders',
        'deliveries',
        'stock_ins',
        'stock_in_items',
        'stock_outs',
        'payments',
        'expenses',
        'activity_logs'
    ];
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH v_table IN ARRAY v_tables LOOP
            IF NOT EXISTS (
                SELECT 1
                FROM pg_publication_tables
                WHERE pubname = 'supabase_realtime'
                  AND schemaname = 'public'
                  AND tablename = v_table
            ) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', v_table);
            END IF;
        END LOOP;
    END IF;
END $$;
