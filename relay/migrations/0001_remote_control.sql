PRAGMA foreign_keys = ON;

CREATE TABLE environments (
    id TEXT PRIMARY KEY,
    mac_name TEXT NOT NULL,
    app_version TEXT NOT NULL,
    secret_hash TEXT NOT NULL UNIQUE,
    push_alerts INTEGER NOT NULL DEFAULT 1,
    push_presence INTEGER NOT NULL DEFAULT 1,
    push_commands INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);

CREATE TABLE pairings (
    id TEXT PRIMARY KEY,
    environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'owner')),
    expires_at TEXT NOT NULL,
    used_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE members (
    id TEXT PRIMARY KEY,
    environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'owner')),
    created_at TEXT NOT NULL,
    last_seen_at TEXT
);
CREATE INDEX members_environment ON members(environment_id);

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ios', 'android', 'unknown')),
    push_token TEXT UNIQUE,
    notify_alerts INTEGER NOT NULL DEFAULT 1,
    notify_presence INTEGER NOT NULL DEFAULT 1,
    notify_commands INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    last_seen_at TEXT
);
CREATE INDEX devices_member ON devices(member_id);

CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    access_hash TEXT NOT NULL UNIQUE,
    access_expires_at TEXT NOT NULL,
    refresh_hash TEXT NOT NULL UNIQUE,
    refresh_expires_at TEXT NOT NULL,
    revoked_at TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT
);
CREATE INDEX sessions_member ON sessions(member_id, revoked_at);

CREATE TABLE websocket_tickets (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
    principal_id TEXT NOT NULL,
    client_kind TEXT NOT NULL CHECK (client_kind IN ('mac', 'mobile')),
    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'owner')),
    expires_at TEXT NOT NULL,
    used_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE audit_events (
    id TEXT PRIMARY KEY,
    environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
    member_id TEXT,
    actor_name TEXT NOT NULL,
    action_id TEXT NOT NULL,
    risk TEXT NOT NULL CHECK (risk IN ('read_only', 'mutation', 'sensitive', 'destructive')),
    outcome TEXT NOT NULL,
    error_code TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX audit_environment_time ON audit_events(environment_id, created_at DESC);

CREATE TABLE push_tickets (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    push_token TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_check_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX push_tickets_due ON push_tickets(next_check_at);
