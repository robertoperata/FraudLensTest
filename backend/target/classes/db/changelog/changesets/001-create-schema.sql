--liquibase formatted sql

--changeset fraudlens:001-create-sessions
CREATE TABLE IF NOT EXISTS sessions (
    id          VARCHAR(255) PRIMARY KEY,
    user_id     VARCHAR(255) NOT NULL,
    ip          VARCHAR(45)  NOT NULL,
    country     VARCHAR(2)   NOT NULL,
    device      VARCHAR(255) NOT NULL,
    timestamp   VARCHAR(50)  NOT NULL,
    status      VARCHAR(20)  NOT NULL
);

--changeset fraudlens:001-create-events
CREATE TABLE IF NOT EXISTS events (
    id          VARCHAR(255) PRIMARY KEY,
    session_id  VARCHAR(255) NOT NULL,
    type        VARCHAR(50)  NOT NULL,
    url         VARCHAR(2048) NOT NULL,
    duration_ms BIGINT       NOT NULL,
    metadata    TEXT,
    CONSTRAINT fk_session FOREIGN KEY (session_id)
        REFERENCES sessions(id) ON DELETE CASCADE
);

--changeset fraudlens:001-create-users
CREATE TABLE IF NOT EXISTS users (
    id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username VARCHAR(255) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    role     VARCHAR(50)  NOT NULL
);
