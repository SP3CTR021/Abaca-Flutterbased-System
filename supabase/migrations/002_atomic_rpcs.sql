-- ============================================================================
-- 002_atomic_rpcs.sql
-- Abaca System — Atomic Transactional RPC Functions
--
-- Custom ERRCODE conventions mapped by Dart SupabaseHelpers:
--   P0002 -> NotFoundFailure
--   P0003 -> InsufficientStockFailure (DETAIL carries JSON payload)
--   P0004 -> InvalidStateTransitionFailure (DETAIL carries JSON payload)
--   P0005 -> ValidationFailure
--   P0006 -> ConflictFailure
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. rpc_create_stock_in
-- Atomically creates a stock_ins header + stock_in_items, increments inventory,
-- and writes an append-only activity_logs entry.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_stock_in(
    p_order_id UUID,
    p_supplier_id UUID,
    p_employee_id UUID,
    p_date_received DATE,
    p_notes TEXT,
    p_items JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_stockin_id UUID;
    v_item JSONB;
    v_inventory_id UUID;
    v_qty NUMERIC(10, 2);
    v_cost NUMERIC(10, 2);
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'warehouse_staff') THEN
            RAISE EXCEPTION 'Only active managers or warehouse staff can record stock-ins.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'At least one stock-in line item is required.'
            USING ERRCODE = 'P0005';
    END IF;

    INSERT INTO public.stock_ins (
        order_id,
        supplier_id,
        employee_id,
        date_received,
        notes
    ) VALUES (
        p_order_id,
        p_supplier_id,
        p_employee_id,
        p_date_received,
        p_notes
    )
    RETURNING stockin_id INTO v_stockin_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_inventory_id := (v_item->>'inventory_id')::UUID;
        v_qty := ROUND((v_item->>'quantity_kg')::NUMERIC, 2);
        v_cost := ROUND((v_item->>'cost_per_kg')::NUMERIC, 2);

        IF v_qty <= 0 OR v_cost < 0 THEN
            RAISE EXCEPTION 'Line item quantity must be > 0 and cost_per_kg must be >= 0.'
                USING ERRCODE = 'P0005';
        END IF;

        PERFORM 1
        FROM public.inventory
        WHERE inventory_id = v_inventory_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Inventory grade % not found.', v_inventory_id
                USING ERRCODE = 'P0002',
                      DETAIL = jsonb_build_object(
                          'entity_name', 'Inventory',
                          'entity_id', v_inventory_id::TEXT
                      )::TEXT;
        END IF;

        INSERT INTO public.stock_in_items (
            stockin_id,
            inventory_id,
            quantity_kg,
            cost_per_kg
        ) VALUES (
            v_stockin_id,
            v_inventory_id,
            v_qty,
            v_cost
        );

        UPDATE public.inventory
        SET current_stock_kg = current_stock_kg + v_qty,
            last_updated = NOW()
        WHERE inventory_id = v_inventory_id;
    END LOOP;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        new_values
    ) VALUES (
        p_employee_id,
        'created',
        'stock_in',
        v_stockin_id::TEXT,
        format('Recorded stock-in receipt with %s item(s).', jsonb_array_length(p_items)),
        jsonb_build_object(
            'order_id', p_order_id,
            'supplier_id', p_supplier_id,
            'date_received', p_date_received,
            'items', p_items
        )
    );

    RETURN v_stockin_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. rpc_delete_stock_in
