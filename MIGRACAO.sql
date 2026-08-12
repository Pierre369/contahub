-- ============================================
-- MIGRACAO.SQL - ContaHub Marketplace - FASE 1
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
  -- IMPORTANTE: Troque 'admin@contahub.com.br' pelo seu email real
  RETURN user_email = 'admin@contahub.com.br';
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
    SELECT user_id INTO seller_id FROM public.listings WHERE id = NEW.listing_id;
    
    IF seller_id IS NOT NULL THEN
      -- Calcular 90% do valor_item
      valor_credito := COALESCE(NEW.valor_item, 0) * 0.9;
      
      -- Creditar na conta do seller
      UPDATE public.profiles 
      SET saldo = COALESCE(saldo, 0) + valor_credito,
          updated_at = now()
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
-- Select: usuário vê seus próprios pedidos ou se for seller da listing, admin vê tudo
DROP POLICY IF EXISTS orders_select_own_or_admin ON public.orders;
CREATE POLICY orders_select_own_or_admin ON public.orders
  FOR SELECT TO authenticated
  USING (
    auth.uid() = buyer_id 
    OR auth.uid() IN (SELECT user_id FROM public.listings WHERE id = orders.listing_id)
    OR public.is_admin()
  );

-- Insert: apenas usuário autenticado pode criar pedido (como comprador)
DROP POLICY IF EXISTS orders_insert_auth ON public.orders;
CREATE POLICY orders_insert_auth ON public.orders
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = buyer_id);

-- Update: comprador pode mudar para 'entregue' ou 'disputa', admin pode tudo
DROP POLICY IF EXISTS orders_update_buyer_or_admin ON public.orders;
CREATE POLICY orders_update_buyer_or_admin ON public.orders
  FOR UPDATE TO authenticated
  USING (
    (auth.uid() = buyer_id AND NEW.status IN ('entregue', 'disputa'))
    OR public.is_admin()
  )
  WITH CHECK (
    (auth.uid() = buyer_id AND NEW.status IN ('entregue', 'disputa'))
    OR public.is_admin()
  );

-- ===== WITHDRAWALS =====
-- Select: usuário vê seus saques, admin vê tudo
DROP POLICY IF EXISTS withdrawals_select_own_or_admin ON public.withdrawals;
CREATE POLICY withdrawals_select_own_or_admin ON public.withdrawals
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id OR public.is_admin());

-- Insert: apenas usuário autenticado pode solicitar saque
DROP POLICY IF EXISTS withdrawals_insert_auth ON public.withdrawals;
CREATE POLICY withdrawals_insert_auth ON public.withdrawals
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Update: apenas admin pode atualizar status de saques
DROP POLICY IF EXISTS withdrawals_update_admin ON public.withdrawals;
CREATE POLICY withdrawals_update_admin ON public.withdrawals
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ===== LISTINGS =====
-- Select: todos podem ver anúncios ativos, admin vê tudo
DROP POLICY IF EXISTS listings_select_active_or_admin ON public.listings;
CREATE POLICY listings_select_active_or_admin ON public.listings
  FOR SELECT TO public
  USING (status = 'ativo' OR public.is_admin());

-- Insert: apenas usuários autenticados podem criar anúncios
DROP POLICY IF EXISTS listings_insert_auth ON public.listings;
CREATE POLICY listings_insert_auth ON public.listings
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Update: dono pode editar se não estiver vendido, admin pode tudo
DROP POLICY IF EXISTS listings_update_owner_or_admin ON public.listings;
CREATE POLICY listings_update_owner_or_admin ON public.listings
  FOR UPDATE TO authenticated
  USING (
    (auth.uid() = user_id AND status != 'vendido')
    OR public.is_admin()
  )
  WITH CHECK (
    (auth.uid() = user_id AND status != 'vendido')
    OR public.is_admin()
  );

-- Delete: apenas admin pode remover anúncios
DROP POLICY IF EXISTS listings_delete_admin ON public.listings;
CREATE POLICY listings_delete_admin ON public.listings
  FOR DELETE TO authenticated
  USING (public.is_admin());

