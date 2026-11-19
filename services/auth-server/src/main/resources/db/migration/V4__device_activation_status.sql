-- Aktivasyon durumu auth-server'de tutulur (PENDING / ACTIVATED). V3 uygulandıktan sonra eklendi (V3 değiştirilmez).
ALTER TABLE device_activation ADD COLUMN status VARCHAR(32) NOT NULL DEFAULT 'PENDING';
