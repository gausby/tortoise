defmodule Tortoise.App do
  @moduledoc false

  use Application

  @doc """
  Start the application supervisor
  """
  def start(_type, _args) do
    # read configuration and start connections
    # start with client_id, and driver from config

    children = [
      {Registry, [keys: :unique, name: Registry.Tortoise]},
      {Tortoise.Supervisor, [strategy: :one_for_one]}
    ]

    opts = [strategy: :one_for_one, name: Tortoise]
    Supervisor.start_link(children, opts)
  end
end
