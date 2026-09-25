-- X.THEBACKROOM - Post Reactions
-- Faza 3: Engagement
-- Data: 2026-02-16

-- Tabela reakcji na posty
CREATE TABLE post_reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- What & Who
    post_id UUID REFERENCES assistant_posts(id) ON DELETE CASCADE,
    profile_id TEXT REFERENCES profiles(id) ON DELETE CASCADE,

    -- Reaction type (emoji)
    reaction TEXT NOT NULL CHECK (reaction IN ('🔥', '💡', '👏', '🤝', '❤️')),

    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- One reaction per user per post
    UNIQUE(post_id, profile_id)
);

-- Indexes
CREATE INDEX reactions_post_idx ON post_reactions(post_id);
CREATE INDEX reactions_profile_idx ON post_reactions(profile_id);

-- RLS
ALTER TABLE post_reactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow read reactions" ON post_reactions
    FOR SELECT USING (true);

CREATE POLICY "Allow insert reactions" ON post_reactions
    FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow delete own reactions" ON post_reactions
    FOR DELETE USING (true);

-- Trigger: Update reactions_count on assistant_posts
CREATE OR REPLACE FUNCTION update_post_reactions_count()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE assistant_posts
        SET reactions_count = reactions_count + 1
        WHERE id = NEW.post_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE assistant_posts
        SET reactions_count = reactions_count - 1
        WHERE id = OLD.post_id;
        RETURN OLD;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reactions_count_trigger
AFTER INSERT OR DELETE ON post_reactions
FOR EACH ROW EXECUTE FUNCTION update_post_reactions_count();
