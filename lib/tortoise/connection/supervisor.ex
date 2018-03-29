defmodule Tortoise.Connection.Supervisor do
  @moduledoc false

  use Supervisor

  alias Tortoise.Connection.{Transmitter, Receiver, Controller}

  def start_link({_protocol, _host, _port} = server, opts) do
    Supervisor.start_link(__MODULE__, {server, opts})
  end

  def init({{_protocol, _host, _port} = server, opts}) do
    children = [
      worker(Transmitter, [Keyword.take(opts, [:client_id])]),
      worker(Receiver, [server, Keyword.take(opts, [:client_id])]),
      worker(Controller, [Keyword.take(opts, [:client_id, :driver])])
    ]

    supervise(children, strategy: :one_for_one)
  end
end
