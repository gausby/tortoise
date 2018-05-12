# Intoduction

Tortoise is a MQTT client application written in Elixir for use in
Elixir applications. Its philosophy is to separate the MQTT semantics
from the Elixir semantics, attempting to hide the MQTT protocol
details from the end-user while still being flexible enough to be able
to do just about anything one would like to do with the MQTT protocol.

## MQTT overview

MQTT is a lightweight Publish/Subscribe (PubSub) protocol, designed to
operate on high-latency networks or unreliable networks. It is a
server/client architecture, so a MQTT server (often referred to as a
broker) is required for the clients to connect to. All communication
happens via the broker, clients cannot see each other, and the
capabilities of the MQTT broker can vary depending on its
implementation and its configuration.

Being a PubSub protocol the clients can connect to the broker and
subscribe to topics, by specifying topic filters, and post messages to
topics. Depending on the configuration of the broker the topics can be
free-form (any valid topic filter accepted), or restricted to a
handful of topics. A topic consist of one or more *topic levels*,
separated by forward slashes such as:

    rooms/living-room/temp
    rooms/hall/temp
    rooms/kitchen/temp

"Topic filters" allow the client to glob on topics, and support
wildcards for a single level using a plus sign `+`; or multiple levels
using a hash sign `#`, which may only be at the last spot of the topic
filter. `rooms/+/temp` would subscribe to messages posted to all the
topics in the previous example, and `rooms/#` would subscribe to every
message posted to all topics starting with *rooms*. The wildcard
patterns can be mixed, so `+/+/#` would be a valid topic.

When publishing a message we cannot use the wildcard functionality,
that is strictly for subscribing; Publishing messages needs to be
addressed to a specific topic, *not a topic filter*.

The protocol support three kinds of quality of service (QoS) for both
subscriptions and publishing. The three kinds are defined as the
following:

  - *QoS=0* is a fire and forget. The sender has no guarantee that the
    receiver will receive the message.

  - *QoS=1* where the receiver will respond with an acknowledge
    message, at which point the sender will stop retransmitting the
    message. It is possible that a retransmission will arrive after
    the acknowledge message has been sent, in which case the
    retransmission will be treated as a new message. In other words,
    this implements **at least once delivery**.

  - *QoS=2* implements a series of acknowledge and release messages
    ensuring a message will only get delivered once to the receiver,
    referred to as **exactly once delivery**.

The varying kinds of quality of services require more messages to be
transmitted on the network, so depending on the configuration on a
broker a message can be refused if the client is not allowed to send
using the specified QoS, or a subscription can be accepted with a
lower QoS than requested. This can be expensive on the bandwidth,
especially for subscriptions made to topics that are high traffic.

**Notice**: Placing a subscription with QoS=2 does not mean that the
client will receive messages received as QoS=2, it will receive all
messages published to that topic regardless of QoS; the message
exchange between the broker and the client will use the specified QoS
in the subscription.

### Last will message

### Retained messages

## Summary
