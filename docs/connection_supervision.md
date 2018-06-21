# Connection Supervision

An important aspect of building an Elixir application is setting up a
supervision structure that ensure the application will continue
working if parts of the system should reach an erroneous state and
need to get restarted into a known working state.

To do this one need to group the processes the application consist of
in a manner such that processes belonging together will start and
terminate together.

`Tortoise` offers multiple ways of supervising one or multiple
connections; by using the provided dynamic `Tortoise.Supervisor` or
starting a dynamic supervisor belonging to the application using the
connections; or by starting the connections needed directly in an
application supervisor. This document will describe when to use a
given supervision strategy, and its pros and cons.

## The `Tortoise.Supervisor`

When `Tortoise` is included as a dependency in the *mix.exs*-file of
an application `Tortoise` will automatically get started along the
application. During the application start up a dynamic supervisor will
spawn and register itself under the name `Tortoise.Supervisor`. This
can be used to start supervised connections that will get restarted if
they are terminated with an abnormal reason.

To start a connection on the `Tortoise.Supervisor` one can use the
`Tortoise.Supervisor.start_child/1` function.

    Tortoise.Supervisor.start_child(
        client_id: "heart-of-gold",
        handler: {Tortoise.Handler.Logger, []},
        server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883}
    )

This is an easy and convenient way of getting started, as everything
needed to supervise a connection is there when the `Tortoise`
application is started. it does [continue here, martin!]...
