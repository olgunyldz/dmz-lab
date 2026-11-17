# Spring IdP (prototip). Derleme ve çalıştırma aşamaları ayrı.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/spring-idp.jar /app/spring-idp.jar
USER 10001
EXPOSE 8443 8080
ENTRYPOINT ["java", "-jar", "/app/spring-idp.jar"]
