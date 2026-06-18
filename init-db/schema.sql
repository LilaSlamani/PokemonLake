-- ═══════════════════════════════════════════════════════════════════════════
-- PokemonLake — Schéma de base enrichie (Partie B)
-- Base : pokemon_lake
-- ═══════════════════════════════════════════════════════════════════════════


-- ── pokemon_files ────────────────────────────────────────────────────────────
-- Référence chaque fichier physique stocké dans MinIO.
-- La base ne stocke pas le fichier lui-même, seulement ses métadonnées
-- et un pointeur (object_key) vers l'objet dans le bucket.
CREATE TABLE IF NOT EXISTS pokemon_files (
    file_id         SERIAL          PRIMARY KEY,
    pokemon_id      INTEGER         NOT NULL,
    bucket_name     VARCHAR(100)    NOT NULL,
    object_key      VARCHAR(500)    NOT NULL,
    file_name       VARCHAR(255)    NOT NULL,
    file_type       VARCHAR(50)     NOT NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Colonnes enrichies
    file_size_bytes BIGINT,                 -- taille en octets
    mime_type       VARCHAR(100),           -- ex: application/json, image/png
    internal_url    TEXT,                   -- URL S3 interne (accès réseau Docker)
    checksum        VARCHAR(64),            -- SHA-256 pour vérification d'intégrité

    -- Garantit l'idempotence : un même objet ne peut être référencé deux fois
    UNIQUE (bucket_name, object_key)
);

COMMENT ON TABLE pokemon_files IS
    'Catalogue des fichiers stockés dans MinIO, liés à un Pokémon de la base.';


-- ── file_ingestion_log ───────────────────────────────────────────────────────
-- Journal de toutes les tentatives d'ingestion (succès et erreurs).
-- Permet de tracer l'historique complet des flux entrants.
CREATE TABLE IF NOT EXISTS file_ingestion_log (
    log_id          SERIAL          PRIMARY KEY,
    file_name       VARCHAR(255)    NOT NULL,
    bucket_name     VARCHAR(100)    NOT NULL,
    object_key      VARCHAR(500),
    processed_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    source          VARCHAR(100),           -- ex: pokeapi, n8n-workflow, manual
    status          VARCHAR(20)     NOT NULL CHECK (status IN ('success', 'error', 'pending')),

    -- Colonnes enrichies
    error_message   TEXT,                   -- message d'erreur si status = 'error'
    file_size_bytes BIGINT                  -- taille ingérée
);

COMMENT ON TABLE file_ingestion_log IS
    'Journal d ingestion : une ligne par tentative, succès ou échec inclus.';


-- ── Index de performance ─────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_pokemon_files_pokemon_id
    ON pokemon_files (pokemon_id);

CREATE INDEX IF NOT EXISTS idx_ingestion_log_status
    ON file_ingestion_log (status);

CREATE INDEX IF NOT EXISTS idx_ingestion_log_processed_at
    ON file_ingestion_log (processed_at DESC);
