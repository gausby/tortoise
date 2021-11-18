defmodule Tortoise311.Supervisor do
  @moduledoc """
  A dynamic supervisor that can hold `Tortoise311.Connection` processes

  A `Tortoise311.Supervisor`, registered under the name
  `Tortoise311.Supervisor`, is started as part of the `Tortoise311.App`,
  which will get started automatically when `Tortoise311` is included as
  a `Mix` dependency. Spawning a connection on the
  `Tortoise311.Supervisor` can be done as follows:

      {:ok, pid} =
        Tortoise311.Supervisor.start_child(
          client_id: T1000,
          handler: {Tortoise311.Handler.Logger, []},
          server: {Tortoise311.Transport.Tcp, host: 'localhost', port: 1883},
          subscriptions: [{"foo/bar", 0}]
        )

  While this is an easy way to get started one should consider the
  supervision strategy of the application using the
  `Tortoise311.Connection`s. Often one would like to close the connection
  with the application using the connection, in which case one could
  consider starting the `Tortoise311.Connection` directly in the
  supervisor of the application using the connection, or start a
  `Tortoise311.Supervisor` as part of ones application if it require more
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

  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    DynamicSupervisor.child_spec(opts)
  end

  @doc """
  Start a connection as a child of the `Tortoise311.Supervisor`.

  `supervisor` is the name of the supervisor the child should be
  started on, and it defaults to `Tortoise311.Supervisor`.
  """
  def start_child(supervisor \\ __MODULE__, opts) do
    spec = {Tortoise311.Connection, opts}
    DynamicSupervisor.start_child(supervisor, spec)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
