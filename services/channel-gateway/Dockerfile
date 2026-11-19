# channel-gateway (bank-prod/channel). Taban: dmz-lab/base-python.
ARG BASE_PYTHON=dmz-lab/base-python:3.12
FROM ${BASE_PYTHON}
COPY channel_gateway.py /app/channel_gateway.py
ENV PORT=8443
EXPOSE 8443
ENTRYPOINT ["python", "/app/channel_gateway.py"]
