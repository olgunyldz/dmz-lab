-- Kayıtlı mobil cihazlar ve web girişi onayları (V3/V4 değiştirilmez).
CREATE TABLE device_registry (
    username      VARCHAR(64)  NOT NULL,
    device_id     VARCHAR(128) NOT NULL,
    registered_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    PRIMARY KEY (username, device_id)
);

-- Bir web girişi onayı, kullanıcının her kayıtlı cihazına bir satır olarak gider; ilk onay kazanır.
CREATE TABLE device_approval (
    approval_id VARCHAR(64)  NOT NULL,
    device_id   VARCHAR(128) NOT NULL,
    username    VARCHAR(64)  NOT NULL,
    state       VARCHAR(16)  NOT NULL,
    expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    decided_at  TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (approval_id, device_id)
);
