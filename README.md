# Tortoise

[![Build Status](https://travis-ci.org/gausby/tortoise.svg)](https://travis-ci.org/gausby/tortoise)

A MQTT Client application that keep connections to one or more MQTT
brokers, handles subscriptions, and expose a publisher for publishing
messages to the broker.

This is work in progress. I need to write documentation before it us
usable, but as such the client should support:

  - Keeping a connection to a MQTT server (version 3.1.1 for now)
  - Publishing and subscribing to topics of QoS 0, 1, and 2
  - Connecting via TCP
  - The fundamentals are there, but some of the API's might change in
    the near future

Most of the public facing interface should be in the `Tortoise`
module. See the GitHub issues for work in progress "known issues in
the design", "what needs to be done", and so forth list of todo's.

I would love to get some feedback and help building this thing.


## Example

Just to get people started:

``` elixir
# make sure the application is started
Tortoise.start(:temporary, [])

# connect to the server and subscribe to foo/bar
Tortoise.Supervisor.start_child(
    client_id: "my_client_id",
    driver: {Tortoise.Driver.Logger, []},
    server: {:tcp, 'localhost', 1883},
    subscriptions: [{"foo/bar", 0}])

# Open a pipe we can post stuff into...

# ...while the word subscribe might be confusing it is meant to mean
# "subscribe to a connection on the transmitter"; the subscribing
# process will get a new pipe when the connection is reestablished, for
# what ever reason. The pipe will be in the mailbox of the subscribing
# process.
{:ok, pipe} = Tortoise.Connection.Transmitter.subscribe_await("my_client_id");

# publish a message on the broker
Tortoise.publish(pipe, "foo/bar", "Hello from the World of Tomorrow !", qos: 0)
```

The "pipe" concept should get a better description, it is basically a
struct that holds a socket we can put MQTT Publish messages into, and
they will get shot directly on the server.


## Installation

It is not available on hex yet, but it will be soon!

When [available in Hex](https://hex.pm/docs/publish), the package can
be installed by adding `tortoise` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:tortoise, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/tortoise](https://hexdocs.pm/tortoise).
