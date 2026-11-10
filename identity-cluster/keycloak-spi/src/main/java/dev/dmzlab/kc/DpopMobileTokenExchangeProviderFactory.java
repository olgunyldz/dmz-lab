package dev.dmzlab.kc;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.protocol.oidc.TokenExchangeProviderFactory;
import org.keycloak.protocol.oidc.tokenexchange.StandardTokenExchangeProvider;

public class DpopMobileTokenExchangeProviderFactory implements TokenExchangeProviderFactory {

    public static final String ID = "dmz-dpop-mobile-exchange";

    @Override
    public TokenExchangeProvider create(KeycloakSession session) {
        return new DpopMobileTokenExchangeProvider(new StandardTokenExchangeProvider());
    }

    @Override
    public void init(Config.Scope config) {
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
    }

    @Override
    public void close() {
    }

    @Override
    public String getId() {
        return ID;
    }

    /**
     * Keycloak, provider factory'leri order() değerine göre (büyük olan önce) dener ve supports() true dönen
     * ilkini kullanır. Standart provider order 0 olduğu için bizimki önce denenir. supports() yalnızca
     * DMZ mobil client'ından gelen isteklerde true döner; diğer exchange'ler standart akışta kalır.
     * (Doğrulandı: order 100 ile mobil exchange SPI'ye ulaşır; -100 ile ulaşmaz.)
     */
    @Override
    public int order() {
        return 100;
    }
}
