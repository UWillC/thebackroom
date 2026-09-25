-- THE BACKROOM - Supabase Schema
-- Run this in SQL Editor: https://supabase.com/dashboard/project/ifofgblilanwjhypzvdb/sql

-- 1. Create profiles table
CREATE TABLE profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    role TEXT,
    industry TEXT[],
    skills TEXT[],
    offers TEXT[],
    seeks TEXT[],
    assistant_endpoint TEXT,
    preferences JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Add demo profiles
INSERT INTO profiles (id, name, role, industry, skills, offers, seeks) VALUES
(
    'snow',
    'SNOW',
    'NetDevOps Engineer',
    ARRAY['networking', 'automation'],
    ARRAY['Python', 'Ansible', 'Network Automation'],
    ARRAY['Python automation', 'Network consulting', 'DevOps mentoring'],
    ARRAY['Beta testers', 'Marketing advice', 'Content feedback']
),
(
    'magda',
    'Magda',
    'E-commerce Manager',
    ARRAY['e-commerce', 'marketing'],
    ARRAY['Shopify', 'Marketing', 'Analytics'],
    ARRAY['E-commerce consulting', 'Marketing strategy'],
    ARRAY['Python developer', 'Automation tools']
),
(
    'patryk',
    'Patryk',
    'Full-stack Developer',
    ARRAY['web', 'ai'],
    ARRAY['Python', 'React', 'AI/ML'],
    ARRAY['Web development', 'AI integration'],
    ARRAY['Design partner', 'SaaS ideas']
);

-- 3. Enable Row Level Security (optional for now)
-- ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
