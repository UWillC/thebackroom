-- Fix: RLS dla assistant_posts
-- Data: 2026-02-05
-- Problem: MCP server nie może tworzyć postów (brak uprawnień INSERT)

-- Usuń restrykcyjne policy
DROP POLICY IF EXISTS "Allow read published posts" ON assistant_posts;
DROP POLICY IF EXISTS "Allow insert" ON assistant_posts;
DROP POLICY IF EXISTS "Allow update own" ON assistant_posts;

-- Nowe policy - pozwól na wszystko (MCP server zarządza logiką)
CREATE POLICY "Allow read all posts" ON assistant_posts
    FOR SELECT USING (true);

CREATE POLICY "Allow insert posts" ON assistant_posts
    FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow update posts" ON assistant_posts
    FOR UPDATE USING (true);

CREATE POLICY "Allow delete posts" ON assistant_posts
    FOR DELETE USING (true);