-- Atomically verifies reversing all items will not drive stock negative,
-- decrements inventory, deletes stock_ins (cascading items), and logs audit.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_stock_in(
    p_stockin_id UUID,
    p_actor_employee_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_stockin public.stock_ins%ROWTYPE;
    v_line RECORD;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'warehouse_staff') THEN
            RAISE EXCEPTION 'Only active managers or warehouse staff can delete stock-ins.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_stockin
    FROM public.stock_ins
    WHERE stockin_id = p_stockin_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'StockIn % not found.', p_stockin_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'StockIn',
                      'entity_id', p_stockin_id::TEXT
                  )::TEXT;
    END IF;

    FOR v_line IN
        SELECT
            sii.inventory_id,
            SUM(sii.quantity_kg) AS total_reversal_kg,
            inv.abaca_type,
            inv.current_stock_kg
        FROM public.stock_in_items sii
        JOIN public.inventory inv ON inv.inventory_id = sii.inventory_id
        WHERE sii.stockin_id = p_stockin_id
        GROUP BY sii.inventory_id, inv.abaca_type, inv.current_stock_kg
        ORDER BY sii.inventory_id
        FOR UPDATE OF inv
    LOOP
        IF v_line.current_stock_kg < v_line.total_reversal_kg THEN
            RAISE EXCEPTION 'Cannot reverse stock-in: insufficient % stock.', v_line.abaca_type
                USING ERRCODE = 'P0003',
                      DETAIL = jsonb_build_object(
                          'abaca_type', v_line.abaca_type,
                          'available_kg', v_line.current_stock_kg,
                          'requested_kg', v_line.total_reversal_kg
                      )::TEXT;
        END IF;

        UPDATE public.inventory
        SET current_stock_kg = current_stock_kg - v_line.total_reversal_kg,
            last_updated = NOW()
        WHERE inventory_id = v_line.inventory_id;
    END LOOP;

    DELETE FROM public.stock_ins
    WHERE stockin_id = p_stockin_id;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        old_values
    ) VALUES (
        p_actor_employee_id,
        'deleted',
        'stock_in',
        p_stockin_id::TEXT,
        'Deleted stock-in receipt and reversed inbound stock quantities.',
        to_jsonb(v_stockin)
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. rpc_create_stock_out
-- Blocks manual 'released' stock-outs (must go through rpc_complete_delivery).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_stock_out(
    p_inventory_id UUID,
    p_employee_id UUID,
    p_quantity_kg NUMERIC,
    p_reason VARCHAR,
    p_notes TEXT,
    p_date DATE
)
RETURNS public.stock_outs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inv public.inventory%ROWTYPE;
    v_created public.stock_outs%ROWTYPE;
    v_qty NUMERIC(10, 2);
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'warehouse_staff') THEN
            RAISE EXCEPTION 'Only active managers or warehouse staff can create stock-outs.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    IF p_reason = 'released' THEN
        RAISE EXCEPTION 'Released stock-outs can only be recorded via delivery completion.'
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'StockOut',
                      'current_state', 'manual',
                      'attempted_action', 'create_released_stock_out'
                  )::TEXT;
    END IF;

    v_qty := ROUND(p_quantity_kg, 2);
    IF v_qty <= 0 THEN
        RAISE EXCEPTION 'Stock-out quantity must be greater than zero.'
            USING ERRCODE = 'P0005';
    END IF;

    SELECT * INTO v_inv
    FROM public.inventory
    WHERE inventory_id = p_inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory grade % not found.', p_inventory_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Inventory',
                      'entity_id', p_inventory_id::TEXT
                  )::TEXT;
    END IF;

    IF v_inv.current_stock_kg < v_qty THEN
        RAISE EXCEPTION 'Insufficient % stock for stock-out.', v_inv.abaca_type
            USING ERRCODE = 'P0003',
                  DETAIL = jsonb_build_object(
                      'abaca_type', v_inv.abaca_type,
                      'available_kg', v_inv.current_stock_kg,
                      'requested_kg', v_qty
                  )::TEXT;
    END IF;

    UPDATE public.inventory
    SET current_stock_kg = current_stock_kg - v_qty,
        last_updated = NOW()
    WHERE inventory_id = p_inventory_id;

    INSERT INTO public.stock_outs (
        inventory_id,
        employee_id,
        quantity_kg,
        reason,
        notes,
        date
    ) VALUES (
        p_inventory_id,
        p_employee_id,
        v_qty,
        p_reason,
        p_notes,
        p_date
    )
    RETURNING * INTO v_created;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        new_values
    ) VALUES (
        p_employee_id,
        'stock_adjusted',
        'stock_out',
        v_created.stockout_id::TEXT,
        format('Recorded manual stock-out (%s): %s kg of %s.', p_reason, v_qty, v_inv.abaca_type),
        to_jsonb(v_created)
    );

    RETURN v_created;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. rpc_delete_stock_out
