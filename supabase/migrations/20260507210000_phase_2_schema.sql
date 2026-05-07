-- Phase 2 schema additions
--
-- ADR-0008: last_applied_logged_at watermark on trainee_models — gates
-- chronological session-apply ordering at the Edge Function tier.
-- ADR-0013: memory_embeddings.created_at server-side clamp — defends the
-- classifier-stage watermark against client clock skew.

ALTER TABLE public.trainee_models
  ADD COLUMN last_applied_logged_at TIMESTAMPTZ;

COMMENT ON COLUMN public.trainee_models.last_applied_logged_at IS
  'Watermark for chronological session-apply ordering per ADR-0008. Events with loggedAt < watermark are refused at the Edge Function tier (model not mutated, structured trainee_model.late_arrival event emitted, dedupe-table insert still records the event for idempotency). Nullable; populated on first watermark-checked apply.';

CREATE OR REPLACE FUNCTION public.clamp_memory_embeddings_created_at()
RETURNS TRIGGER AS $$
BEGIN
  -- Per ADR-0013: clamp client-provided created_at to LEAST(client, NOW())
  -- to defend against client clock skew advancing the classifier watermark
  -- beyond now and silently skipping subsequent notes.
  IF NEW.created_at > NOW() THEN
    NEW.created_at := NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER memory_embeddings_clamp_created_at
  BEFORE INSERT ON public.memory_embeddings
  FOR EACH ROW EXECUTE FUNCTION public.clamp_memory_embeddings_created_at();
