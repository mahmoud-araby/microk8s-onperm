package com.example.platform.payments.config;

import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.DirectExchange;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.ExchangeBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Declares the topology this service owns: its work queue bound to the orders exchange, with a dead-letter
 * exchange/queue for messages that are rejected (manual ack, requeue=false) or exceed the quorum delivery limit.
 */
@Configuration
public class RabbitConfig {

    private final PaymentsProperties.Rabbit rabbit;

    public RabbitConfig(PaymentsProperties properties) {
        this.rabbit = properties.rabbit();
    }

    @Bean
    TopicExchange ordersExchange() {
        return ExchangeBuilder.topicExchange(rabbit.exchange()).durable(true).build();
    }

    @Bean
    DirectExchange deadLetterExchange() {
        return ExchangeBuilder.directExchange(rabbit.deadLetterExchange()).durable(true).build();
    }

    @Bean
    Queue orderCreatedQueue() {
        return QueueBuilder.durable(rabbit.queue())
                .quorum()
                .deliveryLimit(5)
                .deadLetterExchange(rabbit.deadLetterExchange())
                .deadLetterRoutingKey(rabbit.deadLetterQueue())
                .build();
    }

    @Bean
    Queue orderCreatedDeadLetterQueue() {
        return QueueBuilder.durable(rabbit.deadLetterQueue()).quorum().build();
    }

    @Bean
    Binding orderCreatedBinding() {
        return BindingBuilder.bind(orderCreatedQueue()).to(ordersExchange()).with(rabbit.routingKey());
    }

    @Bean
    Binding deadLetterBinding() {
        return BindingBuilder.bind(orderCreatedDeadLetterQueue()).to(deadLetterExchange()).with(rabbit.deadLetterQueue());
    }
}