-- Restores manual stock-out weight; blocks deleting delivery-linked records.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_stock_out(
    p_stockout_id UUID,
    p_actor_employee_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_stockout public.stock_outs%ROWTYPE;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'warehouse_staff') THEN
            RAISE EXCEPTION 'Only active managers or warehouse staff can delete stock-outs.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_stockout
    FROM public.stock_outs
    WHERE stockout_id = p_stockout_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'StockOut % not found.', p_stockout_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'StockOut',
                      'entity_id', p_stockout_id::TEXT
                  )::TEXT;
    END IF;

    IF v_stockout.delivery_id IS NOT NULL THEN
        RAISE EXCEPTION 'Delivery-linked stock-out records cannot be deleted.'
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'StockOut',
                      'current_state', 'delivery_linked',
                      'attempted_action', 'delete_stock_out'
                  )::TEXT;
    END IF;

    UPDATE public.inventory
    SET current_stock_kg = current_stock_kg + v_stockout.quantity_kg,
        last_updated = NOW()
    WHERE inventory_id = v_stockout.inventory_id;

    DELETE FROM public.stock_outs
    WHERE stockout_id = p_stockout_id;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        old_values
    ) VALUES (
        p_actor_employee_id,
        'deleted',
        'stock_out',
        p_stockout_id::TEXT,
        'Deleted manual stock-out and restored deducted inventory weight.',
        to_jsonb(v_stockout)
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. rpc_mark_order_stocked
-- Verifies pending order and sufficient stock without deducting yet.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_mark_order_stocked(
    p_order_id UUID,
    p_actor_employee_id UUID
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_inv public.inventory%ROWTYPE;
    v_updated public.orders%ROWTYPE;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'warehouse_staff', 'accountant') THEN
            RAISE EXCEPTION 'Unauthorized role for marking order stocked.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found.', p_order_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'entity_id', p_order_id::TEXT
                  )::TEXT;
    END IF;

    IF v_order.status <> 'pending' THEN
        RAISE EXCEPTION 'Only pending orders can be marked stocked.'
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'current_state', v_order.status,
                      'attempted_action', 'mark_order_stocked'
                  )::TEXT;
    END IF;

    SELECT * INTO v_inv
    FROM public.inventory
    WHERE inventory_id = v_order.inventory_id
    FOR UPDATE;

    IF v_inv.current_stock_kg < v_order.quantity_kg THEN
        RAISE EXCEPTION 'Insufficient % stock to mark order stocked.', v_inv.abaca_type
            USING ERRCODE = 'P0003',
                  DETAIL = jsonb_build_object(
                      'abaca_type', v_inv.abaca_type,
                      'available_kg', v_inv.current_stock_kg,
                      'requested_kg', v_order.quantity_kg
                  )::TEXT;
    END IF;

    UPDATE public.orders
    SET status = 'stocked'
    WHERE order_id = p_order_id
    RETURNING * INTO v_updated;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        old_values,
        new_values
    ) VALUES (
        p_actor_employee_id,
        'status_changed',
        'order',
        p_order_id::TEXT,
        'Marked order as stocked.',
        jsonb_build_object('status', v_order.status),
        jsonb_build_object('status', v_updated.status)
    );

    RETURN v_updated;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. rpc_cancel_order
