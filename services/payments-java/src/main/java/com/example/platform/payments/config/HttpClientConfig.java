package com.example.platform.payments.config;

import java.net.http.HttpClient;

import org.springframework.boot.http.client.ClientHttpRequestFactoryBuilder;
import org.springframework.boot.http.client.ClientHttpRequestFactorySettings;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestClient;

@Configuration
public class HttpClientConfig {

    /**
     * RestClient.Builder from Boot is observation-enabled, so traceparent is propagated to the provider.
     * HTTP/1.1 explicitly: plain-text calls go through the Envoy sidecar / egress gateway, which originates TLS and
     * HTTP/2 itself; the JDK client's default h2c upgrade attempt is rejected by many servers.
     */
    @Bean
    RestClient paymentProviderRestClient(RestClient.Builder builder, PaymentsProperties properties) {
        var provider = properties.provider();
        var settings = ClientHttpRequestFactorySettings.defaults()
                .withConnectTimeout(provider.connectTimeout())
                .withReadTimeout(provider.readTimeout());
        return builder
                .baseUrl(provider.baseUrl())
                .requestFactory(ClientHttpRequestFactoryBuilder.jdk()
                        .withHttpClientCustomizer(client -> client.version(HttpClient.Version.HTTP_1_1))
                        .build(settings))
                .build();
    }
}
