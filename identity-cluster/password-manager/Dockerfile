# Password Manager (vendor mock, identity cluster, ns seal-pm). Yalnız stdlib.
FROM python:3.12-alpine
WORKDIR /app
COPY server.py /app/server.py
USER 10001
EXPOSE 8443
ENTRYPOINT ["python", "/app/server.py"]
