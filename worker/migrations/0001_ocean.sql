-- Slack Water ocean schema, initial migration.
--
-- The reference tables (species, species_run_months, habitat_affinity) are
-- seeded from ../src/Shared/Species.luau and the adjacency matrix in
-- OceanSim.luau's habitatAffinity. They exist as data (not hardcoded SQL
-- expressions) so the tick's single-statement UPDATE can recompute effective
-- capacity for every stock atomically, in one transaction.
--
-- The seed arithmetic (0.82·K biomass) and the capacity expression below are
-- the SQL rendering of OceanSim.addRegion/effectiveCapacity; the integration
-- test pins them against the TypeScript port of the same math.

--=============================================================================
-- Reference data
--=============================================================================

CREATE TABLE species (
  id            TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  habitat       TEXT NOT NULL CHECK (habitat IN ('kelp','reef','sand','mud','open','estuary')),
  min_depth     REAL NOT NULL CHECK (min_depth >= 0),
  max_depth     REAL NOT NULL CHECK (max_depth > min_depth),
  base_capacity REAL NOT NULL CHECK (base_capacity > 0),
  growth_rate   REAL NOT NULL CHECK (growth_rate >= 0),
  base_value    REAL NOT NULL CHECK (base_value > 0),
  anadromous    INTEGER NOT NULL CHECK (anadromous IN (0, 1)),
  run_strength  REAL NOT NULL DEFAULT 0,
  rarity        REAL NOT NULL CHECK (rarity > 0 AND rarity <= 1)
);

INSERT INTO species (id, display_name, habitat, min_depth, max_depth, base_capacity, growth_rate, base_value, anadromous, run_strength, rarity) VALUES
  ('chinook',   'Chinook Salmon',    'open',     30, 300,  900, 0.09,  220, 1, 1.0,  0.18),
  ('coho',      'Coho Salmon',       'open',     20, 200, 1100, 0.11,  120, 1, 0.85, 0.26),
  ('sockeye',   'Sockeye Salmon',    'open',    100, 320,  800, 0.10,   95, 1, 0.90, 0.28),
  ('pink',      'Pink Salmon',       'estuary',   5, 120, 2400, 0.16,   40, 1, 1.35, 0.42),
  ('chum',      'Chum Salmon',       'estuary',  10, 180, 1300, 0.12,   60, 1, 0.80, 0.34),
  ('halibut',   'Pacific Halibut',   'sand',    200, 900,  420, 0.045, 460, 0, 0,    0.12),
  ('sablefish', 'Sablefish',         'mud',     300, 800,  380, 0.04,  340, 0, 0,    0.15),
  ('cod',       'Pacific Cod',       'mud',      90, 300,  950, 0.07,  130, 0, 0,    0.30),
  ('pollock',   'Alaska Pollock',    'open',     80, 300, 1800, 0.14,   55, 0, 0,    0.44),
  ('lingcod',   'Lingcod',           'reef',     90, 300,  620, 0.06,  175, 0, 0,    0.22),
  ('rockfish',  'Black Rockfish',    'reef',     25, 120, 1100, 0.08,  145, 0, 0,    0.32),
  ('yelloweye', 'Yelloweye Rockfish','reef',     40, 180,  300, 0.035, 395, 0, 0,    0.11),
  ('herring',   'Pacific Herring',   'kelp',     15, 110, 2600, 0.18,   30, 0, 0.60, 0.52),
  ('flounder',  'Starry Flounder',   'sand',     15, 150, 1200, 0.10,   75, 0, 0,    0.38),
  ('skate',     'Big Skate',         'sand',     60, 400,  480, 0.05,  210, 0, 0,    0.19),
  ('dungeness', 'Dungeness Crab',    'reef',     15, 200,  760, 0.07,  190, 0, 0,    0.24),
  ('kingcrab',  'Red King Crab',     'mud',     200, 500,  260, 0.03,  580, 0, 0,    0.09);

CREATE TABLE species_run_months (
  species_id TEXT NOT NULL REFERENCES species(id),
  month      INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
  PRIMARY KEY (species_id, month)
);

INSERT INTO species_run_months (species_id, month) VALUES
  ('chinook', 3), ('chinook', 4), ('chinook', 5), ('chinook', 6),
  ('coho', 8), ('coho', 9), ('coho', 10),
  ('sockeye', 8), ('sockeye', 9), ('sockeye', 10),
  ('pink', 7), ('pink', 8), ('pink', 9),
  ('chum', 8), ('chum', 9), ('chum', 10), ('chum', 11),
  ('herring', 3), ('herring', 4), ('herring', 5);

