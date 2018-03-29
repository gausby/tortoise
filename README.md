# Tortoise

A MQTT Client application that keep connections to one or more MQTT
brokers, handles subscriptions, and expose a publisher for publishing
messages to the broker.


## Subscribing to sockets

A process should be able to subscribe to a transmission socket, which
can be used to send data to directly without having to copy the data
to the transmission process before dispatching.

## Todo

- [ ] The identity of a connection should be an atom it is registered
      with in the configuration; right now a it is a binary used as
      the client id for the connection
- [ ] Handle connecting to brokers using an existing connections
- [ ] Handle encrypted connections

## Installation

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
