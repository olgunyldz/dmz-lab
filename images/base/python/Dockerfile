# Taban imaj: Python uygulamaları. Derleyen: images/build-base.sh (tracing.py bağlamda hazırlanır).
# Uygulama imajları bundan başlar; pip ve kod orada eklenir. Çalışma zamanında pip kurulumu yapılmaz.
ARG PYTHON_TAG=3.12-alpine
FROM python:${PYTHON_TAG}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/opt/shared \
    HOME=/tmp

# Ortak izleme modülü: uygulamalar `import tracing` ile kullanır
COPY tracing.py /opt/shared/tracing.py

RUN addgroup -S -g 10001 app \
 && adduser -S -D -H -u 10001 -G app app

LABEL org.opencontainers.image.title="dmz-lab/base-python" \
      org.opencontainers.image.description="Python taban imajı (kullanıcı 10001, ortak tracing modülü)"

WORKDIR /app
USER 10001
