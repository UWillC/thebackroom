-- Security Sprint 3: Quick Fixes
-- Data: 2026-02-18
-- Effort: ~5 min

-- ============================================
-- 1. DROP DUPLICATE INDEX
-- ============================================
-- Problem: slug ma UNIQUE constraint (tworzy implicit index)
--          + explicit CREATE INDEX = duplikat
--
-- UWAGA: Wykonaj tylko jeśli index istnieje!

DROP INDEX IF EXISTS assistant_profiles_slug_idx;

-- Weryfikacja (sprawdź czy został tylko jeden index na slug):
-- SELECT indexname, indexdef
-- FROM pg_indexes
-- WHERE tablename = 'assistant_profiles';


-- ============================================
-- 2. RLS POLICIES REVIEW - assistant_profiles
-- ============================================
-- PROBLEM: Obecne policies używają "USING (true)" = każdy może wszystko
--
-- OBECNE (niebezpieczne):
--   "Allow public read" → FOR SELECT USING (true)  ← OK dla public profiles
--   "Allow insert" → FOR INSERT WITH CHECK (true)  ← ⚠️ każdy może dodać
--   "Allow update own" → FOR UPDATE USING (true)   ← ⚠️ każdy może edytować
--
-- DOCELOWE (Sprint 3 full):
--   SELECT → true (public read OK)
--   INSERT → auth.uid() = human_profile_id (tylko właściciel)
--   UPDATE → auth.uid() = human_profile_id (tylko właściciel)
--   DELETE → auth.uid() = human_profile_id (tylko właściciel)
--
-- ALE: wymaga Supabase Auth (Magic Link) → to osobne zadanie
--
-- TYMCZASOWE ROZWIĄZANIE (bez Auth):
-- Walidacja w MCP server (Python) zamiast RLS
-- Status: ✅ już zrobione w Sprint 1-2 (rate limiting, validation)


-- ============================================
-- 3. QUICK AUDIT: Tables with "USING (true)"
-- ============================================
-- Uruchom to w Supabase SQL Editor żeby zobaczyć wszystkie otwarte policies:
--
-- SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
-- FROM pg_policies
-- WHERE qual = 'true' OR qual IS NULL
-- ORDER BY tablename;
--
-- Oczekiwany wynik: ~18 policies z "true"
-- Wszystkie wymagają Auth żeby naprawić poprawnie


-- ============================================
-- PODSUMOWANIE
-- ============================================
-- ✅ DO WYKONANIA TERAZ:
--    - DROP INDEX assistant_profiles_slug_idx
--
-- ⏳ WYMAGA AUTH (marzec):
--    - RLS policies per-user
--    - Magic Link setup
--
-- ✅ JUŻ ZROBIONE (Sprint 1-2):
--    - Rate limiting (walidacja w MCP)
--    - Input validation (walidacja w MCP)
--    - Email verification