-- ===== PROFILES =====
-- Select: público pode ver perfis básicos
DROP POLICY IF EXISTS profiles_select_public ON public.profiles;
CREATE POLICY profiles_select_public ON public.profiles
  FOR SELECT TO public
  USING (true);

-- Update: usuário pode atualizar seu próprio perfil, admin pode tudo
DROP POLICY IF EXISTS profiles_update_own_or_admin ON public.profiles;
CREATE POLICY profiles_update_own_or_admin ON public.profiles
  FOR UPDATE TO authenticated
  USING (auth.uid() = id OR public.is_admin())
  WITH CHECK (auth.uid() = id OR public.is_admin());

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================
CREATE INDEX IF NOT EXISTS idx_reviews_listing ON public.reviews(listing_id);
CREATE INDEX IF NOT EXISTS idx_reviews_reviewer ON public.reviews(reviewer);
CREATE INDEX IF NOT EXISTS idx_disputes_order ON public.disputes(order_id);
CREATE INDEX IF NOT EXISTS idx_disputes_buyer ON public.disputes(buyer);
CREATE INDEX IF NOT EXISTS idx_reports_listing ON public.reports(listing_id);
CREATE INDEX IF NOT EXISTS idx_reports_reporter ON public.reports(reporter);
CREATE INDEX IF NOT EXISTS idx_orders_listing ON public.orders(listing_id);

-- ============================================================================
-- FUNÇÕES AUXILIARES PARA O FRONTEND
-- ============================================================================

-- Função para calcular média de avaliações de uma listing
CREATE OR REPLACE FUNCTION public.get_listing_rating(p_listing_id uuid)
RETURNS TABLE (
  media_nota numeric,
  total_avaliacoes bigint
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COALESCE(AVG(r.nota), 0)::numeric AS media_nota,
    COUNT(*)::bigint AS total_avaliacoes
  FROM public.reviews r
  WHERE r.listing_id = p_listing_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Função para obter estatísticas do vendedor
CREATE OR REPLACE FUNCTION public.get_seller_stats(p_user_id uuid)
RETURNS TABLE (
  data_cadastro timestamptz,
  total_vendas_entregues bigint,
  media_avaliacoes numeric
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.criado_em AS data_cadastro,
    (
      SELECT COUNT(*) 
      FROM public.orders o
      JOIN public.listings l ON o.listing_id = l.id
      WHERE l.user_id = p_user_id 
        AND o.status = 'entregue'
    )::bigint AS total_vendas_entregues,
    (
      SELECT COALESCE(AVG(r.nota), 0)
      FROM public.reviews r
      JOIN public.listings l ON r.listing_id = l.id
      WHERE l.user_id = p_user_id
    )::numeric AS media_avaliacoes
  FROM public.profiles p
  WHERE p.id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Função para calcular saldo pendente do vendedor
CREATE OR REPLACE FUNCTION public.get_seller_pending_balance(p_user_id uuid)
RETURNS numeric AS $$
DECLARE
  pending numeric;
BEGIN
  SELECT COALESCE(SUM(o.valor_item * 0.90), 0)
  INTO pending
  FROM public.orders o
  JOIN public.listings l ON o.listing_id = l.id
  WHERE l.user_id = p_user_id
    AND o.status IN ('pago', 'disputa');
  
  RETURN pending;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Função para calcular receita total do admin (10% de comissão)
CREATE OR REPLACE FUNCTION public.get_admin_revenue()
RETURNS numeric AS $$
DECLARE
  revenue numeric;
BEGIN
  SELECT COALESCE(SUM(valor_item * 0.10), 0)
  INTO revenue
  FROM public.orders
  WHERE status = 'entregue';
  
  RETURN revenue;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- FIM DA MIGRAÇÃO - FASE 1
-- ============================================================================

DO $$
BEGIN
  RAISE NOTICE 'Migração ContaHub Fase 1 concluída com sucesso!';
  RAISE NOTICE 'IMPORTANTE: Substitua o email em is_admin() pelo seu email real antes de usar.';
END $$;
