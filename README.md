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
# connect to the server and subscribe to foo/bar with QoS 0
Tortoise.Supervisor.start_child(
    client_id: "my_client_id",
    handler: {Tortoise.Handler.Logger, []},
    server: {:tcp, 'localhost', 1883},
    subscriptions: [{"foo/bar", 0}])

# publish a message on the broker
Tortoise.publish("my_client_id", "foo/bar", "Hello from the World of Tomorrow !", qos: 0)
```

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

## License

Copyright 2018 Martin Gausby

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
