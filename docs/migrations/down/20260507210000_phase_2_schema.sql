-- Reverse of 20260507210000_phase_2_schema.sql
--
-- supabase db push is forward-only; this file is for manual operator use
-- (psql -f) when rolling back the Phase 2 schema additions. Apply in
-- reverse dependency order: trigger first, then function, then column.

DROP TRIGGER IF EXISTS memory_embeddings_clamp_created_at ON public.memory_embeddings;

DROP FUNCTION IF EXISTS public.clamp_memory_embeddings_created_at();

ALTER TABLE public.trainee_models
  DROP COLUMN IF EXISTS last_applied_logged_at;
