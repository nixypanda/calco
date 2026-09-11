ALTER TABLE identities
    ADD COLUMN session_security_stamp UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE identities
    ALTER COLUMN session_security_stamp DROP DEFAULT;

ALTER TABLE sessions
    ADD COLUMN identity_security_stamp UUID NOT NULL
        DEFAULT 'ffffffff-ffff-ffff-ffff-ffffffffffff';

ALTER TABLE sessions
    ALTER COLUMN identity_security_stamp DROP DEFAULT;
