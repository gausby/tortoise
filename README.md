# Tortoise311

This is a fork of [Martin Gausby's Tortoise] (https://github.com/gausby/tortoise)

[![Build Status](https://semaphoreci.com/api/v1/gausby/tortoise/branches/master/badge.svg)](https://semaphoreci.com/gausby/tortoise)
[![Hex.pm](https://img.shields.io/hexpm/l/tortoise.svg "Apache 2.0 Licensed")](https://github.com/gausby/tortoise/blob/master/LICENSE)
[![Hex version](https://img.shields.io/hexpm/v/tortoise.svg "Hex version")](https://hex.pm/packages/tortoise)
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
  - A PubSub system where one can listen to system events. For now
    connection status and ping response times can be subscribed for
    statistics and administrative purposes.

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
transport can be used. This requires configuration of the server's
CA certificate, and possibly a client certificate and key. For
example, when using the [certifi](https://hex.pm/packages/certifi)
package as the CA trust store:

``` elixir
Tortoise.Supervisor.start_child(
    client_id: "smart-spoon",
    handler: {Tortoise.Handler.Logger, []},
    server: {
      Tortoise.Transport.SSL,
      host: host, port: port,
      cacertfile: :certifi.cacertfile(),
      key: key, cert: cert
    },
    subscriptions: [{"foo/bar", 0}])
```

Alternatively, for testing purposes, server certificate verification
can be disabled by passing `verify: :verify_none` in the server
options. In that case there is no need for CA certificates, but an
attacker could intercept the connection without detection!

Look at the `connection_test.exs`-file for more examples.

Example Handler
```elixir
defmodule Tortoise.Handler.Example do
  use Tortoise.Handler

  def init(args) do
    {:ok, args}
  end

  def connection(status, state) do
    # `status` will be either `:up` or `:down`; you can use this to
    # inform the rest of your system if the connection is currently
    # open or closed; tortoise should be busy reconnecting if you get
    # a `:down`
    {:ok, state}
  end

  #  topic filter room/+/temp
  def handle_message(["room", room, "temp"], payload, state) do
    # :ok = Temperature.record(room, payload)
    {:ok, state}
  end
  def handle_message(topic, payload, state) do
    # unhandled message! You will crash if you subscribe to something
    # and you don't have a 'catch all' matcher; crashing on unexpected
    # messages could be a strategy though.
    {:ok, state}
  end

  def subscription(status, topic_filter, state) do
    {:ok, state}
  end

  def terminate(reason, state) do
    # tortoise doesn't care about what you return from terminate/2,
    # that is in alignment with other behaviours that implement a
    # terminate-callback
    :ok
  end
end
```

## Upgrade path

### pre-0.9 to 0.9

The `subscribe/3`, `unsubscribe/3`, `subscribe_sync/3`, and
`unsubscribe_sync/3` is no longer exposed on the `Tortoise`
module. The functionality has been moved to the `Tortoise.Connection`
module. The functions has the same arities and functionality, so the
upgrade path is a simple search and replace:

  - `"Tortoise.subscribe(" -> "Tortoise.Connection.subscribe("`
  - `"Tortoise.subscribe_sync(" -> "Tortoise.Connection.subscribe_sync("`
  - `"Tortoise.unsubscribe(" -> "Tortoise.Connection.unsubscribe("`
  - `"Tortoise.unsubscribe_sync(" -> "Tortoise.Connection.unsubscribe_sync("`

This change is done because the `Tortoise.Connection` module should be
in charge of changes to the connection life-cycle.

## Installation

Tortoise can be installed by adding `tortoise` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tortoise, "~> 0.9"}
  ]
end
```

Documentation should be available at
[https://hexdocs.pm/tortoise](https://hexdocs.pm/tortoise).

## Development

To start developing, run the following commands:

```
mix deps.get
MIX_ENV=test mix eqc.install --mini
mix test
```

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