-- habitat_affinity[region_habitat][species_habitat], from OceanSim.luau's
-- adjacency matrix: matching habitat thrives (1.0), neighbours degrade.
CREATE TABLE habitat_affinity (
  region_habitat  TEXT NOT NULL CHECK (region_habitat IN ('kelp','reef','sand','mud','open','estuary')),
  species_habitat TEXT NOT NULL CHECK (species_habitat IN ('kelp','reef','sand','mud','open','estuary')),
  affinity        REAL NOT NULL CHECK (affinity > 0 AND affinity <= 1),
  PRIMARY KEY (region_habitat, species_habitat)
);

INSERT INTO habitat_affinity (region_habitat, species_habitat, affinity) VALUES
  ('open',    'open', 1.0), ('open',    'estuary', 0.6), ('open',    'kelp', 0.55), ('open',    'sand', 0.35), ('open',    'reef', 0.3),  ('open',    'mud', 0.25),
  ('estuary', 'estuary', 1.0), ('estuary', 'open', 0.6), ('estuary', 'kelp', 0.4),  ('estuary', 'sand', 0.45), ('estuary', 'reef', 0.25), ('estuary', 'mud', 0.5),
  ('kelp',    'kelp', 1.0),  ('kelp',    'open', 0.55), ('kelp',    'reef', 0.5),  ('kelp',    'estuary', 0.4), ('kelp',    'sand', 0.3), ('kelp',    'mud', 0.2),
  ('reef',    'reef', 1.0),  ('reef',    'kelp', 0.5),  ('reef',    'sand', 0.35), ('reef',    'open', 0.3),   ('reef',    'mud', 0.25),  ('reef',    'estuary', 0.25),
  ('sand',    'sand', 1.0),  ('sand',    'open', 0.35), ('sand',    'estuary', 0.45), ('sand',  'mud', 0.5),   ('sand',    'reef', 0.35), ('sand',    'kelp', 0.3),
  ('mud',     'mud', 1.0),   ('mud',     'open', 0.25), ('mud',     'sand', 0.5),  ('mud',     'reef', 0.25),  ('mud',     'estuary', 0.5), ('mud',   'kelp', 0.2);

--=============================================================================
-- The ocean
--=============================================================================

