# Cihaz güven servisi (örnek). Yalnız stdlib: ek bağımlılık yok.
FROM python:3.12-alpine
WORKDIR /app
COPY server.py /app/server.py
USER 10001
EXPOSE 8443
ENTRYPOINT ["python", "/app/server.py"]
