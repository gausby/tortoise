defmodule Tortoise.TransmitterSupervisor do
  @moduledoc false

  alias Tortoise.Connection.Receiver

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_transmitter(sup \\ __MODULE__, opts) do
    opts = Keyword.put(opts, :parent, self())
    spec = {Receiver, Keyword.take(opts, [:transport, :parent])}
    DynamicSupervisor.start_child(sup, spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
