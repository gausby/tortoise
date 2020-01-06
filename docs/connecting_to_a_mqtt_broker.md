# Connecting to a MQTT Broker

Tortoise is capable of connecting to any MQTT broker that implements
the 3.1.1 version of the MQTT protocol (support for MQTT 5 is
planned). It does so by taking a connection specification, and with it
will do its best to connect to the broker and keeping the connection
open.

A minimal connection specification looks like this:

``` elixir
{ok, _pid} =
  Tortoise.Connection.start_link(
    client_id: HelloWorld,
    server: {Tortoise.Transport.Tcp, host: "localhost", port: 1883},
    handler: {Tortoise.Handler.Logger, []}
  )
```

This will establish a TCP connection to a broker running on
*localhost* port *1883*. The connection takes a module that implements
the `Tortoise.Handler` behaviour; In this case the
`Tortoise.Handler.Logger` callback module, which will print a log
statement on events happening during the connection life cycle.

Furthermore, we specify that the `client_id` of the connection is
`HelloWorld`. The client id can later be used to interact with the
connection, such as publishing messages and subscribing to topics.

Notice that this example expects a server configured to allow anonymous
connections without SSL. Not all MQTT brokers are configured the same, so
depending on the server more configuration options might be needed for
a successful connection. This document aims to give an overview.

## Network Transport

Tortoise has an abstraction for the network transport, and comes
with two official implementations included in Tortoise itself:

  - `Tortoise.Transport.Tcp` used to connect to a broker via
    TCP. While this transport is the simplest to use it is also the
    least secure, and should only be used on trusted networks. It is
    based on `:gen_tcp` found in the Erlang/OTP distribution.

  - `Tortoise.Transport.SSL` used to create a secure connection via
    secure socket layer. This option takes a bit more work to setup,
    but it will prevent people from eavesdropping on the data being
    sent between the client and the broker.

The transports are given with the `server` field in the connection
specification as a tuple, containing the transport type and an
options list specific to the given transport.

`Tortoise.Transport.Tcp` takes two options; the host name as a string,
such as `"localhost"` or a four-tuple describing an IP-network
address, such as `{127, 0, 0, 1}`. An example where the TCP transport
is used can be seen in the introduction to this article.

