-- =====================================================================
-- WhatsApp AI Receptionist — self-contained schema + seed
-- SC Agentic Solutions · MIT
--
-- Scaffold / placeholder. NOT deployed or tested. No live DB was touched.
-- Idempotent: safe to run repeatedly (drops + recreates in one transaction).
--
-- Four tables:
--   services      — the salon menu the receptionist quotes from (price + duration)
--   customers     — one row per phone number, upserted on each inbound message
--   appointments  — booking requests; written as 'pending' for owner confirmation
--   messages      — conversation memory (load the last N for context)
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS messages     CASCADE;
DROP TABLE IF EXISTS customers    CASCADE;
DROP TABLE IF EXISTS services     CASCADE;

-- ---------------------------------------------------------------------
-- services — the menu. The prompt is built ONLY from these rows, so the
-- model can never invent a service or a price. Swap this seed to re-skin
-- the demo for a barbershop / clinic / restaurant / cleaning / real estate.
-- ---------------------------------------------------------------------
CREATE TABLE services (
    id            serial PRIMARY KEY,
    name          text    NOT NULL,
    description   text    NOT NULL DEFAULT '',
    price         numeric NOT NULL DEFAULT 0,   -- quoted currency amount
    duration_min  integer NOT NULL DEFAULT 30   -- appointment length, minutes
);

-- ---------------------------------------------------------------------
-- customers — upserted by phone (WhatsApp sender id). One row per person.
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    id          serial PRIMARY KEY,
    phone       text    NOT NULL UNIQUE,         -- E.164, the WhatsApp sender
    name        text,
    email       text,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- appointments — a booking request. The agent only ever writes 'pending';
-- the owner confirms out-of-band (owner-notify + Calendly/Acuity swap-points).
-- ---------------------------------------------------------------------
CREATE TABLE appointments (
    id             serial PRIMARY KEY,
    phone          text NOT NULL,
    service_id     integer REFERENCES services(id),
    requested_time text,                          -- free text as the customer phrased it
    status         text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','confirmed','declined')),
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- messages — conversation memory. Every inbound + assistant turn is logged;
-- the prompt loads the most recent N for this phone to keep context.
-- ---------------------------------------------------------------------
CREATE TABLE messages (
    id          serial PRIMARY KEY,
    phone       text NOT NULL,
    role        text NOT NULL CHECK (role IN ('user','assistant')),
    text        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_phone_created ON messages (phone, created_at DESC);
CREATE INDEX idx_appts_phone            ON appointments (phone);

-- =====================================================================
-- SEED — a realistic salon so the demo reads as real.
-- =====================================================================

-- 8 salon services with prices + durations.
INSERT INTO services (name, description, price, duration_min) VALUES
  ('Women''s Haircut',   'Consultation, shampoo, cut & style',                45,  60),
  ('Men''s Haircut',     'Clipper or scissor cut, hot-towel finish',          30,  45),
  ('Blow-Dry & Style',   'Wash and professional blow-out',                    40,  45),
  ('Full Color',         'Single-process all-over color',                    110,  90),
  ('Balayage',           'Hand-painted freehand highlights, natural grow-out',180, 150),
  ('Root Touch-Up',      'Regrowth color at the roots',                       75,  60),
  ('Manicure',           'Classic manicure, shape, cuticle care & polish',    35,  40),
  ('Pedicure',           'Spa pedicure, exfoliation, massage & polish',       50,  55);

-- 2 sample customers.
INSERT INTO customers (phone, name, email, notes) VALUES
  ('+15551234567', 'Maria Gomez', 'maria.g@example.com', 'Prefers Saturday mornings; regular balayage client'),
  ('+15559876543', 'James Carter', NULL,                 'New contact — first message');

-- A short sample thread for Maria so conversation context is visible.
INSERT INTO messages (phone, role, text, created_at) VALUES
  ('+15551234567', 'user',      'Hi! Do you have any openings this week?',                                   now() - interval '2 days'),
  ('+15551234567', 'assistant', 'Hi Maria! Yes, we have several openings this week. What service were you looking for?', now() - interval '2 days' + interval '1 minute'),
  ('+15551234567', 'user',      'Thinking about a balayage refresh.',                                        now() - interval '2 days' + interval '3 minutes'),
  ('+15551234567', 'assistant', 'Lovely — a Balayage is $180 and takes about 2.5 hours. What day works best for you?', now() - interval '2 days' + interval '4 minutes');

COMMIT;

-- =====================================================================
-- Reference queries the workflow issues (parameterized in n8n):
--   upsert customer:
--     INSERT INTO customers (phone, name) VALUES ($1, $2)
--     ON CONFLICT (phone) DO UPDATE SET name = COALESCE(EXCLUDED.name, customers.name);
--   load recent context:
--     SELECT role, text FROM messages WHERE phone = $1 ORDER BY created_at DESC LIMIT 10;
--   log a message:
--     INSERT INTO messages (phone, role, text) VALUES ($1, $2, $3);
--   book (pending):
--     INSERT INTO appointments (phone, service_id, requested_time, status, notes)
--     VALUES ($1, $2, $3, 'pending', $4);
-- =====================================================================
