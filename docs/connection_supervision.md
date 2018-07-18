# Connection Supervision

An important aspect of building an Elixir application is setting up a
supervision structure that ensure the application will continue
working if parts of the system should reach an erroneous state and
need to get restarted into a known working state. To do this one need
to group the processes the application consist of in a manner such
that processes belonging together will start and terminate together.

`Tortoise` offers multiple ways of supervising one or multiple
connections; by using the provided dynamic `Tortoise.Supervisor` or
starting a dynamic supervisor belonging to the application using the
connections; or by starting the connections needed directly in an
application supervisor. This document will describe the ways of
supervision, and give an overview for when to use a given supervision
strategy.


## Linked Connection

A connection can be started and linked to the current process by using
the `Tortoise.Connection.start_link/1` function.

``` elixir
Tortoise.Connection.start_link(
  client_id: HeartOfGold,
  server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883},
  handler: {Tortoise.Handler.Logger, []}
)
```

As with any other linked process both process will terminate if either
terminate, as described in the `Process.link/1` documentation. This
mean that any stored state in the process that own the MQTT connection
will disappear with the process if the connection process
terminates. Therefore it is not recommended to link a connection
process like this outside of experimenting in `IEx`, but instead run
it inside of a supervisor process. When properly supervised connection
terminations the crash will be contained, allowing the other processes
to keep their state.


## Supervising a connection

The `Tortoise.Connection` module provides a `child_spec/1` which makes
it easier to start a `Tortoise.Connection` as part of a supervisor by
simply passing a `{Tortoise.Connection, connection_specification}` to
the supervisor child list.

``` elixir
defmodule MyApp.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Tortoise.Connection,
       [
         client_id: WombatTaskForce,
         server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883},
         handler: {Tortoise.Handler.Logger, []}
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

The great thing about this approach is that the connection can live in
the same supervision tree as the rest of the application that depend
on that connection. The connection is started, restarted, and stopped
with the application as a whole, ensuring the connection is closed
with the processes that depend on it.

Be sure to set a reasonable connection strategy for the
supervisor. Refer to the `Supervisor` documentation for more
information on usage and configuration.


## The `Tortoise.Supervisor`

When `Tortoise` is included as a dependency in the *mix.exs*-file of
an application `Tortoise` will automatically get started along the
application. During the application start up a dynamic supervisor will
spawn and register itself under the name `Tortoise.Supervisor`. This
can be used to start supervised connections that will get restarted if
they are terminated with an abnormal reason.

To start a connection on the `Tortoise.Supervisor` one can use the
`Tortoise.Supervisor.start_child/2` function, which defaults to using
the dynamic supervisor registered under the name
`Tortoise.Supervisor`.

``` elixir
Tortoise.Supervisor.start_child(
  client_id: "heart-of-gold",
  handler: {Tortoise.Handler.Logger, []},
  server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883}
)
```

This is an easy and convenient way of getting started, as everything
needed to supervise a connection is there when the `Tortoise`
application has been initialized. One downside is that, while the
children are supervised they are not grouped with the application that
need the connections; they are grouped with the `Tortoise`
application. To mitigate this a `Tortoise.Supervisor.child_spec/1`
function is available, which can be used to start the
`Tortoise.Supervisor` as part of another supervisor.

``` elixir
defmodule MyApp.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Tortoise.Supervisor,
       [
         name: MyApp.Connection.Supervisor,
         strategy: :one_for_one
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Connections can now, dynamically, be attached to the supervised
`Tortoise.Supervisor` by calling the
`Tortoise.Supervisor.start_child/2` function and specifying the name
that was given to the supervisor, in this case
*MyApp.Connection.Supervisor*.

``` elixir
Tortoise.Supervisor.start_child(
  MyApp.Connection.Supervisor,
  client_id: SmartHose,
  server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883},
  handler: {Tortoise.Handler.Logger, []}
)
```

This is the best way of supervising a dynamic set of connections, but
might be overkill if only one, static connection is needed for the
application.


## Summary

`Tortoise` makes it possible to spawn connections and supervise them,
and it is always best practice to supervise a connection to ensure it
remains up. Different approaches can be taken depending on the
situation:

  * If a fixed amount of connections are needed the recommended way is
    to attach them directly to a supervision tree, along with the
    processes that depend on said connections using the
    `Tortoise.Connection.child_spec/1`

  * If a dynamic set of connections are needed the recommended way is
    to spawn a named `Tortoise.Supervisor` as part of a supervisor,
    which hold the processes that depend on the connections, and spawn
    the connections on the dynamic supervisor.

Supervising the connections along the processes that rely on the
connection ensure that the application can be started and stopped as a
whole, and makes it possible to recover from faulty state.