-- Cancels a pending/stocked order if no completed delivery or payments exist,
-- cleaning up any pending scheduled delivery first.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_cancel_order(
    p_order_id UUID,
    p_actor_employee_id UUID,
    p_reason TEXT
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_delivery public.deliveries%ROWTYPE;
    v_payment_count INTEGER;
    v_updated public.orders%ROWTYPE;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'warehouse_staff', 'accountant') THEN
            RAISE EXCEPTION 'Unauthorized role for cancelling order.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found.', p_order_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'entity_id', p_order_id::TEXT
                  )::TEXT;
    END IF;

    IF v_order.status IN ('delivered', 'cancelled') THEN
        RAISE EXCEPTION 'Cannot cancel order in status %.', v_order.status
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'current_state', v_order.status,
                      'attempted_action', 'cancel_order'
                  )::TEXT;
    END IF;

    SELECT COUNT(*) INTO v_payment_count
    FROM public.payments
    WHERE order_id = p_order_id;

    IF v_payment_count > 0 THEN
        RAISE EXCEPTION 'Cannot cancel an order with active payments. Void payments first.'
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'current_state', 'has_payments',
                      'attempted_action', 'cancel_order'
                  )::TEXT;
    END IF;

    SELECT * INTO v_delivery
    FROM public.deliveries
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF FOUND THEN
        IF v_delivery.status = 'delivered' THEN
            RAISE EXCEPTION 'Cannot cancel an order whose delivery is already delivered.'
                USING ERRCODE = 'P0004',
                      DETAIL = jsonb_build_object(
                          'entity_name', 'Order',
                          'current_state', 'delivered',
                          'attempted_action', 'cancel_order'
                      )::TEXT;
        END IF;
        DELETE FROM public.deliveries WHERE delivery_id = v_delivery.delivery_id;
    END IF;

    UPDATE public.orders
    SET status = 'cancelled',
        notes = CASE
            WHEN p_reason IS NOT NULL AND LENGTH(TRIM(p_reason)) > 0
                THEN COALESCE(notes || E'\n[Cancelled] ' || p_reason, '[Cancelled] ' || p_reason)
            ELSE notes
        END
    WHERE order_id = p_order_id
    RETURNING * INTO v_updated;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        old_values,
        new_values
    ) VALUES (
        p_actor_employee_id,
        'status_changed',
        'order',
        p_order_id::TEXT,
        COALESCE(NULLIF(TRIM(p_reason), ''), 'Order cancelled.'),
        jsonb_build_object('status', v_order.status),
        jsonb_build_object('status', v_updated.status)
    );

    RETURN v_updated;
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. rpc_complete_delivery
-- Single atomic fulfillment function (eliminates legacy PHP+trigger double
-- deduction): checks stock, decrements inventory ONCE, inserts stock_outs
-- (reason = 'released', delivery_id = p_delivery_id), marks delivery & order
-- delivered, and logs activity_logs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_complete_delivery(
    p_delivery_id UUID,
    p_actor_employee_id UUID,
    p_delivered_at TIMESTAMPTZ,
    p_notes TEXT
)
RETURNS public.deliveries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_delivery public.deliveries%ROWTYPE;
    v_order public.orders%ROWTYPE;
    v_inv public.inventory%ROWTYPE;
    v_updated public.deliveries%ROWTYPE;
    v_effective_delivered_at TIMESTAMPTZ;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'delivery_driver') THEN
            RAISE EXCEPTION 'Only active managers or delivery drivers can complete deliveries.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_delivery
    FROM public.deliveries
    WHERE delivery_id = p_delivery_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Delivery % not found.', p_delivery_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Delivery',
                      'entity_id', p_delivery_id::TEXT
                  )::TEXT;
    END IF;

    IF v_delivery.status <> 'pending' THEN
        RAISE EXCEPTION 'Delivery % is already %.', p_delivery_id, v_delivery.status
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Delivery',
                      'current_state', v_delivery.status,
                      'attempted_action', 'complete_delivery'
                  )::TEXT;
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = v_delivery.order_id
    FOR UPDATE;

    IF v_order.status <> 'stocked' THEN
        RAISE EXCEPTION 'Order must be in stocked state before completing delivery (current: %).', v_order.status
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'current_state', v_order.status,
                      'attempted_action', 'complete_delivery'
                  )::TEXT;
    END IF;

    SELECT * INTO v_inv
    FROM public.inventory
    WHERE inventory_id = v_order.inventory_id
    FOR UPDATE;

    IF v_inv.current_stock_kg < v_order.quantity_kg THEN
        RAISE EXCEPTION 'Insufficient % stock to complete delivery.', v_inv.abaca_type
            USING ERRCODE = 'P0003',
                  DETAIL = jsonb_build_object(
                      'abaca_type', v_inv.abaca_type,
                      'available_kg', v_inv.current_stock_kg,
                      'requested_kg', v_order.quantity_kg
                  )::TEXT;
    END IF;

    v_effective_delivered_at := COALESCE(p_delivered_at, NOW());

    UPDATE public.inventory
    SET current_stock_kg = current_stock_kg - v_order.quantity_kg,
        last_updated = NOW()
    WHERE inventory_id = v_inv.inventory_id;

    INSERT INTO public.stock_outs (
        inventory_id,
        employee_id,
        delivery_id,
        order_id,
        quantity_kg,
        reason,
        notes,
        date
    ) VALUES (
        v_inv.inventory_id,
        p_actor_employee_id,
        v_delivery.delivery_id,
        v_order.order_id,
        v_order.quantity_kg,
        'released',
        COALESCE(p_notes, 'Auto-released on delivery completion.'),
        v_effective_delivered_at::DATE
    );

    UPDATE public.deliveries
    SET status = 'delivered',
        delivered_at = v_effective_delivered_at,
        notes = COALESCE(p_notes, notes)
    WHERE delivery_id = p_delivery_id
    RETURNING * INTO v_updated;

    UPDATE public.orders
    SET status = 'delivered'
    WHERE order_id = v_order.order_id;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        old_values,
        new_values
    ) VALUES (
        p_actor_employee_id,
        'delivery_completed',
        'delivery',
        p_delivery_id::TEXT,
        format('Completed delivery for order %s (%s kg of %s released).', v_order.order_id, v_order.quantity_kg, v_inv.abaca_type),
        jsonb_build_object('status', v_delivery.status),
        jsonb_build_object('status', v_updated.status, 'delivered_at', v_effective_delivered_at)
    );

    RETURN v_updated;
