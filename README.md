# Tortoise

[![Hex.pm](https://img.shields.io/hexpm/l/tortoise.svg "Apache 2.0 Licensed")](https://github.com/gausby/tortoise/blob/master/LICENSE)
[![Hex version](https://img.shields.io/hexpm/v/tortoise.svg "Hex version")](https://hex.pm/packages/tortoise)
[![Build Status](https://travis-ci.org/gausby/tortoise.svg)](https://travis-ci.org/gausby/tortoise)
[![Coverage Status](https://coveralls.io/repos/github/gausby/tortoise/badge.svg?branch=master)](https://coveralls.io/github/gausby/tortoise?branch=master)

A MQTT Client application that keep connections to one or more MQTT
brokers, handles subscriptions, and expose a publisher for publishing
messages to the broker.

Amongst other things Tortoise supports:

  - Keeping a connection to a MQTT server (version 3.1.1 for now)
  - Retry connecting with incremental back-off
  - Publishing and subscribing to topics of QoS 0, 1, and 2
  - Connections support last will message
  - Connecting via TCP and SSL
  - The fundamentals are there, but some of the API's might change in
    the near future

Most of the public facing interface should be in the `Tortoise`
module. See the GitHub issues for work in progress "known issues in
the design", "what needs to be done", and so forth; feel free to open
your own issues if something is confusing or broken.

I would love to get some feedback and help building this thing.

## Example

A supervised connection can be started like this:

``` elixir
# connect to the server and subscribe to foo/bar with QoS 0
Tortoise.Supervisor.start_child(
    client_id: "my_client_id",
    handler: {Tortoise.Handler.Logger, []},
    server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883},
    subscriptions: [{"foo/bar", 0}])

# publish a message on the broker
Tortoise.publish("my_client_id", "foo/bar", "Hello from the World of Tomorrow !", qos: 0)
```

To connect to a MQTT server using SSL the `Tortoise.Transport.SSL`
transport can be used like this:

``` elixir
Tortoise.Supervisor.start_child(
    client_id: "smart-spoon",
    handler: {Tortoise.Handler.Logger, []},
    server: {Tortoise.Transport.SSL, host: host, port: port, key: key, cert: cert},
    subscriptions: [{"foo/bar", 0}])
```

Look at the `connection_test.exs`-file for an example.

## Installation

Tortoise can be installed by adding `tortoise` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tortoise, "~> 0.5.0"}
  ]
end
```

Documentation should be available at
[https://hexdocs.pm/tortoise](https://hexdocs.pm/tortoise).

## Building documentation

To build the documentation run the following command in a terminal emulator:

``` shell
MIX_ENV=docs mix docs
```

This will build the documentation in place them in the *doc*-folder in
the root of the project. These docs will also find their way to the
Hexdocs website when the project is published on Hex.

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
