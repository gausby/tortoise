defmodule Tortoise.Events do
  @moduledoc false

  @types [:connection]

  def register(client_id, type, value \\ nil) when type in @types do
    {:ok, _pid} = Registry.register(__MODULE__, {client_id, type}, value)
  end

  def unregister(client_id, type) when type in @types do
    :ok = Registry.unregister(__MODULE__, {client_id, type})
  end

  @doc false
  def dispatch(client_id, type, msg) when type in @types do
    :ok =
      Registry.dispatch(__MODULE__, {client_id, type}, fn subscribers ->
        for {pid, _value} <- subscribers do
          Kernel.send(pid, {{Tortoise, client_id}, type, msg})
        end
      end)
  end
end
