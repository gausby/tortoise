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

The higher quality of service specified the more expensive a publish
or a subscription will be bandwidth wise, as a higher QoS will require
more protocol messages to fulfill network exchange. That is why some
brokers administrators choose to configure their broker to refuse
higher quality of services for some topics, or some subscriptions. In
the case of subscriptions it can happen that a lower QoS than the one
requested is accepted.

**Notice**: Placing a subscription with QoS=2 does not mean that the
client will receive messages received as QoS=2, it will receive all
messages published to that topic regardless of QoS; the message
exchange between the broker and the client will use the specified QoS
in the subscription.

When a message is published to the broker the client sending the
message can specify that the broker should retain the message; if so
the broker will keep the message and dispatch it to clients when they
subscribe to the topic.

It is also possible for a client to specify a *last will message* when
connecting to the broker. The broker will keep this message and
dispatch it to the specified topic when the client disconnect abruptly
from the broker.

## The Tortoise MQTT Client

Tortoise aims to hide the MQTT semantics from the user, and expose an
interface that should be familiar to a Elixir developer. This means
the message exchanges needed to complete a publish-, or retrieval of a
message on a subscription with a QoS>0 should be handled in the
background and the details of the protocol should not bleed through to
the user.

While the goal of the project is to hide the details of the MQTT
protocol from the user another goal is not to restrict the user in any
way. This means Tortoise will attempt to map Elixir semantics to the
MQTT semantics, which should be possible because both systems deals
with message passing:

  - A publish with QoS=0 works like a cast; send and forget.

  - A publish with QoS>0 result in a message exchange between the
    sender and the receiver; to keep track of these messages the MQTT
    protocol specify that these messages should have an identifier
    assigned, a random 16-bit number. The user of Tortoise will never
    see this random 16-bit number, but instead an Erlang reference
    will get returned from the publish function, which makes it
    possible to await and pattern match for the return.

  - Further more, when it comes to publishing messages; the client
    should make sure that messages with a QoS>0 is delivered, so if
    the client is offline it should store these messages and send them
    when the client is back online.

  - A callback behaviour is specified allowing the user to implement
    custom behavior for when the client connects; disconnects; accept
    a subscription; acknowledge an unsubscribe; and receive a message
    on one of the subscribed topics.

If the design of Tortoise is a hindrance to creating something with
MQTT (within reason) it should be considered a bug, and it should be
discussed how we should map that behaviour to the Elixir semantics.

## Summary

MQTT is a protocol implementing a PubSub allowing one or multiple
clients to subscribe to topics, using topic filters, and clients to
publish messages to topics. Tortoise is a MQTT client that aims to map
the MQTT semantics to Elixir so sending and receiving messages using a
MQTT broker feels like any other kind of message passing, and awaiting
results feels natural to the Elixir ecosystem.
