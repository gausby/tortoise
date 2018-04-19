defmodule Tortoise.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    DynamicSupervisor.child_spec(opts)
  end

  def start_child(name \\ __MODULE__, opts) do
    spec = {Tortoise.Connection, opts}
    DynamicSupervisor.start_child(name, spec)
  end

  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      extra_arguments: [opts]
    )
  end
end
