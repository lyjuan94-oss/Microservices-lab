package com.skistation.reservationms.config;

import feign.RequestInterceptor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.oauth2.client.*;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.AuthenticatedPrincipalOAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizedClientRepository;

@Configuration
public class FeignOAuth2Config {

    private static final String REGISTRATION_ID = "msreservation";

    @Bean
    public OAuth2AuthorizedClientManager authorizedClientManager(
            ClientRegistrationRepository clientRegistrationRepository) {

        OAuth2AuthorizedClientService authorizedClientService =
                new InMemoryOAuth2AuthorizedClientService(clientRegistrationRepository);

        OAuth2AuthorizedClientRepository authorizedClientRepository =
                new AuthenticatedPrincipalOAuth2AuthorizedClientRepository(authorizedClientService);

        DefaultOAuth2AuthorizedClientManager manager =
                new DefaultOAuth2AuthorizedClientManager(clientRegistrationRepository, authorizedClientRepository);

        OAuth2AuthorizedClientProvider provider = OAuth2AuthorizedClientProviderBuilder.builder()
                .clientCredentials()
                .build();

        manager.setAuthorizedClientProvider(provider);
        return manager;
    }

    @Bean
    public RequestInterceptor oauth2FeignRequestInterceptor(OAuth2AuthorizedClientManager manager) {
        return requestTemplate -> {
            var principal = new AnonymousAuthenticationToken(
                    "key",
                    "reservation-service",
                    AuthorityUtils.createAuthorityList("ROLE_SERVICE")
            );

            OAuth2AuthorizeRequest authorizeRequest = OAuth2AuthorizeRequest
                    .withClientRegistrationId(REGISTRATION_ID)
                    .principal(principal)
                    .build();

            OAuth2AuthorizedClient client = manager.authorize(authorizeRequest);

            if (client != null && client.getAccessToken() != null) {
                requestTemplate.header("Authorization", "Bearer " + client.getAccessToken().getTokenValue());
            }
        };
    }
}
