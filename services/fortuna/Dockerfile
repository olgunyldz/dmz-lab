# Fortuna zinciri (CGW, API, ACL, SMS mock): tek kod, rol ROLE ortam değişkeniyle seçilir. Taban: dmz-lab/base-python.
ARG BASE_PYTHON=dmz-lab/base-python:3.12
FROM ${BASE_PYTHON}
COPY requirements.txt /app/requirements.txt
# Bağımlılıklar sistem dizinine kurulur (root); çalışma kullanıcısı 10001 aşağıda
USER root
RUN pip install --no-cache-dir -r /app/requirements.txt
USER 10001
COPY fortuna_stack.py /app/fortuna_stack.py
ENV PORT=8443
EXPOSE 8443
ENTRYPOINT ["python", "/app/fortuna_stack.py"]
