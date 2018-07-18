defmodule Tortoise.Supervisor do
  @moduledoc """
  A dynamic supervisor that can hold `Tortoise.Connection` processes

  A `Tortoise.Supervisor`, registered under the name
  `Tortoise.Supervisor`, is started as part of the `Tortoise.App`,
  which will get started automatically when `Tortoise` is included as
  a `Mix` dependency. Spawning a connection on the
  `Tortoise.Supervisor` can be done as follows:

      {:ok, pid} =
        Tortoise.Supervisor.start_child(
          client_id: T1000,
          handler: {Tortoise.Handler.Logger, []},
          server: {Tortoise.Transport.Tcp, host: 'localhost', port: 1883},
          subscriptions: [{"foo/bar", 0}]
        )

  While this is an easy way to get started one should consider the
  supervision strategy of the application using the
  `Tortoise.Connection`s. Often one would like to close the connection
  with the application using the connection, in which case one could
  consider starting the `Tortoise.Connection` directly in the
  supervisor of the application using the connection, or start a
  `Tortoise.Supervisor` as part of ones application if it require more
  than one connection.

  See the *Connection Supervision* article in the project
  documentation for more information on connection supervision.
  """

  use DynamicSupervisor

  @doc """
  Start a dynamic supervisor that can hold connection processes.

  The `:name` option can also be given in order to register a supervisor
  name, the supported values are described in the "Name registration"
  section in the `GenServer` module docs.
  """
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Returns a specification to start this module under a supervisor.

  The supervisor is registered under the name given as `name`-option
  will. The default is `Tortoise.Supervisor`.

  See the documentation for `Supervisor` for configuration options.
  """
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    DynamicSupervisor.child_spec(opts)
  end

  @doc """
  Start a connection as a child of the `Tortoise.Supervisor`.

  `supervisor` is the name of the supervisor the child should be
  started on, and it defaults to `Tortoise.Supervisor`.
  """
  def start_child(supervisor \\ __MODULE__, opts) do
    spec = {Tortoise.Connection, opts}
    DynamicSupervisor.start_child(supervisor, spec)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
