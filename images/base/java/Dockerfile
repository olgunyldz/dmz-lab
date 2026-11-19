# Taban imaj: Java çalışma zamanı (JRE). Derleyen: images/build-base.sh.
# Uygulama imajı çok aşamalıdır: derleme Maven ile, çalışma bu imajdan.
ARG JAVA_TAG=21-jre
FROM eclipse-temurin:${JAVA_TAG}

RUN groupadd -g 10001 app \
 && useradd -u 10001 -g app -M -s /usr/sbin/nologin app

LABEL org.opencontainers.image.title="dmz-lab/base-java" \
      org.opencontainers.image.description="Java JRE taban imajı (kullanıcı 10001)"

WORKDIR /app
USER 10001
