# Publishing Messages

Tortoise provides a couple of methods for publishing messages to an MQTT
broker. They vary in the amount of setup needed to setup a publish,
and they differ in the way connection drops are handled.

This document will describe the different supported ways of publishing
messages, and should serve as a guide for when to choose a particular
strategy and its setup. All publish methods require an open
connection.

## `Tortoise.publish/4`

The simplest way of publishing a message is to use the `publish`
function found on the main `Tortoise` module. Given the identifier
(*client_id*) of an open connection, and a topic, such as *foo/bar*, a
publish is as simple as `Tortoise.publish(MyClientId, "foo/bar")`,
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
binary would be sent instead, which is different from an empty
payload.

Notice that the semantics of the returned value change when the QoS
is bigger than *0*. For messages published with *QoS=0* the client
will respond with *:ok*.

``` iex
iex(1)> Tortoise.publish(MyClientId, "baz", nil, [qos: 0])
:ok
```

A message with *QoS=0* has no quality of service, which in MQTT terms
means that we have no guarantee that the message was delivered.

If the message is published with *QoS=1* or *QoS=2* we will get a
reference as the return value. This reference allows us to enter a
selective receive where we can get the result of the publish; in an
`iex` context we can simply use the `flush/0` command to see the
result:

``` iex
iex(2)> Tortoise.publish(MyClientId, "baz", nil, [qos: 1])
{:ok, #Reference<0.1924528969.904134659.102547>}
iex(3)> flush()
{{Tortoise, C}, #Reference<0.1924528969.904134659.102547>, :ok}
:ok
```

As observed we can expect a message containing a three-tuple. The
first element contains an identifier for the tortoise connection
`{Tortoise, *client identifier*}`, then the reference created by the
publish command, and finally the result of the operation; in this case
*:ok*. This structure should allow for some flexible pattern matches
in `handle_info/2` when Tortoise is used in the context of a
`GenServer`.
