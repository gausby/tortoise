defmodule Tortoise311.App do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # read configuration and start connections
    # start with client_id, and handler from config

    children = [
      {Registry, [keys: :unique, name: Tortoise311.Registry]},
      {Registry, [keys: :duplicate, name: Tortoise311.Events]},
      {Tortoise311.Supervisor, [strategy: :one_for_one]}
    ]

    opts = [strategy: :one_for_one, name: Tortoise311]
    Supervisor.start_link(children, opts)
  end
end
