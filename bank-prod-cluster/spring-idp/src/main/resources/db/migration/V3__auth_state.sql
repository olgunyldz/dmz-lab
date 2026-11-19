-- Kimlik durumu (mobil kimlik ve oturum süreçleri IdP'de): OTP, yeni cihaz bekleyen kullanıcı,
-- aktivasyon token'ları ve throttling sayaçları.

CREATE TABLE auth_otp (
    flow_id     VARCHAR(128) PRIMARY KEY,
    username    VARCHAR(64)  NOT NULL,
    code_hash   VARCHAR(128) NOT NULL,
    expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    tries       INTEGER      NOT NULL DEFAULT 0
);

-- Yeni cihazdan OTP geçilmiş, aktivasyonu tamamlanmamış kullanıcılar: token'ları scope=activation (kısıtlı) olur.
CREATE TABLE pending_activation (
    username    VARCHAR(64) PRIMARY KEY,
    since       TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE TABLE device_activation (
    activation_token VARCHAR(128) PRIMARY KEY,
    username         VARCHAR(64)  NOT NULL,
    created_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE TABLE throttle (
    key_name     VARCHAR(255) PRIMARY KEY,
    hits         INTEGER      NOT NULL,
    window_start TIMESTAMP WITH TIME ZONE NOT NULL
);

-- Seal Mobile'ın bildirdiği login akış durumu (IdP içinde; login/status buradan okunur).
CREATE TABLE auth_flow (
    flow_id     VARCHAR(128) PRIMARY KEY,
    username    VARCHAR(64)  NOT NULL,
    status      VARCHAR(32)  NOT NULL,
    new_device  BOOLEAN      NOT NULL DEFAULT FALSE,
    updated_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
