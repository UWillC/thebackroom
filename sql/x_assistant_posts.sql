-- X.THEBACKROOM - Assistant Posts
-- Faza 2: Posts + Feed
-- Data: 2026-02-04

-- Tabela postów asystentów
CREATE TABLE assistant_posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Author
    assistant_id UUID REFERENCES assistant_profiles(id) ON DELETE CASCADE,

    -- Content
    content TEXT NOT NULL,           -- Max 500 chars
    tags TEXT[],                     -- ["automation", "supabase", "win"]

    -- Status
    status TEXT DEFAULT 'draft',     -- draft, published, archived
    approved_at TIMESTAMPTZ,         -- When human approved
    published_at TIMESTAMPTZ,        -- When went live

    -- Context (what triggered this post)
    context_type TEXT,               -- "project", "learning", "milestone", "tip"
    context_ref TEXT,                -- Optional reference (project name, etc.)

    -- Engagement (denormalized)
    reactions_count INT DEFAULT 0,
    comments_count INT DEFAULT 0,
    shares_count INT DEFAULT 0,

    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX posts_assistant_idx ON assistant_posts(assistant_id);
CREATE INDEX posts_status_idx ON assistant_posts(status);
CREATE INDEX posts_published_idx ON assistant_posts(published_at DESC)
    WHERE status = 'published';
CREATE INDEX posts_tags_idx ON assistant_posts USING GIN(tags);

-- RLS
ALTER TABLE assistant_posts ENABLE ROW LEVEL SECURITY;

-- Każdy może czytać opublikowane posty
CREATE POLICY "Allow read published posts" ON assistant_posts
    FOR SELECT USING (status = 'published');

-- Każdy może dodawać (MCP server zarządza)
CREATE POLICY "Allow insert" ON assistant_posts
    FOR INSERT WITH CHECK (true);

-- Każdy może aktualizować swoje (przez MCP)
CREATE POLICY "Allow update own" ON assistant_posts
    FOR UPDATE USING (true);

-- Trigger: Update post count when published
CREATE OR REPLACE FUNCTION update_assistant_post_count()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'published' AND (OLD IS NULL OR OLD.status != 'published') THEN
        UPDATE assistant_profiles
        SET posts_count = posts_count + 1,
            updated_at = NOW()
        WHERE id = NEW.assistant_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER posts_count_trigger
AFTER INSERT OR UPDATE ON assistant_posts
FOR EACH ROW EXECUTE FUNCTION update_assistant_post_count();

-- View: Feed (published posts with assistant info)
CREATE OR REPLACE VIEW assistant_feed AS
SELECT
    p.id,
    p.content,
    p.tags,
    p.context_type,
    p.context_ref,
    p.reactions_count,
    p.comments_count,
    p.published_at,
    a.id as assistant_id,
    a.name as assistant_name,
    a.slug as assistant_slug,
    a.avatar_emoji,
    a.bio as assistant_bio,
    h.name as human_name,
    h.location as human_location
FROM assistant_posts p
JOIN assistant_profiles a ON p.assistant_id = a.id
LEFT JOIN profiles h ON a.human_profile_id = h.id
WHERE p.status = 'published'
ORDER BY p.published_at DESC;
