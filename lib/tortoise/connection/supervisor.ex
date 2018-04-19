defmodule Tortoise.Connection.Supervisor do
  @moduledoc false

  use Supervisor

  alias Tortoise.Connection.{Transmitter, Receiver, Controller, Inflight}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(opts) do
    children = [
      {Inflight, Keyword.take(opts, [:client_id])},
      {Transmitter, Keyword.take(opts, [:client_id])},
      {Receiver, Keyword.take(opts, [:client_id])},
      {Controller, Keyword.take(opts, [:client_id, :driver])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
