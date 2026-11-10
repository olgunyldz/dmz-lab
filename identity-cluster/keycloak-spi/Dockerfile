# Keycloak 26.6 + DMZ mobil DPoP token exchange SPI'si
# Derleme: docker build -t dmz-lab/keycloak-dpop:26.6 identity-cluster/keycloak-spi
# Kaynak: Maven Central (keycloak-* 26.6.4, provided)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline || true
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM quay.io/keycloak/keycloak:26.6
COPY --from=build /src/target/dmz-dpop-mobile-exchange.jar /opt/keycloak/providers/
# x509 provider (exchange istemcileri client-x509 ile kimlik doğrular) ve SPI'nin build'e alınması
RUN /opt/keycloak/bin/kc.sh build --spi-x509cert-lookup--provider=envoy