END;
$$;

-- ----------------------------------------------------------------------------
-- 8. rpc_record_payment
-- Validates stocked/delivered order state and prevents cumulative overpayment.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_record_payment(
    p_order_id UUID,
    p_employee_id UUID,
    p_amount_paid NUMERIC,
    p_payment_date DATE,
    p_payment_method VARCHAR,
    p_reference_number VARCHAR,
    p_notes TEXT
)
RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_existing_paid NUMERIC(12, 2);
    v_amount NUMERIC(12, 2);
    v_created public.payments%ROWTYPE;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'accountant') THEN
            RAISE EXCEPTION 'Only active managers or accountants can record payments.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    v_amount := ROUND(p_amount_paid, 2);
    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero.'
            USING ERRCODE = 'P0005';
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found.', p_order_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'entity_id', p_order_id::TEXT
                  )::TEXT;
    END IF;

    IF v_order.status NOT IN ('stocked', 'delivered') THEN
        RAISE EXCEPTION 'Payments can only be recorded for stocked or delivered orders.'
            USING ERRCODE = 'P0004',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Order',
                      'current_state', v_order.status,
                      'attempted_action', 'record_payment'
                  )::TEXT;
    END IF;

    SELECT COALESCE(SUM(amount_paid), 0.00) INTO v_existing_paid
    FROM public.payments
    WHERE order_id = p_order_id;

    IF v_existing_paid + v_amount > v_order.total_amount THEN
        RAISE EXCEPTION 'Payment exceeds remaining balance (paid: %, order total: %).', v_existing_paid, v_order.total_amount
            USING ERRCODE = 'P0005';
    END IF;

    INSERT INTO public.payments (
        order_id,
        employee_id,
        amount_paid,
        payment_date,
        payment_method,
        reference_number,
        notes
    ) VALUES (
        p_order_id,
        p_employee_id,
        v_amount,
        p_payment_date,
        p_payment_method,
        p_reference_number,
        p_notes
    )
    RETURNING * INTO v_created;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        new_values
    ) VALUES (
        p_employee_id,
        'payment_recorded',
        'payment',
        v_created.payment_id::TEXT,
        format('Recorded %s payment of %s against order %s.', p_payment_method, v_amount, p_order_id),
        to_jsonb(v_created)
    );

    RETURN v_created;
