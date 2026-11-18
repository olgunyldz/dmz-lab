# Seal Intranet: iç backend-to-backend API servisi (ayrı deployment, namespace seal-intranet).
FROM python:3.12-alpine
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY server.py /app/server.py
USER 10001
EXPOSE 8080
ENTRYPOINT ["python", "/app/server.py"]