The `Tortoise.Transport.SSL` is a bit more versatile in its
configuration options. The most important additional options are:

  - `cacertfile` needs to point to a file with trusted CA
    certificates, which is necessary for server certificate
    verification. For instance, when using the
    [certifi](https://hex.pm/packages/certifi) package, pass
    `cacertfile: :certifi.cacertfile()` in the options. It is also
    possible to pass a list of binary (DER encoded) root CA
    certificates using the `cacerts` option instead.
  - `certfile` and `keyfile` are needed if the server authenticates
    clients using a client certificate. The `cert` and `key` options
    can be used instead to pass the client certificate and key as
    DER binaries instead of paths.
  - `verify` defaults to `:verify_peer`, enabling server certificate
    verification. To override, include `verify: :verify_none` in the
    server options. In that case there is no need to define CA
    certificates, but an attacker could intercept the connection
    without detection!

Note that any paths must be specified as charlists.

The implementation is based on the `:ssl` module from the Erlang
distribution, so be sure to check the documentation for the `:ssl`
module for detailed information on the possible configuration
options.

Information on creating a custom transport can be found in the
`Tortoise.Transport` module, but for most cases the TCP and SSL modules
should suffice.

## Connection Handler

A handful of events are possible during a client life cycle. Tortoise
aims to expose the interesting events as callback functions, defined in
the `Tortoise.Handler` behaviour, making it possible to implement
custom behavior for the client. The exposed events are:

  - The client is initialized, or terminated allowing for
    initialization and tear down of subsystems
  - A connection to the server is established
  - The connection to the server is dropped
  - The subscription status of a given topic filter is changed
  - A message is received on one of the subscribed topic filters

Read more about defining custom behavior for a connection in the
documentation for the `Tortoise.Handler` module.

## The `client_id`

In MQTT, the clients announce themselves to the broker with what is
referred to as a *client id*. Two clients cannot share the same client
id on a broker, and depending on the implementation (or configuration)
the server will either kick the first client out, or deny the new client
if it specifies a client id that is already in use.

The protocol specifies that a valid client id is between 1 and 23
UTF-8 encoded bytes in length, but some server configurations may
allow for longer ids; thus tortoise will allow for client identifiers
longer than 23 bytes but some MQTT brokers might reject the
connection.

Allowed values are a string or an atom. If an atom is specified it
will be converted to a string when the connection message is sent on
the wire, but it will be possible to refer to the connection using the
atom, which can be more convenient. Notice that the client id can
easily reach the 23 bytes when converted from an atom because atoms
starting with an uppercase letter will be prefixed with *Elixir.*;
therefore `MyClientId` will be 17 bytes instead of the 10 one could
expect.

``` elixir
iex(1)> client_id = Atom.to_string(MyClientId)
"Elixir.MyClientId"
iex(2)> byte_size(client_id)
17
```

The specified client identifier is used to identify a connection when
publishing messages, subscribing to topics, or otherwise interacting
with the named connection.

``` elixir
{ok, _pid} =
  Tortoise.Connection.start_link(
    client_id: MyClient,
    server: {Tortoise.Transport.Tcp, host: "localhost", port: 1883},
    handler: {Tortoise.Handler.Logger, []}
  )

Tortoise.publish(MyClient, "foo/bar", "hello")
```

**Note**: Though the MQTT 3.1.1 protocol allows for a zero-byte
client id — in which case the server should assign a random `client_id`
for the connection — a client id is enforced in Tortoise. This is
done so the connection has an identifier that can be used when
interacting with the connection.

## User Name and Password

Some brokers are configured to require some basic authentication,
which will determine whether a user is allowed to subscribe or publish
to a given topic, and some set limitations to what quality of service
a particular user, or group of users, are allowed to subscribe or
publish with.

To specify a user name and password for a connection the aptly named
*user_name* and *password* connection configuration fields come in handy.
Both of them take UTF-8 encoded strings, or `nil` as their value, in which
case an anonymous connection is attempted. Depending on the broker 
configuration it is allowed to specify a user name and omit the password, 
but the user name has to be specified if a password is specified.

Both default to `nil` if left blank.

## The keep alive interval

When connected, an MQTT client should ping the server on a set interval
to let the broker know that it is still alive. The keep alive value is
given as an integer, describing time in seconds between keep alive
messages, and should be set depending on factors such as power
consumption, network bandwidth, etc. Per default Tortoise will send a
keep alive message every 60 seconds, which is a reasonable value for
most installations. The allowed maximum value is `65_535`, which is 18
hours, 12 minutes, and 15 seconds; most would consider this a bit too
extreme, and some brokers might reject connections specifying `keep_alive`
interval that is too high.

Some brokers allow disabling the keep alive interval by setting it to
zero, so `Tortoise` allows for a `keep_alive` specified as `0`. Note
that the broker can still choose to disconnect a given client due to
inactivity. When `keep_alive` is disabled, the broker
implementation will decide its own measure of inactivity. So, to avoid
unspecified behavior, it is advised to use a keep alive value.

## Last will message

It is possible to specify a message which should be dispatched by the
broker if the client is abruptly disconnected from the broker. This
message is known as the last will message, and allows for other
connected clients to act on other clients leaving the broker.

The last will message is specified as part of the connection, and for
Tortoise it is possible to configure a last will message by passing in
a `Tortoise.Package.Publish` struct to the *will* connection
configuration field.

``` elixir
{:ok, pid} =
  Tortoise.Connection.start_link(
    client_id: William,
    server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883},
    handler: {Tortoise.Handler.Logger, []},
    will: %Tortoise.Package.Publish{topic: "foo/bar", payload: "goodbye"}
  )
```

If we have another client connected to the broker, subscribing to
*foo/bar*, we should now receive a message containing the message
*goodbye* on that topic, should the client called *William* disconnect
abruptly from the broker. We can simulate this by terminating the *pid*
using `Process.exit(pid, :ouch)`.
