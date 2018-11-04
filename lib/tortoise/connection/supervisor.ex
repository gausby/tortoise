defmodule Tortoise.Connection.Supervisor do
  @moduledoc false

  use Supervisor

  alias Tortoise.Connection.{Receiver, Inflight}

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    Supervisor.start_link(__MODULE__, opts, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def whereis(client_id) do
    __MODULE__
    |> Tortoise.Registry.reg_name(client_id)
    |> Registry.whereis_name()
  end

  @impl true
  def init(opts) do
    children = [
      {Inflight, Keyword.take(opts, [:client_id, :parent])},
      {Receiver, Keyword.take(opts, [:client_id, :transport, :parent])}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_seconds: 30, max_restarts: 10)
  end
end
