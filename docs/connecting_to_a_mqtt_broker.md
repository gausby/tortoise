# Connecting to a MQTT Broker

Tortoise is capable of connecting to any MQTT broker that implements
the 3.1.1 version of the MQTT protocol (support for MQTT 5 is
planned). It does so by taking a connection specification, and with it
will do its best to connect to the broker and keeping the connection
open.

This document will describe the configuration options.

## Connection name and `client_id`

In MQTT the clients announce themselves to the broker with what is
referred to as a *client id*. Two clients cannot share the same client
id, and depending on the implementation (or configuration) the server
will either kick the first client off the broker, or deny the new
client if it specifies a client id already in use.

The protocol specifies that a valid client id is between 1 and 23
UTF-8 encoded bytes in length, but some server configurations may
allow for longer ids.

`Tortoise` uses the specified client id to identify a connection, so
it is used when publishing messages, subscribing to topics, or
otherwise interacting with the connection in the user code.

Allowed values is a string, or an atom. If an atom is specified it
will be converted to a string when the connection message is send on
the wire, but it will be possible to refer to the connection using the
atom.

**Notice**: Though the MQTT 3.1.1 protocol allow for a zero-byte
client id—in which case the server should assign a random `client_id`
for the connection—a `client_id` is enforced in `Tortoise`. This is
done so the connection has an identifier that can be used when
interacting with the connection.

## The keep alive interval

When connected a MQTT client should ping the server on a set interval
to let the broker know that it is still alive. The keep alive value is
given as an integer, describing time in seconds between keep alive
messages, and should be set depending on factors such as power
consumption, network bandwidth, etc. Per default `Tortoise` will sent
a keep alive message every 60 seconds, which is a reasonable value for
most installations. The allowed maximum value is `65_535`, which is 18
hours, 12 minutes, and 15 seconds; most would considered this a bit
too extreme, and some brokers might reject connections specifying a
too long `keep_alive` interval.

Some brokers allow disabling the keep alive interval by setting it to
zero, so `Tortoise` allow for a `keep_alive` specified as `0`. Note
that the broker can still choose to disconnect a given client on the
grounds of inactivity. When `keep_alive` is disabled the broker
implementation will decide its own measure of inactivity, so to avoid
unspecified behavior it is advised to use a keep alive value.

## User Name and Password

Some brokers are configured to require some basic authentication,
which will determine whether a user is allowed to subscribe or publish
to a given topic, and some set limitations to what quality of service
a particular user, or group of users, are allowed to subscribe or
publish with.

To specify a user name and password for a connection the aptly named
`user_name` and `password` comes in handy. Both of them take UTF-8
encoded strings, or `nil` as their value, in which case an anonymous
connection is attempted. Depending on the broker configuration it is
allowed to specify a user name and omit the password, but the user
name has to be specified if a password is specified.

Both default to `nil` if left blank.

## Last will message

It is possible to specify a message which should be dispatched by the
broker if the client is disconnected from the broker abruptly. This
message is known as the last will message. This allow for other
connected clients to act on other clients leaving the broker.

The last will message is specified as part of the connection, and for
tortoise [todo]
