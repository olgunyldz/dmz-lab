# Seal Mobile (vendor mock, DMZ, ns seal-mobile). IdP token doğrulaması için PyJWT.
FROM python:3.12-alpine
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY server.py /app/server.py
USER 10001
EXPOSE 8443
ENTRYPOINT ["python", "/app/server.py"]
