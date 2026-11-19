# Janus (web ve mobil kanal girişi). Taban: dmz-lab/base-python (images/build-base.sh).
ARG BASE_PYTHON=dmz-lab/base-python:3.12
FROM ${BASE_PYTHON}
COPY janus.py /app/janus.py
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["python", "/app/janus.py"]
