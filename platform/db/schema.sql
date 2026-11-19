-- LegacyDB (PostgreSQL 16, ibdb_fortuna) şeması. Tekrar çalıştırılabilir (IF NOT EXISTS).
-- Referans şema (LegacyDB). Monolit başlangıçta tabloları kendisi oluşturur; bu dosya el ile inceleme içindir.
-- Sırlar bu dosyada yok. Demo verisi: seed.sql.

CREATE TABLE IF NOT EXISTS customers (
    customer_id     text PRIMARY KEY,
    seal_owner_id   text NOT NULL UNIQUE,
    full_name       text NOT NULL,
    status          text NOT NULL DEFAULT 'ACTIVE'
);

CREATE TABLE IF NOT EXISTS accounts (
    account_no      text PRIMARY KEY,
    customer_id     text NOT NULL REFERENCES customers(customer_id),
    account_type    text NOT NULL,
    balance         numeric(16,2) NOT NULL,
    currency        text NOT NULL DEFAULT 'TRY'
);

CREATE TABLE IF NOT EXISTS fortuna_users (
    username        text PRIMARY KEY,
    customer_id     text NOT NULL,
    salt            text NOT NULL,
    pw_hash         text NOT NULL,
    status          text NOT NULL
);

-- customer_devices kaldırıldı: cihaz kaydı ve durumu Seal Intranet'te (tek kaynak, D-13)

CREATE SEQUENCE IF NOT EXISTS device_events_id_seq START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS device_events (
    id              bigint PRIMARY KEY DEFAULT nextval('device_events_id_seq'),
    customer_id     text NOT NULL,
    device_id       text NOT NULL,
    from_status     text,
    to_status       text NOT NULL,
    reason          text NOT NULL,
    at              timestamptz NOT NULL DEFAULT now()
);

-- PIN doğrulayıcıları (eski Password Manager; monolit da açılışta aynı tabloyu oluşturur)
CREATE TABLE IF NOT EXISTS pin_verifiers (
    user_id         text NOT NULL,
    device_id       text NOT NULL,
    salt            bytea NOT NULL,
    hash            bytea NOT NULL,
    fails           integer NOT NULL DEFAULT 0,
    expires         double precision NOT NULL,
    PRIMARY KEY (user_id, device_id)
);
