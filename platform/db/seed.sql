-- LegacyDB demo verisi (lab). Tekrar çalıştırılabilir (ON CONFLICT DO NOTHING).
-- Müşteri C000000001 = Alice Demo, Seal sahibi alice. Parola Fortuna ACL tarafında (fortuna_users) tutulur.

INSERT INTO customers (customer_id, seal_owner_id, full_name, status)
VALUES ('C000000001', 'alice', 'Alice Demo', 'ACTIVE')
ON CONFLICT (customer_id) DO NOTHING;

INSERT INTO accounts (account_no, customer_id, account_type, balance, currency)
VALUES ('TR000000000001', 'C000000001', 'vadesiz', 12500.00, 'TRY')
ON CONFLICT (account_no) DO NOTHING;

-- Havale testi için ikinci müşteri (lab). Parola ve Seal cihazı yok; yalnız alıcı hesap olarak kullanılır.
INSERT INTO customers (customer_id, seal_owner_id, full_name, status)
VALUES ('C000000002', 'bora', 'Bora Demo', 'ACTIVE')
ON CONFLICT (customer_id) DO NOTHING;

INSERT INTO accounts (account_no, customer_id, account_type, balance, currency)
VALUES ('TR000000000002', 'C000000002', 'vadesiz', 2500.00, 'TRY')
ON CONFLICT (account_no) DO NOTHING;
