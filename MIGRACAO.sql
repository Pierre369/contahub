-- ============================================
-- MIGRACAO.SQL - ContaHub Marketplace
-- Rodar no SQL Editor do Supabase
-- ============================================

-- ===== CONFIGURAÇÃO DO ADMIN =====
-- SUBSTITUA PELO SEU EMAIL DE DONO AQUI:
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean AS $$
DECLARE
  user_email text;
BEGIN
  user_email := auth.jwt()->>'email';
  RETURN user_email = 'SEU_EMAIL_AQUI@EXEMPLO.COM'; -- <-- COLOQUE SEU EMAIL AQUI
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ALTER TABLE orders: adicionar valor_item
-- ============================================
ALTER TABLE IF EXISTS public.orders 
ADD COLUMN IF NOT EXISTS valor_item numeric(10,2);

-- ============================================
-- CRIAR TABELAS NOVAS
-- ============================================

-- Reviews (avaliações de compradores)
CREATE TABLE IF NOT EXISTS public.reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid REFERENCES public.listings(id) ON DELETE CASCADE,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  reviewer uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  nota int CHECK (nota >= 1 AND nota <= 5),
  texto text,
  created_at timestamptz DEFAULT now()
);

-- Disputas (comprador abre disputa em pedido)
CREATE TABLE IF NOT EXISTS public.disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  buyer uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  motivo text,
  status text DEFAULT 'aberta' CHECK (status IN ('aberta', 'resolvida', 'reembolsada')),
  created_at timestamptz DEFAULT now()
);

-- Reports (denúncias de anúncios)
CREATE TABLE IF NOT EXISTS public.reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid REFERENCES public.listings(id) ON DELETE CASCADE,
  reporter uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  motivo text,
  status text DEFAULT 'aberto' CHECK (status IN ('aberto', 'resolvido', 'removido')),
  created_at timestamptz DEFAULT now()
);

-- ============================================
-- DROP TRIGGER ANTIGO (credita_venda)
-- ============================================
DROP TRIGGER IF EXISTS credita_venda ON public.orders;
DROP FUNCTION IF EXISTS public.credita_venda_trigger();

-- ============================================
-- TRIGGER A: AFTER INSERT em orders → listings.status='vendido'
-- ============================================
CREATE OR REPLACE FUNCTION public.trigger_order_insert()
RETURNS trigger AS $$
BEGIN
  IF NEW.listing_id IS NOT NULL THEN
    UPDATE public.listings 
    SET status = 'vendido' 
    WHERE id = NEW.listing_id AND status = 'ativo';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_insert
AFTER INSERT ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.trigger_order_insert();

-- ============================================
-- TRIGGER B: AFTER UPDATE orders status='entregue' → creditar seller (90%)
-- ============================================
CREATE OR REPLACE FUNCTION public.trigger_order_entregue()
RETURNS trigger AS $$
DECLARE
  seller_id uuid;
  valor_credito numeric;
BEGIN
  -- Só processa se mudou para 'entregue'
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'entregue' AND NEW.listing_id IS NOT NULL THEN
    -- Buscar seller da listing
    SELECT seller INTO seller_id FROM public.listings WHERE id = NEW.listing_id;
    
    IF seller_id IS NOT NULL THEN
      -- Calcular 90% do valor_item
      valor_credito := COALESCE(NEW.valor_item, 0) * 0.9;
      
      -- Creditar na conta do seller
      UPDATE public.profiles 
      SET saldo = COALESCE(saldo, 0) + valor_credito
      WHERE id = seller_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_entregue
AFTER UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.trigger_order_entregue();

-- ============================================
-- TRIGGER C: status='reembolsado' → listing volta para 'ativo'
-- ============================================
CREATE OR REPLACE FUNCTION public.trigger_order_reembolso()
RETURNS trigger AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'reembolsado' AND NEW.listing_id IS NOT NULL THEN
    UPDATE public.listings 
    SET status = 'ativo' 
    WHERE id = NEW.listing_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_reembolso
AFTER UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.trigger_order_reembolso();

-- ============================================
-- RLS (Row Level Security)
-- ============================================

-- Habilitar RLS nas tabelas novas
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

-- ===== REVIEWS =====
-- Insert: usuário autenticado pode criar review
CREATE POLICY reviews_insert_auth ON public.reviews
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = reviewer);

-- Select: público pode ver reviews
CREATE POLICY reviews_select_public ON public.reviews
  FOR SELECT TO public
  USING (true);

-- ===== DISPUTES =====
-- Insert: buyer pode abrir disputa do seu pedido
CREATE POLICY disputes_insert_buyer ON public.disputes
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = buyer);

-- Select: buyer vê suas disputas, admin vê tudo
CREATE POLICY disputes_select_own ON public.disputes
  FOR SELECT TO authenticated
  USING (auth.uid() = buyer OR public.is_admin());

-- Admin pode atualizar disputas
CREATE POLICY disputes_admin_update ON public.disputes
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ===== REPORTS =====
-- Insert: autenticado pode denunciar
CREATE POLICY reports_insert_auth ON public.reports
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = reporter);

-- Select: admin vê todas denúncias
CREATE POLICY reports_select_admin ON public.reports
  FOR SELECT TO authenticated
  USING (public.is_admin());

-- Admin pode atualizar reports
CREATE POLICY reports_admin_update ON public.reports
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ===== ORDERS =====
-- Buyer pode atualizar status dos próprios pedidos para 'entregue' ou 'disputa'
CREATE POLICY orders_buyer_update_status ON public.orders
  FOR UPDATE TO authenticated
  USING (auth.uid() = buyer AND status IN ('pago', 'pendente'))
  WITH CHECK (status IN ('pago', 'pendente', 'entregue', 'disputa'));

-- Admin pode selecionar e atualizar tudo em orders
CREATE POLICY orders_admin_all ON public.orders
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ===== WITHDRAWALS =====
-- Admin pode selecionar e atualizar withdrawals
CREATE POLICY withdrawals_admin_all ON public.withdrawals
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ===== LISTINGS =====
-- Admin pode remover/editar qualquer listing
CREATE POLICY listings_admin_all ON public.listings
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================
CREATE INDEX IF NOT EXISTS idx_reviews_listing ON public.reviews(listing_id);
CREATE INDEX IF NOT EXISTS idx_disputes_order ON public.disputes(order_id);
CREATE INDEX IF NOT EXISTS idx_reports_listing ON public.reports(listing_id);
CREATE INDEX IF NOT EXISTS idx_orders_listing ON public.orders(listing_id);