CREATE TABLE regions (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  habitat    TEXT NOT NULL CHECK (habitat IN ('kelp','reef','sand','mud','open','estuary')),
  depth      REAL NOT NULL CHECK (depth BETWEEN 5 AND 900),
  salinity   REAL NOT NULL CHECK (salinity BETWEEN 18 AND 36),
  richness   REAL NOT NULL CHECK (richness BETWEEN 0.5 AND 1.5),
  origin     TEXT NOT NULL DEFAULT 'procedural' CHECK (origin IN ('procedural','composed')),
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE region_stocks (
  region_id  TEXT NOT NULL REFERENCES regions(id),
  species_id TEXT NOT NULL,
  biomass    REAL NOT NULL CHECK (biomass >= 0),
  capacity   REAL NOT NULL CHECK (capacity >= 0),
  PRIMARY KEY (region_id, species_id)
);

-- Global abundance sums per species without scanning the whole PK.
CREATE INDEX idx_region_stocks_species ON region_stocks(species_id);

CREATE TABLE ocean_state (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  tick       INTEGER NOT NULL DEFAULT 0,
  month      INTEGER NOT NULL DEFAULT 1 CHECK (month BETWEEN 1 AND 12),
  day        INTEGER NOT NULL DEFAULT 1 CHECK (day BETWEEN 1 AND 4),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO ocean_state (id, tick, month, day) VALUES (1, 0, 1, 1);

-- One row per applied simulation tick; its PRIMARY KEY is what makes two
-- concurrent tick invocations safe (the loser's whole batch rolls back).
CREATE TABLE tick_log (
  tick     INTEGER PRIMARY KEY,
  ticked_at TEXT NOT NULL DEFAULT (datetime('now'))
);

--=============================================================================
-- Market
--=============================================================================

CREATE TABLE market_prices (
  species_id TEXT PRIMARY KEY REFERENCES species(id),
  price      REAL NOT NULL CHECK (price >= 0),
  abundance  REAL NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE market_price_history (
  species_id TEXT NOT NULL,
  price      REAL NOT NULL,
  abundance  REAL NOT NULL,
  recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_market_price_history_species ON market_price_history(species_id, recorded_at);

--=============================================================================
-- Banks (AI-composed content, validated before insert)
--=============================================================================

CREATE TABLE banks (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  habitat     TEXT NOT NULL CHECK (habitat IN ('kelp','reef','sand','mud','open','estuary')),
  depth       REAL NOT NULL CHECK (depth BETWEEN 5 AND 900),
  salinity    REAL NOT NULL CHECK (salinity BETWEEN 18 AND 36),
  richness    REAL NOT NULL CHECK (richness BETWEEN 0.5 AND 1.5),
  hazard      TEXT CHECK (hazard IS NULL OR hazard IN
    ('none','rip_current','rocky_bottom','deep_water','kelp_tangle','seabird_activity','debris_field','cold_drain')),
  species_mix TEXT NOT NULL, -- JSON: [{speciesId, weight}] with weights summing to 1
  origin      TEXT NOT NULL CHECK (origin IN ('procedural','composed')),
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

--=============================================================================
-- Catch log — append-only by force
--=============================================================================

CREATE TABLE catch_events (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id       TEXT NOT NULL,
  region_id        TEXT NOT NULL,
  species_id       TEXT NOT NULL,
  effort           REAL NOT NULL,
  yielded          REAL NOT NULL,
  abundance_before REAL NOT NULL,
  abundance_after  REAL NOT NULL,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_catch_events_region_time ON catch_events(region_id, created_at);
CREATE INDEX idx_catch_events_species_time ON catch_events(species_id, created_at);
CREATE INDEX idx_catch_events_request ON catch_events(request_id);

CREATE TRIGGER catch_events_no_update BEFORE UPDATE ON catch_events
BEGIN SELECT RAISE(ABORT, 'catch_events is append-only'); END;

CREATE TRIGGER catch_events_no_delete BEFORE DELETE ON catch_events
BEGIN SELECT RAISE(ABORT, 'catch_events is append-only'); END;

--=============================================================================
-- Idempotency ledger for harvests
--=============================================================================

-- A harvest request commits its computed response alongside its claim of the
-- requestId; a retry replays the stored response instead of re-fishing.
CREATE TABLE harvest_requests (
  request_id    TEXT PRIMARY KEY,
  payload_hash  TEXT NOT NULL,
  response_json TEXT NOT NULL,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

--=============================================================================
-- Seed ocean: one working ground per habitat, stocked to 0.82·K
-- (OceanSim.addRegion semantics: regions start healthy so there is somewhere
-- to fish before players have earned the right to deplete it).
--=============================================================================

INSERT INTO regions (id, name, habitat, depth, salinity, richness, origin) VALUES
  ('r_kelp_road',     'Kelp Road',      'kelp',     25, 32.0, 1.0, 'procedural'),
  ('r_saddle_reef',   'Saddle Reef',    'reef',     60, 33.0, 1.0, 'procedural'),
  ('r_flattop_sand',  'Flattop Sand',   'sand',    120, 33.0, 0.9, 'procedural'),
  ('r_nanaimo_mud',   'Nanaimo Mud',    'mud',     350, 34.0, 1.0, 'procedural'),
  ('r_georgia_open',  'Georgia Open',   'open',    200, 32.0, 1.0, 'procedural'),
  ('r_skeena_estuary','Skeena Estuary', 'estuary',  15, 24.0, 1.1, 'procedural');

INSERT INTO region_stocks (region_id, species_id, biomass, capacity)
SELECT f.region_id, f.species_id, f.cap * 0.82, f.cap
FROM (
  SELECT r.id AS region_id, sp.id AS species_id,
    sp.base_capacity * r.richness
      * ha.affinity
      * (CASE WHEN r.depth >= sp.min_depth AND r.depth <= sp.max_depth THEN 1.0 ELSE 0.15 END)
      * (1.0
         + CASE WHEN ha.affinity * (CASE WHEN r.depth >= sp.min_depth AND r.depth <= sp.max_depth THEN 1.0 ELSE 0.15 END) >= 0.95 THEN 0.35 ELSE 0.0 END
         -- Gated on the PRESENCE OF A RUN WINDOW, not on `anadromous`.
         -- Pacific herring aggregate to spawn in spring but never return to
         -- freshwater, so they carry run months with anadromous = 0. Gating on
         -- anadromous meant their spring run never fired. Keep this in step
         -- with OceanSim.luau effectiveCapacity and worker/src/ocean.ts.
         + CASE WHEN EXISTS (
             SELECT 1 FROM species_run_months m WHERE m.species_id = sp.id AND m.month = 1
           ) THEN 0.85 * sp.run_strength ELSE 0.0 END) AS cap
  FROM regions r
  CROSS JOIN species sp
  JOIN habitat_affinity ha ON ha.region_habitat = r.habitat AND ha.species_habitat = sp.habitat
) f;

-- Prices start at base value against the seeded 0.82 abundance; the first
-- /market read steps them toward the scarcity target.
INSERT INTO market_prices (species_id, price, abundance, updated_at)
SELECT id, base_value, 0.82, datetime('now') FROM species;