END;
$$;

-- ----------------------------------------------------------------------------
-- 9. rpc_void_payment
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_void_payment(
    p_payment_id UUID,
    p_order_id UUID,
    p_actor_employee_id UUID,
    p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_payment public.payments%ROWTYPE;
    v_caller_role TEXT;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_caller_role
        FROM public.employees
        WHERE employee_id = auth.uid() AND is_active = TRUE;

        IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'accountant') THEN
            RAISE EXCEPTION 'Only active managers or accountants can void payments.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_payment
    FROM public.payments
    WHERE payment_id = p_payment_id
      AND order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment % not found for order %.', p_payment_id, p_order_id
            USING ERRCODE = 'P0002',
                  DETAIL = jsonb_build_object(
                      'entity_name', 'Payment',
                      'entity_id', p_payment_id::TEXT
                  )::TEXT;
    END IF;

    DELETE FROM public.payments
    WHERE payment_id = p_payment_id;

    INSERT INTO public.activity_logs (
        actor_employee_id,
        action,
        entity_type,
        entity_id,
        description,
        old_values
    ) VALUES (
        p_actor_employee_id,
        'payment_voided',
        'payment',
        p_payment_id::TEXT,
        COALESCE(NULLIF(TRIM(p_reason), ''), 'Voided payment entry.'),
        to_jsonb(v_payment)
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 10. rpc_get_financial_summary (read-only SQL aggregate summary)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_financial_summary(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_total_order_value NUMERIC(14, 2);
    v_total_payments_collected NUMERIC(14, 2);
    v_total_receivables NUMERIC(14, 2);
    v_total_stock_in_cost NUMERIC(14, 2);
    v_total_expenses NUMERIC(14, 2);
BEGIN
    SELECT COALESCE(SUM(o.total_amount), 0.00)
    INTO v_total_order_value
    FROM public.orders o
    WHERE o.status <> 'cancelled'
      AND (p_start_date IS NULL OR o.order_date >= p_start_date)
      AND (p_end_date IS NULL OR o.order_date <= p_end_date);

    SELECT COALESCE(SUM(p.amount_paid), 0.00)
    INTO v_total_payments_collected
    FROM public.payments p
    WHERE (p_start_date IS NULL OR p.payment_date >= p_start_date)
      AND (p_end_date IS NULL OR p.payment_date <= p_end_date);

    SELECT COALESCE(SUM(GREATEST(0.00, o.total_amount - COALESCE(paid.sum_paid, 0.00))), 0.00)
    INTO v_total_receivables
    FROM public.orders o
    LEFT JOIN (
        SELECT order_id, SUM(amount_paid) AS sum_paid
        FROM public.payments
        GROUP BY order_id
    ) paid ON paid.order_id = o.order_id
    WHERE o.status <> 'cancelled'
      AND (p_start_date IS NULL OR o.order_date >= p_start_date)
      AND (p_end_date IS NULL OR o.order_date <= p_end_date);

    SELECT COALESCE(SUM(ROUND(sii.quantity_kg * sii.cost_per_kg, 2)), 0.00)
    INTO v_total_stock_in_cost
    FROM public.stock_in_items sii
    JOIN public.stock_ins si ON si.stockin_id = sii.stockin_id
    WHERE (p_start_date IS NULL OR si.date_received >= p_start_date)
      AND (p_end_date IS NULL OR si.date_received <= p_end_date);

    SELECT COALESCE(SUM(e.amount), 0.00)
    INTO v_total_expenses
    FROM public.expenses e
    WHERE (p_start_date IS NULL OR e.date >= p_start_date)
      AND (p_end_date IS NULL OR e.date <= p_end_date);

    RETURN jsonb_build_object(
        'total_order_value', v_total_order_value,
        'total_payments_collected', v_total_payments_collected,
        'total_receivables', v_total_receivables,
        'total_stock_in_purchase_cost', v_total_stock_in_cost,
        'total_operational_expenses', v_total_expenses
    );
END;
$$;
