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
          client_id: "T-1000",
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

  See the Connection Supervision article in the project documentation
  for more information on connection supervision.

  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    DynamicSupervisor.child_spec(opts)
  end

  @doc """
  Start a connection as a child of the `Tortoise.Supervisor`.

  *Todo, rephrase this.*

  The parent of the connection will be the `Tortoise.Supervisor` so
  the process that call the `start_child/2` function will not get
  linked to the connection; the supervisor will. One need to monitor
  the connection, or use the `Tortoise.Connection.start_link/2`
  directly, or attach the `Tortoise.Connection` to a supervision tree
  if the connection should live with other parts of the system.
  """
  def start_child(name \\ __MODULE__, opts) do
    spec = {Tortoise.Connection, opts}
    DynamicSupervisor.start_child(name, spec)
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      extra_arguments: [opts]
    )
  end
end
