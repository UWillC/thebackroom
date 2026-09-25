-- The Backroom: search_logs table
-- Faza 2: Analytics
-- Data: 2026-02-03

-- Tabela do logowania wyszukiwań
CREATE TABLE search_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query TEXT NOT NULL,
    results_count INT DEFAULT 0,
    user_id TEXT,  -- optional, profile_id jeśli zalogowany
    search_type TEXT DEFAULT 'general',  -- 'general', 'category', 'skills'
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexy dla analytics
CREATE INDEX search_logs_query_idx ON search_logs(query);
CREATE INDEX search_logs_created_idx ON search_logs(created_at DESC);
CREATE INDEX search_logs_type_idx ON search_logs(search_type);

-- RLS (public insert, admin read)
ALTER TABLE search_logs ENABLE ROW LEVEL SECURITY;

-- Każdy może dodawać logi (przez MCP)
CREATE POLICY "Allow insert" ON search_logs
    FOR INSERT WITH CHECK (true);

-- Tylko admin może czytać (na razie wyłączone - public read for analytics)
CREATE POLICY "Allow read" ON search_logs
    FOR SELECT USING (true);

-- View dla top searches (ostatnie 7 dni)
CREATE OR REPLACE VIEW top_searches_7d AS
SELECT
    query,
    COUNT(*) as search_count,
    AVG(results_count) as avg_results,
    MAX(created_at) as last_searched
FROM search_logs
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY query
ORDER BY search_count DESC
LIMIT 20;

-- View dla gap analysis (searches with 0 results)
CREATE OR REPLACE VIEW search_gaps AS
SELECT
    query,
    COUNT(*) as search_count,
    MAX(created_at) as last_searched
FROM search_logs
WHERE results_count = 0
  AND created_at > NOW() - INTERVAL '30 days'
GROUP BY query
ORDER BY search_count DESC
LIMIT 20;
