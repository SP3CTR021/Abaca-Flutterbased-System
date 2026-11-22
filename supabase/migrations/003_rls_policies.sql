-- ============================================================================
-- 003_rls_policies.sql
-- Abaca System — Role-Based Row Level Security (Supabase / PostgreSQL)
-- ============================================================================

-- Helper functions run SECURITY DEFINER so policy checks never recurse on
-- employees RLS rules.
CREATE OR REPLACE FUNCTION public.is_active_employee()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.employees
        WHERE employee_id = auth.uid()
          AND is_active = TRUE
    );
$$;

CREATE OR REPLACE FUNCTION public.current_employee_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT role
    FROM public.employees
    WHERE employee_id = auth.uid()
      AND is_active = TRUE
    LIMIT 1;
$$;

-- Enable RLS across all 12 domain tables.
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_ins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_in_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_outs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- employees: active staff can read; managers manage all; users may insert own
-- profile during self-signup bootstrap if no profile exists yet.
-- ----------------------------------------------------------------------------
CREATE POLICY employees_select_active ON public.employees
    FOR SELECT TO authenticated
    USING (public.is_active_employee() OR employee_id = auth.uid());

CREATE POLICY employees_insert_manager_or_self ON public.employees
    FOR INSERT TO authenticated
    WITH CHECK (
        public.current_employee_role() = 'manager'
        OR employee_id = auth.uid()
    );

CREATE POLICY employees_update_manager ON public.employees
    FOR UPDATE TO authenticated
    USING (public.current_employee_role() = 'manager')
    WITH CHECK (public.current_employee_role() = 'manager');

CREATE POLICY employees_delete_manager ON public.employees
    FOR DELETE TO authenticated
    USING (public.current_employee_role() = 'manager');

-- ----------------------------------------------------------------------------
-- suppliers: active staff read; manager & warehouse_staff write
-- ----------------------------------------------------------------------------
CREATE POLICY suppliers_select_active ON public.suppliers
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY suppliers_write_warehouse_manager ON public.suppliers
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff'));

-- ----------------------------------------------------------------------------
-- customers: active staff read; manager, warehouse_staff & accountant write
-- ----------------------------------------------------------------------------
CREATE POLICY customers_select_active ON public.customers
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY customers_write_staff ON public.customers
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff', 'accountant'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff', 'accountant'));

-- ----------------------------------------------------------------------------
-- inventory: active staff read; manager & warehouse_staff write metadata
-- ----------------------------------------------------------------------------
CREATE POLICY inventory_select_active ON public.inventory
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY inventory_write_warehouse_manager ON public.inventory
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff'));

-- ----------------------------------------------------------------------------
-- orders: active staff read; manager, warehouse_staff & accountant write
-- ----------------------------------------------------------------------------
CREATE POLICY orders_select_active ON public.orders
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY orders_write_staff ON public.orders
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff', 'accountant'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff', 'accountant'));

-- ----------------------------------------------------------------------------
-- deliveries: active staff read; manager, warehouse_staff & delivery_driver write
-- ----------------------------------------------------------------------------
CREATE POLICY deliveries_select_active ON public.deliveries
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY deliveries_write_dispatch ON public.deliveries
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff', 'delivery_driver'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff', 'delivery_driver'));

-- ----------------------------------------------------------------------------
-- stock_ins & stock_in_items: active staff read; manager & warehouse_staff write
-- ----------------------------------------------------------------------------
CREATE POLICY stock_ins_select_active ON public.stock_ins
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY stock_ins_write_warehouse_manager ON public.stock_ins
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff'));

CREATE POLICY stock_in_items_select_active ON public.stock_in_items
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY stock_in_items_write_warehouse_manager ON public.stock_in_items
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff'));

-- ----------------------------------------------------------------------------
-- stock_outs: active staff read; manager & warehouse_staff write
-- (delivery drivers mutate stock_outs exclusively via atomic rpc_complete_delivery)
-- ----------------------------------------------------------------------------
CREATE POLICY stock_outs_select_active ON public.stock_outs
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY stock_outs_write_warehouse_manager ON public.stock_outs
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'warehouse_staff'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'warehouse_staff'));

-- ----------------------------------------------------------------------------
-- payments & expenses: active staff read; manager & accountant write
-- ----------------------------------------------------------------------------
CREATE POLICY payments_select_active ON public.payments
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY payments_write_finance ON public.payments
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'accountant'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'accountant'));

CREATE POLICY expenses_select_active ON public.expenses
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY expenses_write_finance ON public.expenses
    FOR ALL TO authenticated
    USING (public.current_employee_role() IN ('manager', 'accountant'))
    WITH CHECK (public.current_employee_role() IN ('manager', 'accountant'));

-- ----------------------------------------------------------------------------
-- activity_logs: STRICTLY APPEND-ONLY (SELECT + INSERT only; UPDATE/DELETE denied)
-- ----------------------------------------------------------------------------
CREATE POLICY activity_logs_select_active ON public.activity_logs
    FOR SELECT TO authenticated
    USING (public.is_active_employee());

CREATE POLICY activity_logs_insert_active ON public.activity_logs
    FOR INSERT TO authenticated
    WITH CHECK (public.is_active_employee());
