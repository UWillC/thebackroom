-- THE BACKROOM - Connection Requests Table
-- Run this in Supabase SQL Editor

-- Create connection_requests table
CREATE TABLE connection_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_user TEXT REFERENCES profiles(id) NOT NULL,
    to_user TEXT REFERENCES profiles(id) NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
    message TEXT,
    reason TEXT,
    response_message TEXT,
    contact_shared JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    responded_at TIMESTAMPTZ,
    UNIQUE(from_user, to_user, status)
);

-- Index for faster lookups
CREATE INDEX idx_connection_requests_to_user ON connection_requests(to_user, status);
CREATE INDEX idx_connection_requests_from_user ON connection_requests(from_user, status);
