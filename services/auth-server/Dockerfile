# auth-server (Spring Authorization Server). Derleme: Maven aşaması; çalışma: dmz-lab/base-java (images/build-base.sh).
ARG MAVEN_TAG=3.9-eclipse-temurin-21
ARG BASE_JAVA=dmz-lab/base-java:21

FROM maven:${MAVEN_TAG} AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM ${BASE_JAVA}
COPY --from=build /src/target/auth-server.jar /app/auth-server.jar
EXPOSE 8443 8080 9100
# TLS portu dinliyor mu (JRE'de curl yok; bash /dev/tcp kullanılır)
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8443"]
ENTRYPOINT ["java", "-jar", "/app/auth-server.jar"]
