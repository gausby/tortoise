# Publishing Messages

Tortoise provide a couple of methods for publishing messages to a MQTT
broker. They very in the amount of setup needed to setup a publish,
and they differ in the way connection drops are handled.

This document will describe the different supported ways of publishing
messages, and should serve as a guide for when to choose a particular
strategy and their setup. All publish methods require an open
connection.

## `Tortoise.publish/4`

The simplest way of publishing a message is to use the `publish`
function found on the main `Tortoise` module. Given the identifier
(*client_id*) of an open connection, and a topic, such as *foo/bar*, a
publish is a simple as `Tortoise.publish(MyClientId, "foo/bar")`,
which will send a message to the topic *foo/bar* with an empty payload
(`nil`).

A message payload can be specified by passing data as the third
argument.

``` elixir
Tortoise.publish(MyClientId, "foo/bar", "hello, world !")
```

We can pass in a fourth argument: an option list allowing us to
specify:

  - *qos* (default: *0*) the requested quality of service
  - *retain* (default: *false*) specifying if the message should be
    retained on the server for the given topic

Here we will publish a retained message with QoS=1 to *baz*.

``` elixir
Tortoise.publish(MyClientId, "baz", "Hi !", [qos: 1, retain: true])
```

If we want to pass options to a message without a payload we should
specify the payload as *nil*

``` elixir
Tortoise.publish(MyClientId, "baz", nil, [qos: 2])
```

If we were to pass in an empty string (*""*, or *<<>>*) a zero length
binary would be send instead, which is different from an empty
payload.
